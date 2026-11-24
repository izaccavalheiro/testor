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
      case System.cmd("ps", ["-p", "#{pid}", "-o", "pid="], stderr_to_stdout: true) do
        {out, 0} -> String.trim(out) == "#{pid}"
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
    case System.cmd("ps", ["-A", "-o", "pid=,ppid="], stderr_to_stdout: true) do
      {out, 0} ->
        children =
          out
          |> String.split("\n", trim: true)
          |> Enum.flat_map(fn line ->
            case String.split(line) do
              [child, parent] -> [{String.to_integer(parent), String.to_integer(child)}]
              _ -> []
            end
          end)
          |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

        walk(children, [pid], [])

      _ ->
        []
    end
  end

  defp walk(_children, [], found), do: found

  defp walk(children, [pid | rest], found) do
    kids = Map.get(children, pid, []) |> Enum.reject(&(&1 in found or &1 == pid))
    walk(children, rest ++ kids, found ++ kids)
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
