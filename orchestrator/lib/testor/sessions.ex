defmodule Testor.Sessions do
  @moduledoc """
  PowerShell sessions working in a project snapshot that do not go through run.ps1 (a task
  without KIND, a Taskfile that is not wired, an interactive ssh). remote.yml sends scripts as
  `pwsh -Command '&([scriptblock]::Create(...FromBase64String("...")))'`, so the command line
  is decoded to find the project; older Taskfiles that send `Set-Location "...\\<project>"; ...`
  in clear are read as they are. Listing processes costs a PowerShell start on Windows, so this
  polls every 5 s only while someone watches the dashboard.
  """
  use GenServer
  alias Testor.{Config, Events, OS}

  @every 5_000

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def list, do: GenServer.call(__MODULE__, :list)

  @doc "Polls now (a viewer connected)."
  def poke, do: send(__MODULE__, :poll)

  @impl true
  def init(nil) do
    Process.send_after(self(), :tick, @every)
    {:ok, %{list: [], task: nil}}
  end

  @impl true
  def handle_call(:list, _from, state), do: {:reply, state.list, state}

  @impl true
  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, @every)
    if Events.subscribers("global") > 0, do: send(self(), :poll)
    {:noreply, state}
  end

  def handle_info(:poll, %{task: nil} = state) do
    task = Task.Supervisor.async_nolink(Testor.TaskSupervisor, &query/0)
    {:noreply, %{state | task: task.ref}}
  end

  def handle_info(:poll, state), do: {:noreply, state}

  def handle_info({ref, list}, %{task: ref} = state) do
    Process.demonitor(ref, [:flush])
    if list != state.list, do: Events.broadcast("global", "sessions", list)
    {:noreply, %{state | list: list, task: nil}}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{task: ref} = state),
    do: {:noreply, %{state | task: nil}}

  def handle_info(_, state), do: {:noreply, state}

  defp query do
    processes() |> Enum.flat_map(&describe/1) |> Enum.sort_by(& &1["startedAt"])
  end

  # [{pid, startedAt, command line}] of the PowerShell processes.
  defp processes do
    if OS.windows?(), do: windows_processes(), else: unix_processes()
  end

  defp windows_processes do
    script = """
    Get-CimInstance Win32_Process -Filter "Name='pwsh.exe' OR Name='powershell.exe'" |
      Where-Object { $_.CommandLine -notmatch 'Get-CimInstance|sysinfo\\.ps1' } |
      ForEach-Object { [pscustomobject]@{ pid = $_.ProcessId; started = $_.CreationDate.ToUniversalTime().ToString('o'); cmd = $_.CommandLine } } |
      ConvertTo-Json -Compress
    """

    with {:ok, out} <- OS.powershell(script),
         out when out != "" <- String.trim(out),
         {:ok, parsed} <- JSON.decode(out) do
      for %{"pid" => pid, "started" => started, "cmd" => cmd} <- List.wrap(parsed),
          do: {pid, started, cmd || ""}
    else
      _ -> []
    end
  end

  defp unix_processes do
    case System.cmd("ps", ["-A", "-o", "pid=,etime=,args="], stderr_to_stdout: true) do
      {out, 0} ->
        now = DateTime.utc_now()

        out
        |> String.split("\n", trim: true)
        |> Enum.filter(&String.contains?(&1, "pwsh"))
        |> Enum.flat_map(fn line ->
          case String.split(String.trim(line), ~r/\s+/, parts: 3) do
            [pid, etime, args] ->
              started = DateTime.add(now, -elapsed(etime), :second) |> DateTime.to_iso8601()
              [{String.to_integer(pid), started, args}]

            _ ->
              []
          end
        end)

      _ ->
        []
    end
  end

  # ps's etime: [[dd-]hh:]mm:ss
  @doc false
  def elapsed(etime) do
    {days, rest} =
      case String.split(etime, "-") do
        [d, rest] -> {String.to_integer(d), rest}
        [rest] -> {0, rest}
      end

    parts = rest |> String.split(":") |> Enum.map(&String.to_integer/1)
    [s, m, h] = Enum.reverse(parts) ++ List.duplicate(0, 3 - length(parts))
    days * 86_400 + h * 3_600 + m * 60 + s
  end

  @doc false
  def describe({pid, started, cmd}) do
    # Windows hands the command line with the inner quotes escaped as \".
    cmd = String.replace(cmd, ~S(\"), ~S("))
    script = decode(cmd)
    text = script || cmd

    case project(text) do
      nil ->
        []

      project ->
        wrapped = String.contains?(text, "& $testorRun") or String.contains?(text, "run.ps1\" -Project")
        sysinfo = String.contains?(text, "sysinfo.ps1")

        if wrapped or sysinfo do
          []
        else
          [%{"pid" => pid, "startedAt" => started, "project" => project, "command" => command(script, cmd)}]
        end
    end
  end

  defp decode(cmd) do
    with [_, b64] <- Regex.run(~r/FromBase64String\("([A-Za-z0-9+\/=]+)"\)/, cmd),
         {:ok, text} <- Base.decode64(b64),
         true <- String.valid?(text) do
      text
    else
      _ -> nil
    end
  end

  defp project(text) do
    folder = Regex.escape(Config.workspaces_name())

    cond do
      # remote.yml's prelude: Join-Path (Join-Path $HOME "<workspaces>") "<project>"
      m = Regex.run(~r/Join-Path \$HOME "#{folder}"\) "([^"]+)"/, text) -> Enum.at(m, 1)
      m = Regex.run(~r/#{folder}[\\\/]([^"\\\/;\s']+)/, text) -> Enum.at(m, 1)
      true -> nil
    end
  end

  defp command(nil, cmd) do
    case Regex.split(~r/Set-Location\s+"[^"]*"\s*;/, cmd, parts: 2) do
      [_, rest] -> rest
      _ -> cmd
    end
    |> String.replace(~r/["']?\s*$/, "")
    |> String.trim()
  end

  # The script's own lines: what follows the prelude's Set-Location (or the whole script).
  defp command(script, _cmd) do
    lines = String.split(script, ~r/\r?\n/)

    body =
      case Enum.find_index(lines, &(String.trim(&1) == "Set-Location $workspace")) do
        nil ->
          Enum.drop_while(
            lines,
            &(not String.starts_with?(&1, "function") and not String.starts_with?(&1, "tar"))
          )

        i ->
          Enum.drop(lines, i + 1)
      end

    body |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) |> Enum.join("; ")
  end
end
