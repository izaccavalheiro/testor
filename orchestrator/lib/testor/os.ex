defmodule Testor.OS do
  @moduledoc "Windows process and disk queries."

  @doc "Whether a process with this pid exists (tasklist prints its CSV row, in any locale)."
  def alive?(pid) when is_integer(pid) do
    case System.cmd("tasklist", ["/FI", "PID eq #{pid}", "/NH", "/FO", "CSV"], stderr_to_stdout: true) do
      {out, 0} -> String.contains?(out, ~s("#{pid}"))
      # If tasklist itself fails, assume alive: a wrong "aborted" is worse than a late one.
      _ -> true
    end
  end

  def alive?(_), do: false

  @doc "Kills a process and every process it started."
  def kill_tree(pid) when is_integer(pid) do
    {out, code} = System.cmd("taskkill", ["/PID", "#{pid}", "/T", "/F"], stderr_to_stdout: true)
    if code == 0, do: :ok, else: {:error, String.trim(out)}
  end

  @doc "Runs a PowerShell script and returns its stdout."
  def powershell(script, timeout \\ 15_000) do
    task =
      Task.async(fn ->
        System.cmd("powershell.exe", ["-NoProfile", "-NonInteractive", "-Command", script],
          stderr_to_stdout: false
        )
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {out, 0}} -> {:ok, out}
      {:ok, {out, code}} -> {:error, {code, out}}
      nil -> {:error, :timeout}
    end
  end

  @doc "Free and total bytes of the drive that holds `path`."
  def disk(path) do
    drive = path |> Path.expand() |> String.first()

    script =
      "$d = [IO.DriveInfo]::new('#{drive}'); \"$($d.AvailableFreeSpace) $($d.TotalSize)\""

    with {:ok, out} <- powershell(script),
         [free, total] <- String.split(String.trim(out)),
         {free, ""} <- Integer.parse(free),
         {total, ""} <- Integer.parse(total) do
      %{"free" => free, "total" => total}
    else
      _ -> nil
    end
  end
end
