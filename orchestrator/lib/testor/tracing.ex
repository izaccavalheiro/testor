defmodule Testor.Tracing do
  @moduledoc """
  OpenTelemetry traces of jobs and runs, sent as OTLP/HTTP JSON to a collector (the
  OpenTelemetry Collector, Grafana Tempo or Alloy, Jaeger, Honeycomb, Datadog...), with no SDK:

    * a **job** is a span from when it was queued to its end;
    * its **run** is a child span from start to end, with the run's project, kind, status,
      exit code and spec counts;
    * a run started by hand is a trace of its own.

  A job queued with a W3C `traceparent` (CI's own trace, `POST /api/v1/jobs`) joins that trace:
  the pipeline, its test job and the run show as one. The agent gives the run `TRACEPARENT`,
  which `run.ps1` records and test tools that propagate W3C trace context can read.

  Off until the standard variables name a collector:

    * `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` (the full URL), or `OTEL_EXPORTER_OTLP_ENDPOINT`
      (its base; `/v1/traces` is added);
    * `OTEL_EXPORTER_OTLP_HEADERS` (`key=value,...`, URL-encoded: an API key);
    * `OTEL_SERVICE_NAME` (`testor`) and `OTEL_RESOURCE_ATTRIBUTES` (`key=value,...`).

  Spans are sent once, in the background; a collector that cannot be reached is logged.
  """
  require Logger
  alias Testor.Webhooks

  @traceparent ~r/^00-([0-9a-f]{32})-([0-9a-f]{16})-[0-9a-f]{2}$/
  @zero_trace String.duplicate("0", 32)
  @zero_span String.duplicate("0", 16)

  @doc "The trace and span ids of a W3C `traceparent`: `{:ok, trace, span}`, or `:error`."
  def parse(traceparent) when is_binary(traceparent) do
    case Regex.run(@traceparent, traceparent) do
      [_, trace, span] when trace != @zero_trace and span != @zero_span -> {:ok, trace, span}
      _ -> :error
    end
  end

  def parse(_), do: :error

  @doc """
  The trace fields of a new job: its own `traceparent` (the run's parent), and the span it was
  queued under (`parentSpanId`) when `incoming` is CI's `traceparent`.
  """
  def job_fields(incoming) do
    span = hex(8)

    case parse(incoming) do
      {:ok, trace, parent} -> %{"traceparent" => "00-#{trace}-#{span}-01", "parentSpanId" => parent}
      :error -> %{"traceparent" => "00-#{hex(16)}-#{span}-01"}
    end
  end

  @doc "Sends the span of a job that has ended."
  def job_ended(job) do
    with true <- enabled?(),
         {:ok, trace, span} <- parse(job["traceparent"]) do
      export(%{
        trace: trace,
        span: span,
        parent: job["parentSpanId"],
        name: "job #{job["project"]} #{job["kind"]}",
        start: job["createdAt"],
        end: job["endedAt"],
        ok: job["status"] == "passed",
        error: job["status"] in ["failed", "expired"],
        attributes: %{
          "testor.job.id" => job["id"],
          "testor.project" => job["project"],
          "testor.kind" => job["kind"],
          "testor.job.status" => job["status"],
          "testor.job.attempts" => job["attempts"],
          "testor.job.agent" => job["agent"],
          "testor.job.requested_by" => job["requestedBy"],
          "testor.run.id" => job["runId"],
          "vcs.ref.head.name" => job["ref"]
        }
      })
    else
      _ -> :ok
    end
  end

  @doc "Sends the span of a run that has ended (under its job's span when it has one)."
  def run_ended(run) do
    if enabled?() and is_binary(run["startedAt"]) do
      {trace, parent} =
        case parse(run["traceparent"]) do
          {:ok, trace, parent} -> {trace, parent}
          :error -> {hex(16), nil}
        end

      summary = run["summary"] || %{}

      export(%{
        trace: trace,
        span: hex(8),
        parent: parent,
        name: "run #{run["project"]} #{run["kind"]}",
        start: run["startedAt"],
        end: run["endedAt"],
        ok: run["status"] == "passed",
        error: run["status"] in ["failed", "aborted"],
        attributes: %{
          "testor.run.id" => run["id"],
          "testor.project" => run["project"],
          "testor.kind" => run["kind"],
          "testor.run.status" => run["status"],
          "process.exit.code" => run["exitCode"],
          "testor.job.id" => run["job"],
          "testor.run.remote" => run["remote"],
          "testor.specs.passed" => summary["passed"],
          "testor.specs.failed" => summary["failed"],
          "vcs.ref.head.revision" => get_in(run, ["source", "commit"])
        }
      })
    else
      :ok
    end
  end

  @doc "Where spans go: the traces endpoint, or nil (off)."
  def endpoint do
    case {System.get_env("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT"), System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT")} do
      {traces, _} when traces not in [nil, ""] -> traces
      {_, base} when base not in [nil, ""] -> String.trim_trailing(base, "/") <> "/v1/traces"
      _ -> nil
    end
  end

  defp enabled?, do: endpoint() != nil

  defp export(span) do
    url = endpoint()
    body = JSON.encode!(request(span))
    Task.Supervisor.start_child(Testor.TaskSupervisor, fn -> send_spans(url, body) end)
    :ok
  end

  @doc "The OTLP/JSON request holding `span`."
  def request(span) do
    %{
      "resourceSpans" => [
        %{
          "resource" => %{"attributes" => attributes(resource())},
          "scopeSpans" => [
            %{
              "scope" => %{"name" => "testor", "version" => version()},
              "spans" => [otlp_span(span)]
            }
          ]
        }
      ]
    }
  end

  defp otlp_span(span) do
    # A record whose start cannot be read still gives a span: at the time it is sent.
    start = nanos(span.start) || System.os_time(:nanosecond)

    %{
      "traceId" => span.trace,
      "spanId" => span.span,
      "name" => span.name,
      # INTERNAL; a job is the work CI asked for, its run the work done.
      "kind" => 1,
      "startTimeUnixNano" => Integer.to_string(start),
      "endTimeUnixNano" => Integer.to_string(max(nanos(span.end) || start, start)),
      "attributes" => attributes(span.attributes),
      "status" => %{"code" => status_code(span)}
    }
    |> then(&if(span.parent, do: Map.put(&1, "parentSpanId", span.parent), else: &1))
  end

  # OK, ERROR, or UNSET (cancelled: neither).
  defp status_code(%{ok: true}), do: 1
  defp status_code(%{error: true}), do: 2
  defp status_code(_span), do: 0

  defp nanos(nil), do: nil

  defp nanos(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, at, _} -> DateTime.to_unix(at, :nanosecond)
      _ -> nil
    end
  end

  defp attributes(map) do
    for {key, value} <- Enum.sort(map), value != nil do
      %{"key" => key, "value" => value(value)}
    end
  end

  defp value(v) when is_integer(v), do: %{"intValue" => Integer.to_string(v)}
  defp value(v) when is_boolean(v), do: %{"boolValue" => v}
  defp value(v), do: %{"stringValue" => to_string(v)}

  defp resource do
    extra = pairs(System.get_env("OTEL_RESOURCE_ATTRIBUTES"))

    Map.merge(
      %{
        "service.name" => System.get_env("OTEL_SERVICE_NAME") || "testor",
        "service.version" => version(),
        "host.name" => hostname()
      },
      extra
    )
  end

  # key=value,key=value with URL-encoded values, as the OpenTelemetry environment variables are.
  defp pairs(nil), do: %{}

  defp pairs(text) do
    for pair <- String.split(text, ","),
        [key, value] <- [String.split(pair, "=", parts: 2)],
        String.trim(key) != "",
        into: %{},
        do: {String.trim(key), URI.decode(String.trim(value))}
  end

  defp send_spans(url, body) do
    headers =
      for {key, value} <- pairs(System.get_env("OTEL_EXPORTER_OTLP_HEADERS")),
          do: {String.to_charlist(key), String.to_charlist(value)}

    request = {String.to_charlist(url), headers, ~c"application/json", body}

    case :httpc.request(:post, request, Webhooks.http_options(), body_format: :binary) do
      {:ok, {{_, status, _}, _, _}} when status in 200..299 -> :ok
      {:ok, {{_, status, _}, _, _}} -> Logger.warning("tracing: #{url} answered #{status}")
      {:error, reason} -> Logger.warning("tracing: #{url} cannot be reached (#{inspect(reason)})")
    end
  end

  defp version, do: to_string(Application.spec(:testor, :vsn))
  defp hostname, do: :inet.gethostname() |> elem(1) |> to_string()
  defp hex(bytes), do: :crypto.strong_rand_bytes(bytes) |> Base.encode16(case: :lower)
end
