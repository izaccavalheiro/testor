defmodule Testor.Test.Helpers do
  @moduledoc "What the integration tests share: recording runs as run.ps1 does, waiting, HTTP."
  alias Testor.{Config, Files, Store}

  @doc "A run id in run.ps1's format, unique in this test run."
  def run_id do
    stamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d-%H%M%S")
    hex = :crypto.strong_rand_bytes(3) |> Base.encode16(case: :lower)
    "#{stamp}-#{hex}"
  end

  @doc "Writes a run's record as run.ps1 does and waits until the store has it."
  def record(attrs) do
    id = attrs["id"] || run_id()

    run =
      Map.merge(
        %{
          "id" => id,
          "project" => "demo",
          "kind" => "test",
          "command" => "npm test",
          "pid" => 0,
          "workdir" => Config.workspaces(),
          "startedAt" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "status" => "running"
        },
        attrs
      )

    File.mkdir_p!(Config.runs_dir())
    Files.write_json(Config.run_file(id), run)
    status = run["status"]
    wait_until(fn -> match?(%{"status" => ^status}, Store.get(id)) end)
    id
  end

  @doc "Ends a recorded run as run.ps1 does."
  def finish(id, status \\ "passed", extra \\ %{}) do
    {:ok, run} = Files.read_json(Config.run_file(id))

    run =
      Map.merge(run, %{"status" => status, "exitCode" => if(status == "passed", do: 0, else: 1)})
      |> Map.merge(%{"endedAt" => DateTime.utc_now() |> DateTime.to_iso8601(), "durationMs" => 1234})
      |> Map.merge(extra)

    Files.write_json(Config.run_file(id), run)
    wait_until(fn -> match?(%{"status" => ^status}, Store.get(id)) end)
    Store.get(id)
  end

  def log(id, text) do
    File.mkdir_p!(Config.logs_dir())
    File.write!(Config.log_file(id), text, [:append])
  end

  @doc "Waits until `fun` returns a truthy value, and returns it."
  def wait_until(fun, timeout \\ 10_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    loop(fun, deadline)
  end

  defp loop(fun, deadline) do
    case fun.() do
      falsy when falsy in [nil, false] ->
        if System.monotonic_time(:millisecond) > deadline, do: raise("timed out waiting")
        Process.sleep(50)
        loop(fun, deadline)

      value ->
        value
    end
  end

  @doc """
  A process that runs until killed: `{port, os_pid}`. `:hide`: without it, a PowerShell
  started from a port in an SSH session on Windows exits at once.
  """
  def sleeper do
    pwsh = System.find_executable("pwsh") || raise "pwsh is not on PATH"

    port =
      Port.open({:spawn_executable, pwsh}, [
        :binary,
        :hide,
        args: ["-NoProfile", "-Command", "Start-Sleep 300"]
      ])

    {:os_pid, pid} = Port.info(port, :os_pid)
    {port, pid}
  end

  def base_url, do: "http://127.0.0.1:#{Application.fetch_env!(:testor, :test_port)}"

  @doc """
  An HTTP/1.1 request to the running server over a plain socket: `%{status, headers, body}`.
  Options: `headers`, `body`, `type` (the body's content type, JSON by default).
  """
  def http(method, path, opts \\ []) do
    {:ok, socket} = connect(method, path, opts)
    data = read_all(socket, "")
    :gen_tcp.close(socket)
    response(data)
  end

  defp connect(method, path, opts) do
    port = Application.fetch_env!(:testor, :test_port)
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :raw], 5_000)
    body = Keyword.get(opts, :body)

    headers =
      [{"host", "127.0.0.1:#{port}"}, {"connection", "close"}] ++
        if(body,
          do: [
            {"content-type", Keyword.get(opts, :type, "application/json")},
            {"content-length", byte_size(body)}
          ],
          else: []
        ) ++
        Keyword.get(opts, :headers, [])

    head = Enum.map_join(headers, "", fn {k, v} -> "#{k}: #{v}\r\n" end)
    method = method |> to_string() |> String.upcase()
    :ok = :gen_tcp.send(socket, ["#{method} #{path} HTTP/1.1\r\n", head, "\r\n", body || ""])
    {:ok, socket}
  end

  defp read_all(socket, acc) do
    case :gen_tcp.recv(socket, 0, 30_000) do
      {:ok, data} -> read_all(socket, acc <> data)
      {:error, :closed} -> acc
    end
  end

  defp response(data) do
    [head, body] = :binary.split(data, "\r\n\r\n")
    [status_line | lines] = String.split(head, "\r\n")
    [_, status | _] = String.split(status_line, " ")

    headers =
      for line <- lines do
        [k, v] = :binary.split(line, ":")
        {String.downcase(k), String.trim(v)}
      end

    chunked = Enum.any?(headers, &(&1 == {"transfer-encoding", "chunked"}))

    %{
      status: String.to_integer(status),
      headers: headers,
      body: if(chunked, do: dechunk(body, ""), else: body)
    }
  end

  defp dechunk(data, acc) do
    case :binary.split(data, "\r\n") do
      [size, rest] ->
        case Integer.parse(size, 16) do
          {0, _} ->
            acc

          {n, _} when byte_size(rest) >= n ->
            dechunk(binary_part(rest, n + 2, byte_size(rest) - n - 2), acc <> binary_part(rest, 0, n))

          _ ->
            acc <> rest
        end

      _ ->
        acc
    end
  end

  def header(%{headers: headers}, name) do
    Enum.find_value(headers, fn {k, v} -> if k == name, do: v end)
  end

  def json(%{body: body}), do: JSON.decode!(body)

  @doc "Opens a server-sent event stream (or the response that refused it); read it with `events/2`."
  def stream(path, headers \\ []) do
    {:ok, socket} = connect(:get, path, headers: headers)
    :inet.setopts(socket, active: true)
    socket
  end

  @doc "Collects the events of a stream until `until` (an event name) arrives: [{name, data}]."
  def events(socket, until, acc \\ "", timeout \\ 10_000) do
    receive do
      {:tcp, ^socket, data} ->
        text = acc <> data
        parsed = parse(text)

        if Enum.any?(parsed, &(elem(&1, 0) == until)),
          do: parsed,
          else: events(socket, until, text, timeout)

      {:tcp_closed, ^socket} ->
        %{status: status, body: body} = response(acc)
        [{"status", %{"status" => status, "body" => body}}]
    after
      timeout -> raise "no #{until} event in #{timeout} ms: #{inspect(parse(acc))}"
    end
  end

  def close(socket), do: :gen_tcp.close(socket)

  # The complete events of a stream read so far (an event ends with a blank line).
  defp parse(text) do
    text
    |> String.split("\n\n")
    |> Enum.drop(-1)
    |> Enum.flat_map(fn block ->
      lines = String.split(block, "\n")

      name =
        Enum.find_value(lines, &(String.starts_with?(&1, "event: ") && String.trim_leading(&1, "event: ")))

      data = Enum.find_value(lines, &(String.starts_with?(&1, "data: ") && String.trim_leading(&1, "data: ")))
      if name && data, do: [{name, JSON.decode!(data)}], else: []
    end)
  end

  @doc """
  Makes `dir` impossible to delete until the returned function is called: on Windows a process
  works in it (a folder in use cannot be removed), on Unix it is read-only (its files cannot be
  removed).
  """
  def lock(dir) do
    if Testor.OS.windows?() do
      # Erlang deletes read-only files and folders in use on Windows: a file held open without
      # sharing cannot be deleted by anyone.
      file = Path.join(dir, ".lock")
      File.write!(file, "")
      pwsh = System.find_executable("pwsh")
      script = "$f = [IO.File]::Open('#{file}', 'Open', 'Read', 'None'); 'locked'; Start-Sleep 300"
      port = Port.open({:spawn_executable, pwsh}, [:binary, :hide, args: ["-NoProfile", "-Command", script]])
      {:os_pid, pid} = Port.info(port, :os_pid)
      receive do: ({^port, {:data, "locked" <> _}} -> :ok), after: (15_000 -> raise("the lock did not start"))
      fn -> Testor.OS.kill_tree(pid) end
    else
      File.chmod!(dir, 0o555)
      fn -> File.chmod(dir, 0o755) end
    end
  end
end
