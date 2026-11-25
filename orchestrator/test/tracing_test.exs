defmodule Testor.TracingTest.Collector do
  @moduledoc "An OTLP/HTTP collector for the tests: hands each request to the test that asked."
  use Plug.Router
  plug(:match)
  plug(:dispatch)

  post "/v1/traces" do
    {:ok, body, conn} = read_body(conn)
    send(Application.fetch_env!(:testor, :collector_test), {:otlp, conn.req_headers, JSON.decode!(body)})
    send_resp(conn, Application.get_env(:testor, :collector_status, 200), "{}")
  end
end

defmodule Testor.TracingTest do
  @moduledoc "OpenTelemetry spans of jobs and runs, sent to a collector."
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  import Testor.Test.Helpers
  alias Testor.{Config, Jobs, Store, Tracing}

  @trace "4bf92f3577b34da6a3ce929d0e0e4736"
  @parent "00f067aa0ba902b7"
  @incoming "00-#{@trace}-#{@parent}-01"

  setup do
    pid = start_supervised!({Bandit, plug: Testor.TracingTest.Collector, ip: :loopback, port: 0, startup_log: false})
    {:ok, {_, port}} = ThousandIsland.listener_info(pid)
    Application.put_env(:testor, :collector_test, self())
    System.put_env("OTEL_EXPORTER_OTLP_ENDPOINT", "http://127.0.0.1:#{port}/")
    :sys.replace_state(Jobs, fn _ -> %{} end)
    File.write!(Path.join(Config.data_dir(), "config.json"), JSON.encode!(%{"execution" => %{"enabled" => true}}))

    on_exit(fn ->
      for var <- ~w(OTEL_EXPORTER_OTLP_ENDPOINT OTEL_EXPORTER_OTLP_TRACES_ENDPOINT OTEL_EXPORTER_OTLP_HEADERS OTEL_RESOURCE_ATTRIBUTES OTEL_SERVICE_NAME),
          do: System.delete_env(var)

      Application.delete_env(:testor, :collector_test)
      Application.delete_env(:testor, :collector_status)
      File.rm(Path.join(Config.data_dir(), "config.json"))
      :sys.replace_state(Jobs, fn _ -> %{} end)
    end)

    %{port: port}
  end

  defp span(%{"resourceSpans" => [%{"scopeSpans" => [%{"spans" => [span]}]}]}), do: span
  defp attr(span, key), do: Enum.find_value(span["attributes"], &(&1["key"] == key && &1["value"]))

  test "traceparent: read, and given to jobs" do
    assert Tracing.parse(@incoming) == {:ok, @trace, @parent}
    assert Tracing.parse("00-#{String.duplicate("0", 32)}-#{@parent}-01") == :error
    assert Tracing.parse("00-#{@trace}-0000000000000000-01") == :error
    assert Tracing.parse("garbage") == :error
    assert Tracing.parse(5) == :error

    assert %{"traceparent" => "00-" <> @trace <> "-" <> _, "parentSpanId" => @parent} = Tracing.job_fields(@incoming)
    assert %{"traceparent" => own} = fresh = Tracing.job_fields(nil)
    refute Map.has_key?(fresh, "parentSpanId")
    assert {:ok, _, _} = Tracing.parse(own)

    assert {:error, "traceparent is" <> _} =
             Jobs.enqueue(%{"project" => "web", "kind" => "test", "traceparent" => "x"}, "ada")
  end

  test "a job's span joins CI's trace; its run is a child of it" do
    System.put_env("OTEL_EXPORTER_OTLP_HEADERS", "authorization=Bearer%20k,x-team=qa")
    System.put_env("OTEL_RESOURCE_ATTRIBUTES", "deployment.environment=ci, team=qa")
    System.put_env("OTEL_SERVICE_NAME", "testor-ci")

    {:ok, job} = Jobs.enqueue(%{"project" => "web", "kind" => "test", "traceparent" => @incoming, "ref" => "main"}, "ada")
    Jobs.request_cancel(job["id"])

    assert_receive {:otlp, headers, request}, 5_000
    assert {"authorization", "Bearer k"} in headers and {"x-team", "qa"} in headers
    [%{"resource" => %{"attributes" => resource}}] = request["resourceSpans"]
    keys = Map.new(resource, &{&1["key"], &1["value"]["stringValue"]})
    assert %{"service.name" => "testor-ci", "deployment.environment" => "ci", "team" => "qa"} = keys

    job_span = span(request)
    assert %{"traceId" => @trace, "parentSpanId" => @parent, "name" => "job web test", "status" => %{"code" => 0}} = job_span
    assert attr(job_span, "testor.job.status") == %{"stringValue" => "cancelled"}
    assert attr(job_span, "testor.job.attempts") == %{"intValue" => "0"}
    assert attr(job_span, "vcs.ref.head.name") == %{"stringValue" => "main"}

    # The run the agent started for it carries the job's traceparent.
    "00-" <> rest = Jobs.get(job["id"])["traceparent"]
    [_trace, job_span_id, _] = String.split(rest, "-")
    id = record(%{"project" => "web", "traceparent" => Jobs.get(job["id"])["traceparent"], "exitCode" => 1, "summary" => %{"passed" => 3, "failed" => 1}})
    on_exit(fn -> Store.delete(id) end)
    capture_log(fn -> finish(id, "failed") end)

    assert_receive {:otlp, _, run_request}, 5_000
    run_span = span(run_request)
    assert %{"traceId" => @trace, "parentSpanId" => ^job_span_id, "name" => "run web test", "status" => %{"code" => 2}} = run_span
    assert attr(run_span, "process.exit.code") == %{"intValue" => "1"}
    assert attr(run_span, "testor.specs.failed") == %{"intValue" => "1"}
    assert String.to_integer(run_span["endTimeUnixNano"]) >= String.to_integer(run_span["startTimeUnixNano"])
  end

  test "a run started by hand is a trace of its own; a passed one is OK", %{port: port} do
    System.delete_env("OTEL_EXPORTER_OTLP_ENDPOINT")
    System.put_env("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT", "http://127.0.0.1:#{port}/v1/traces")
    id = record(%{"project" => "local"})
    on_exit(fn -> Store.delete(id) end)
    capture_log(fn -> finish(id, "passed") end)

    assert_receive {:otlp, _, request}, 5_000
    run_span = span(request)
    assert %{"status" => %{"code" => 1}} = run_span
    refute Map.has_key?(run_span, "parentSpanId")
    assert byte_size(run_span["traceId"]) == 32
  end

  test "off, or without what a span needs: nothing is sent" do
    System.delete_env("OTEL_EXPORTER_OTLP_ENDPOINT")
    System.put_env("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT", "")
    assert Tracing.endpoint() == nil
    assert Tracing.run_ended(%{"startedAt" => "2026-11-25T10:00:00Z"}) == :ok
    assert Tracing.job_ended(%{"traceparent" => @incoming}) == :ok
    refute_receive {:otlp, _, _}, 300

    System.put_env("OTEL_EXPORTER_OTLP_ENDPOINT", "http://127.0.0.1:1")
    # A job from before tracing has no traceparent; a run that never started has no span.
    assert Tracing.job_ended(%{"status" => "passed"}) == :ok
    assert Tracing.run_ended(%{"status" => "aborted"}) == :ok
  end

  test "the span's shape, and a collector that refuses or cannot be reached" do
    span =
      Tracing.request(%{
        trace: @trace,
        span: @parent,
        parent: nil,
        name: "x",
        start: "2026-11-25T10:00:00Z",
        end: nil,
        ok: false,
        error: false,
        attributes: %{"flag" => true, "n" => 3, "s" => :atom, "none" => nil}
      })
      |> span()

    assert span["startTimeUnixNano"] == span["endTimeUnixNano"]
    assert [%{"key" => "flag", "value" => %{"boolValue" => true}}, %{"key" => "n"}, %{"key" => "s", "value" => %{"stringValue" => "atom"}}] = span["attributes"]

    Application.put_env(:testor, :collector_status, 500)

    log =
      capture_log(fn ->
        Tracing.run_ended(%{"startedAt" => "not a time", "endedAt" => "2026-11-25T10:00:00Z", "status" => "cancelled"})
        assert_receive {:otlp, _, _}, 5_000
        Process.sleep(200)
      end)

    assert log =~ "answered 500"

    System.put_env("OTEL_EXPORTER_OTLP_ENDPOINT", "http://127.0.0.1:1")

    log =
      capture_log(fn ->
        Tracing.run_ended(%{"startedAt" => "2026-11-25T10:00:00Z", "status" => "passed"})
        Process.sleep(500)
      end)

    assert log =~ "cannot be reached"
  end
end
