defmodule Testor.Sessions do
  @moduledoc """
  PowerShell sessions working in <workspaces>\\<project> that do not go through run.ps1 (a
  Taskfile that is not wired, an interactive ssh). sshd starts them as `pwsh -c "<command>"`,
  so the command line names the project. Asking Windows costs a PowerShell start, so this
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

  defp script do
    folder = Regex.escape(Config.workspaces_name())

    """
    Get-CimInstance Win32_Process -Filter "Name='pwsh.exe' OR Name='powershell.exe'" |
      Where-Object { $_.CommandLine -match '#{folder}' -and $_.CommandLine -notmatch 'Get-CimInstance|sysinfo\\.ps1' } |
      ForEach-Object { [pscustomobject]@{ pid = $_.ProcessId; started = $_.CreationDate.ToUniversalTime().ToString('o'); cmd = $_.CommandLine } } |
      ConvertTo-Json -Compress
    """
  end

  defp query do
    with {:ok, out} <- OS.powershell(script()),
         out when out != "" <- String.trim(out),
         {:ok, parsed} <- JSON.decode(out) do
      parsed
      |> List.wrap()
      |> Enum.map(&describe/1)
      |> Enum.reject(& &1["wrapped"])
      |> Enum.sort_by(& &1["startedAt"])
    else
      _ -> []
    end
  end

  defp describe(%{"pid" => pid, "started" => started, "cmd" => cmd}) do
    # The command's own quotes arrive escaped as \".
    cmd = String.replace(cmd || "", ~S(\"), ~S("))

    project =
      case Regex.run(~r/#{Regex.escape(Config.workspaces_name())}\\([^"\\;]+)/, cmd) do
        [_, project] -> project
        _ -> "?"
      end

    command =
      case Regex.split(~r/Set-Location\s+"[^"]*"\s*;/, cmd, parts: 2) do
        [_, rest] -> rest
        _ -> cmd
      end
      |> String.replace(~r/["']?\s*$/, "")
      |> String.trim()

    %{
      "pid" => pid,
      "startedAt" => started,
      "project" => project,
      "command" => command,
      "wrapped" => String.contains?(cmd, Path.basename(Config.data_dir()) <> "\\run.ps1")
    }
  end
end
