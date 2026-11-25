defmodule Testor.DoraTest do
  @moduledoc "DORA's four metrics from a project's deploy runs."
  use ExUnit.Case, async: false
  import Plug.Test
  import Testor.Test.Helpers
  alias Testor.{Dora, Store}
  alias Testor.Web.Router

  @now ~U[2026-11-25 12:00:00Z]

  defp at(hours_ago), do: @now |> DateTime.add(round(-hours_ago * 3600)) |> DateTime.to_iso8601()

  defp deploy(status, ended_hours_ago, extra \\ %{}) do
    id =
      record(
        Map.merge(
          %{
            "project" => "shop",
            "kind" => "deploy",
            "status" => status,
            "startedAt" => at(ended_hours_ago + 0.1),
            "endedAt" => at(ended_hours_ago),
            "summary" => %{}
          },
          extra
        )
      )

    on_exit(fn -> Store.delete(id) end)
    wait_until(fn -> Store.get(id) end)
    id
  end

  test "frequency, failure rate, time to restore and lead time" do
    # Oldest first: a pass, then a failure streak restored 3 h after it began, a pass, a
    # failure restored after 1 h, and a cancelled run (neither) and a run outside the window.
    deploy("passed", 100, %{"source" => %{"committedAt" => at(104)}})
    deploy("failed", 90)
    deploy("failed", 88)
    deploy("passed", 87, %{"source" => %{"committedAt" => at(89)}})
    deploy("passed", 50)
    deploy("failed", 10)
    deploy("passed", 9, %{"source" => %{"committedAt" => "not a time"}})
    deploy("cancelled", 5)
    deploy("passed", 24 * 40)
    deploy("passed", 1, %{"kind" => "test"})

    assert %{
             "deployments" => 4,
             "failures" => 3,
             "changeFailureRate" => 0.429,
             "restores" => 2,
             # 3 h and 1 h: the median of two is their mean.
             "medianTimeToRestoreSeconds" => 7200,
             "leadTimes" => 2,
             "medianLeadTimeSeconds" => 10_800,
             "deploymentsPerWeek" => 0.93,
             "days" => 30
           } = Dora.metrics("shop", "deploy", 30, @now)

    # Three values: the middle one.
    deploy("passed", 2, %{"source" => %{"committedAt" => at(3)}})
    assert %{"medianLeadTimeSeconds" => 7200} = Dora.metrics("shop", "deploy", 30, @now)
  end

  test "no runs: no rates" do
    assert %{
             "deployments" => 0,
             "changeFailureRate" => nil,
             "medianTimeToRestoreSeconds" => nil,
             "medianLeadTimeSeconds" => nil
           } =
             Dora.metrics("nothing", "deploy", 7, @now)
  end

  test "over HTTP: deploy and 30 days by default, or as asked" do
    get = fn path ->
      conn(:get, path) |> Router.call(Router.init([])) |> Map.fetch!(:resp_body) |> JSON.decode!()
    end

    assert %{"kind" => "deploy", "days" => 30} = get.("/api/v1/projects/shop/dora")
    assert %{"kind" => "release", "days" => 365} = get.("/api/v1/projects/shop/dora?kind=release&days=9999")
  end
end
