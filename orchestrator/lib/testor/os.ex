defmodule Testor.OS do
  @moduledoc "Process and disk queries, for Windows, Linux and macOS."

  @doc ":windows, :linux, :macos or :unix (another Unix)."
  def family do
    case :os.type() do
      {:win32, _} -> :windows
      {:unix, :linux} -> :linux
      {:unix, :darwin} -> :macos
      {:unix, _} -> :unix
    end
  end

  def windows?, do: family() == :windows

  @doc "Whether a process with this pid exists."
  def alive?(pid) when is_integer(pid) do
    if windows?() do
      # tasklist prints the process's CSV row, in any locale.
      case System.cmd("tasklist", ["/FI", "PID eq #{pid}", "/NH", "/FO", "CSV"], stderr_to_stdout: true) do
        {out, 0} -> String.contains?(out, ~s("#{pid}"))
        # If tasklist itself fails, assume alive: a wrong "aborted" is worse than a late one.
        _ -> true
      end
    else
      # A zombie (ended, not yet reaped by its parent) has ended: its state starts with Z.
      case System.cmd("ps", ["-p", "#{pid}", "-o", "stat="], stderr_to_stdout: true) do
        {out, 0} -> (state = String.trim(out)) != "" and not String.starts_with?(state, "Z")
        {_, 1} -> false
        _ -> true
      end
    end
  end

  def alive?(_), do: false

  @doc "Kills a process and every process it started."
  def kill_tree(pid) when is_integer(pid) do
    if windows?() do
      {out, code} = System.cmd("taskkill", ["/PID", "#{pid}", "/T", "/F"], stderr_to_stdout: true)
      if code == 0, do: :ok, else: {:error, String.trim(out)}
    else
      pids = [pid | descendants(pid)]
      # Children first would let a parent respawn them; stop the whole tree, then kill it.
      System.cmd("kill", ["-STOP" | Enum.map(pids, &to_string/1)], stderr_to_stdout: true)

      case System.cmd("kill", ["-KILL" | Enum.map(pids, &to_string/1)], stderr_to_stdout: true) do
        {_, 0} -> :ok
        {out, _} -> {:error, String.trim(out)}
      end
    end
  end

  @doc "Every process under `pid` (Unix), from `ps`."
  def descendants(pid) do
    children = parents() |> Enum.group_by(&elem(&1, 1), &elem(&1, 0))
    walk(children, [pid], [])
  end

  @doc "`[{pid, parent pid}]` of every process."
  def parents do
    if windows?() do
      script =
        "Get-CimInstance Win32_Process | ForEach-Object { \"$($_.ProcessId) $($_.ParentProcessId)\" }"

      case powershell(script) do
        {:ok, out} -> pairs(out)
        _ -> []
      end
    else
      case System.cmd("ps", ["-A", "-o", "pid=,ppid="], stderr_to_stdout: true) do
        {out, 0} -> pairs(out)
        _ -> []
      end
    end
  end

  defp pairs(out) do
    out
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      with [child, parent] <- String.split(line),
           {child, ""} <- Integer.parse(child),
           {parent, ""} <- Integer.parse(parent) do
        [{child, parent}]
      else
        _ -> []
      end
    end)
  end

  @doc """
  The processes above `pid`, nearest first. Pid reuse can make the parent links of old
  processes loop (Windows keeps a dead parent's pid in its children), so each pid is visited once.
  """
  def ancestors(pid) do
    parent = Map.new(parents())
    climb(parent, Map.get(parent, pid), [pid])
  end

  defp climb(_parent, nil, seen), do: tl(Enum.reverse(seen))
  defp climb(_parent, 0, seen), do: tl(Enum.reverse(seen))

  defp climb(parent, pid, seen) do
    if pid in seen, do: tl(Enum.reverse(seen)), else: climb(parent, Map.get(parent, pid), [pid | seen])
  end

  @doc "When process `pid` started (UTC), or nil when there is no such process."
  def started_at(pid) when is_integer(pid) and pid > 0 do
    if windows?() do
      script =
        "$p = Get-CimInstance Win32_Process -Filter 'ProcessId=#{pid}'; " <>
          "if ($p) { $p.CreationDate.ToUniversalTime().ToString('o') }"

      with {:ok, out} <- powershell(script),
           {:ok, time, _} <-
             out |> String.trim() |> String.replace(~r/(\.\d{6})\d+/, "\\1") |> DateTime.from_iso8601() do
        time
      else
        _ -> nil
      end
    else
      case System.cmd("ps", ["-p", "#{pid}", "-o", "etime="], stderr_to_stdout: true) do
        {out, 0} -> DateTime.add(DateTime.utc_now(), -elapsed(String.trim(out)), :second)
        _ -> nil
      end
    end
  end

  def started_at(_), do: nil

  defp walk(_children, [], found), do: found

  defp walk(children, [pid | rest], found) do
    kids = Map.get(children, pid, []) |> Enum.reject(&(&1 in found or &1 == pid))
    walk(children, rest ++ kids, found ++ kids)
  end

  @doc """
  Removes a symbolic link (not what it points to). Windows refuses File.rm/1 on a junction
  whose target is gone (eperm); deleting it as a directory works.
  """
  def remove_link(path) do
    case File.rm(path) do
      :ok -> :ok
      error -> if windows?(), do: :file.del_dir(path), else: error
    end
  end

  @doc "[{pid, startedAt, command line}] of the running PowerShell 7 and Windows PowerShell processes."
  def pwsh_processes do
    if windows?(), do: windows_pwsh(), else: unix_pwsh()
  end

  defp windows_pwsh do
    script = """
    Get-CimInstance Win32_Process -Filter "Name='pwsh.exe' OR Name='powershell.exe'" |
      Where-Object { $_.CommandLine -notmatch 'Get-CimInstance|sysinfo\\.ps1' } |
      ForEach-Object { [pscustomobject]@{ pid = $_.ProcessId; started = $_.CreationDate.ToUniversalTime().ToString('o'); cmd = $_.CommandLine } } |
      ConvertTo-Json -Compress
    """

    with {:ok, out} <- powershell(script),
         out when out != "" <- String.trim(out),
         {:ok, parsed} <- JSON.decode(out) do
      for %{"pid" => pid, "started" => started, "cmd" => cmd} <- List.wrap(parsed),
          do: {pid, started, cmd || ""}
    else
      _ -> []
    end
  end

  defp unix_pwsh do
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

  @doc "Seconds in ps's etime: [[dd-]hh:]mm:ss."
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

  @doc "Runs a Windows PowerShell script and returns its stdout."
  def powershell(script, timeout \\ 15_000) do
    task =
      Task.async(fn ->
        System.cmd("powershell.exe", ["-NoProfile", "-NonInteractive", "-Command", script])
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {out, 0}} -> {:ok, out}
      {:ok, {out, code}} -> {:error, {code, out}}
      nil -> {:error, :timeout}
    end
  end

  @doc "Free and total bytes of the volume that holds `path`."
  def disk(path) do
    if windows?() do
      drive = path |> Path.expand() |> String.first()
      script = "$d = [IO.DriveInfo]::new('#{drive}'); \"$($d.AvailableFreeSpace) $($d.TotalSize)\""

      with {:ok, out} <- powershell(script),
           [free, total] <- String.split(String.trim(out)),
           {free, ""} <- Integer.parse(free),
           {total, ""} <- Integer.parse(total) do
        %{"free" => free, "total" => total}
      else
        _ -> nil
      end
    else
      case df(path) do
        [volume | _] -> %{"free" => volume["free"], "total" => volume["size"]}
        _ -> nil
      end
    end
  end

  @doc "Mounted volumes (Unix), from `df -Pk`: drive (mount point), fs, size, free."
  def df(path \\ nil) do
    args = if path, do: ["-Pk", path], else: ["-Pk"]

    case System.cmd("df", args, stderr_to_stdout: true) do
      {out, _} ->
        out
        |> String.split("\n", trim: true)
        |> Enum.drop(1)
        |> Enum.flat_map(fn line ->
          case String.split(line) do
            [fs, size, _used, free, _pct | mount] ->
              with {size, ""} <- Integer.parse(size), {free, ""} <- Integer.parse(free) do
                [
                  %{
                    "drive" => Enum.join(mount, " "),
                    "fs" => fs,
                    "size" => size * 1024,
                    "free" => free * 1024,
                    "label" => nil
                  }
                ]
              else
                _ -> []
              end

            _ ->
              []
          end
        end)
    end
  end
end
