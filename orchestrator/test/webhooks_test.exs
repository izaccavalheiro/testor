defmodule Testor.WebhooksTest do
  @moduledoc "Webhooks: configuration, filters, signed deliveries, retries, giving up."
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  import Testor.Test.Helpers
  alias Testor.{Store, Webhooks}

  @secret "a-webhook-secret-of-enough-length"

  setup do
    Application.put_env(:testor, :webhook_backoff_ms, [10])

    on_exit(fn ->
      File.rm(Webhooks.file())
      Application.delete_env(:testor, :webhook_backoff_ms)
    end)
  end

  # A receiver on a free port: answers each request with the next status of `statuses` (then
  # 200) and sends {:hook, headers, body} to the test.
  defp receiver(statuses) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true])
    {:ok, port} = :inet.port(listener)
    test = self()

    Task.start(fn -> serve(listener, statuses, test) end)
    port
  end

  defp serve(listener, statuses, test) do
    case :gen_tcp.accept(listener, 20_000) do
      {:ok, socket} ->
        {head, body} = read_request(socket, "")
        [status | rest] = if statuses == [], do: [200], else: statuses
        :gen_tcp.send(socket, "HTTP/1.1 #{status} X\r\ncontent-length: 0\r\nconnection: close\r\n\r\n")
        :gen_tcp.close(socket)
        send(test, {:hook, head, body})
        serve(listener, rest, test)

      _ ->
        :ok
    end
  end

  defp read_request(socket, acc) do
    case :binary.split(acc, "\r\n\r\n") do
      [head, body] ->
        [_, length] = Regex.run(~r/content-length: *(\d+)/i, head)
        length = String.to_integer(length)

        if byte_size(body) >= length,
          do: {String.downcase(head), body},
          else: read_more(socket, acc)

      _ ->
        read_more(socket, acc)
    end
  end

  defp read_more(socket, acc) do
    {:ok, data} = :gen_tcp.recv(socket, 0, 5_000)
    read_request(socket, acc <> data)
  end

  defp configure(endpoints), do: File.write!(Webhooks.file(), JSON.encode!(%{"endpoints" => endpoints}))

  defp hook_header(head, name) do
    [_, value] = Regex.run(~r/^#{name}: *([^\r\n]+)/m, head)
    value
  end

  test "a finished run is delivered signed; a 5xx answer is tried again" do
    port = receiver([500])

    configure([
      %{"url" => "http://127.0.0.1:#{port}/hook", "secret" => @secret, "events" => ["run.finished"]}
    ])

    id = record(%{"project" => "hooked"})
    on_exit(fn -> Store.delete(id) end)
    capture_log(fn -> finish(id, "passed") end)

    assert_receive {:hook, _, first}, 10_000
    assert_receive {:hook, head, body}, 10_000
    assert first != ""

    timestamp = hook_header(head, "x-testor-timestamp")
    assert hook_header(head, "x-testor-signature") == Webhooks.signature(@secret, timestamp, body)
    assert hook_header(head, "x-testor-event") == "run.finished"
    assert hook_header(head, "content-type") =~ "application/json"

    assert %{"event" => "run.finished", "run" => %{"id" => ^id, "status" => "passed"}, "links" => links} =
             JSON.decode!(body)

    assert links["attestation"] == "/api/v1/runs/#{id}/attestation"
    refute Map.has_key?(JSON.decode!(body)["run"], "pid")
  end

  test "endpoints for other projects or events are not called; an unknown run is nothing" do
    port = receiver([])

    configure([
      %{"url" => "http://127.0.0.1:#{port}/a", "secret" => @secret, "projects" => ["other"]},
      %{"url" => "http://127.0.0.1:#{port}/b", "secret" => @secret, "events" => ["run.started"]}
    ])

    id = record(%{"project" => "not-hooked"})
    on_exit(fn -> Store.delete(id) end)
    finish(id, "passed")
    refute_receive {:hook, _, _}, 500
    assert Webhooks.notify("run.finished", "nope") == :ok
  end

  test "an endpoint that never answers is given up on, and logged" do
    {:ok, listener} = :gen_tcp.listen(0, [])
    {:ok, closed} = :inet.port(listener)
    :gen_tcp.close(listener)
    endpoint = %{url: "http://127.0.0.1:#{closed}/", secret: @secret, events: nil, projects: nil}

    log =
      capture_log(fn -> assert {:error, _} = Webhooks.deliver(endpoint, "run.finished", %{"id" => "x"}) end)

    assert log =~ "trying again in 10 ms"
    assert log =~ "giving up on run.finished"
  end

  test "the file: missing, not valid, and endpoints without a usable url or secret" do
    File.rm(Webhooks.file())
    assert Webhooks.endpoints() == []

    File.write!(Webhooks.file(), "{nope")
    assert capture_log(fn -> assert Webhooks.endpoints() == [] end) =~ "is not valid"

    configure([
      %{"url" => "ftp://x", "secret" => @secret},
      %{"url" => "https://ok.example", "secret" => "short"},
      %{"url" => "https://ok.example", "secret" => @secret}
    ])

    assert [%{url: "https://ok.example", events: nil, projects: nil}] = Webhooks.endpoints()
    assert [timeout: _, connect_timeout: _, autoredirect: false, ssl: ssl] = Webhooks.http_options()
    assert ssl[:verify] == :verify_peer
  end
end
