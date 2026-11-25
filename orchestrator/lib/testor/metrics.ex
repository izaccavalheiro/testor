defmodule Testor.Metrics do
  @moduledoc """
  `GET /metrics`: Prometheus text exposition (version 0.0.4), with the `read` scope like the
  rest of the API (Prometheus sends Basic credentials or a Bearer token from its scrape config).

  The run index is the source, so the run figures are gauges of what testor keeps (retention
  deletes old runs), not counters:

    * `testor_build_info{version}`
    * `testor_runs{status}`: runs kept, by status
    * `testor_last_run_success{project,kind}`: 1 when the latest finished run of a task passed
    * `testor_last_run_timestamp_seconds{project,kind}`, `testor_last_run_duration_seconds{project,kind}`
    * `testor_event_streams`: open dashboard and API event streams
    * `testor_disk_free_bytes`, `testor_disk_size_bytes`: the volume of the testor home
    * `testor_stored_bytes{area}`: screenshots and artifacts kept
    * `testor_cpu_ratio`, `testor_memory_available_bytes`, `testor_memory_total_bytes`
  """
  alias Testor.{Device, Query, Stats, Store}

  @doc "The exposition text."
  def render do
    runs = Store.all()
    stats = Stats.get()
    device = Device.snapshot()
    sample = device["sample"] || %{}
    static = device["static"] || %{}

    [
      family("testor_build_info", "gauge", "testor's version", [
        sample("testor_build_info", %{"version" => to_string(Application.spec(:testor, :vsn))}, 1)
      ]),
      family("testor_runs", "gauge", "runs kept, by status", runs_by_status(runs)),
      last_runs(runs),
      family("testor_event_streams", "gauge", "open event streams", [
        sample("testor_event_streams", %{}, Registry.count(Testor.StreamRegistry))
      ]),
      family("testor_disk_free_bytes", "gauge", "free space of the testor home's volume", [
        sample("testor_disk_free_bytes", %{}, get_in(stats, ["disk", "free"]))
      ]),
      family("testor_disk_size_bytes", "gauge", "size of the testor home's volume", [
        sample("testor_disk_size_bytes", %{}, get_in(stats, ["disk", "total"]))
      ]),
      family("testor_stored_bytes", "gauge", "screenshots and artifacts kept", [
        sample("testor_stored_bytes", %{"area" => "screenshots"}, get_in(stats, ["screenshots", "bytes"])),
        sample("testor_stored_bytes", %{"area" => "artifacts"}, get_in(stats, ["artifacts", "bytes"]))
      ]),
      family("testor_cpu_ratio", "gauge", "CPU in use, 0 to 1", [
        sample("testor_cpu_ratio", %{}, scale(sample["cpu"], 100))
      ]),
      family("testor_memory_available_bytes", "gauge", "memory available", [
        sample("testor_memory_available_bytes", %{}, get_in(sample, ["memory", "available"]))
      ]),
      family("testor_memory_total_bytes", "gauge", "memory installed", [
        sample("testor_memory_total_bytes", %{}, get_in(static, ["memory", "total"]))
      ])
    ]
  end

  defp runs_by_status(runs) do
    counts = Enum.frequencies_by(runs, & &1["status"])

    for status <- Query.statuses(),
        do: sample("testor_runs", %{"status" => status}, Map.get(counts, status, 0))
  end

  # The newest finished run of each project and task.
  defp last_runs(runs) do
    latest =
      runs
      |> Enum.reject(&(&1["status"] == "running"))
      |> Enum.group_by(&{&1["project"], &1["kind"]})
      |> Enum.map(fn {_, [newest | _]} -> newest end)

    labels = &%{"project" => &1["project"], "kind" => &1["kind"]}

    [
      family(
        "testor_last_run_success",
        "gauge",
        "1 when the latest run of a task passed",
        for(
          run <- latest,
          do: sample("testor_last_run_success", labels.(run), if(run["status"] == "passed", do: 1, else: 0))
        )
      ),
      family(
        "testor_last_run_timestamp_seconds",
        "gauge",
        "when the latest run of a task ended",
        for(
          run <- latest,
          do: sample("testor_last_run_timestamp_seconds", labels.(run), unix(run["endedAt"]))
        )
      ),
      family(
        "testor_last_run_duration_seconds",
        "gauge",
        "how long the latest run of a task took",
        for(
          run <- latest,
          do: sample("testor_last_run_duration_seconds", labels.(run), scale(run["durationMs"], 1000))
        )
      )
    ]
  end

  defp family(name, type, help, samples), do: ["# HELP #{name} #{help}\n# TYPE #{name} #{type}\n", samples]

  @doc "One sample line; nothing when the value is not a number (a platform that cannot tell)."
  def sample(name, labels, value) when is_number(value) do
    [name, labels(labels), " ", to_string(value), "\n"]
  end

  def sample(_name, _labels, _value), do: []

  defp labels(labels) when map_size(labels) == 0, do: ""

  defp labels(labels) do
    pairs = labels |> Enum.sort() |> Enum.map_join(",", fn {k, v} -> ~s(#{k}="#{escape(v)}") end)
    "{" <> pairs <> "}"
  end

  @doc "A label value escaped for the exposition format: backslash, double quote, line feed."
  def escape(value) do
    value
    |> to_string()
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("\n", "\\n")
  end

  @doc "`value / divisor` (a percentage as a ratio, milliseconds as seconds), nil for a value that is not a number."
  def scale(value, divisor) when is_number(value), do: value / divisor
  def scale(_value, _divisor), do: nil

  defp unix(time) do
    case Store.parse_time(time) do
      {:ok, time} -> DateTime.to_unix(time)
      _ -> nil
    end
  end
end
