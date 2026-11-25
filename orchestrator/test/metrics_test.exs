defmodule Testor.MetricsTest do
  use ExUnit.Case, async: false
  import Testor.Test.Helpers
  alias Testor.Metrics

  test "the exposition holds the runs, the latest result of each task, and the machine" do
    id = record(%{"project" => "metrics \"app\"", "kind" => "test"})
    # Other tests count failed runs: leave none behind.
    on_exit(fn -> Testor.Store.delete(id) end)
    finish(id, "failed")

    %{status: 200, body: body} = response = http(:get, "/metrics")
    assert header(response, "content-type") =~ "text/plain; version=0.0.4"
    assert body =~ ~r/^# HELP testor_build_info /m
    assert body =~ ~r/^testor_build_info\{version="[^"]+"\} 1$/m
    assert body =~ ~r/^testor_runs\{status="failed"\} [1-9]\d*$/m
    assert body =~ ~r/^testor_runs\{status="cancelled"\} \d+$/m
    assert body =~ ~s(testor_last_run_success{kind="test",project="metrics \\"app\\""} 0\n)
    assert body =~ ~r/^testor_last_run_duration_seconds\{kind="test",project="metrics \\"app\\""\} 1\.234$/m
    assert body =~ ~r/^testor_last_run_timestamp_seconds\{.*project="metrics \\"app\\""\} \d+$/m
    assert body =~ ~r/^testor_event_streams \d+$/m
    assert body =~ ~r/^testor_jobs\{status="queued"\} \d+$/m
  end

  test "a run without an end or a duration has no samples for them" do
    id = run_id()

    Testor.Files.write_json(Testor.Config.run_file(id), %{
      "id" => id,
      "project" => "metrics-bare",
      "kind" => "test",
      "status" => "failed",
      "startedAt" => DateTime.utc_now() |> DateTime.to_iso8601()
    })

    wait_until(fn -> Testor.Store.get(id) end)
    on_exit(fn -> Testor.Store.delete(id) end)
    body = IO.iodata_to_binary(Metrics.render())
    assert body =~ ~s(testor_last_run_success{kind="test",project="metrics-bare"} 0)
    refute body =~ ~s(testor_last_run_duration_seconds{kind="test",project="metrics-bare"})
    refute body =~ ~s(testor_last_run_timestamp_seconds{kind="test",project="metrics-bare"})
  end

  test "values a platform cannot give leave their sample out; label values are escaped" do
    assert Metrics.scale(50, 100) == 0.5
    assert Metrics.scale(nil, 100) == nil
    assert Metrics.sample("x", %{}, nil) == []
    assert IO.iodata_to_binary(Metrics.sample("x", %{"a" => "b"}, 2)) == ~s(x{a="b"} 2\n)
    assert Metrics.escape("a\\b\"c\nd") == ~S(a\\b\"c\nd)
  end
end
