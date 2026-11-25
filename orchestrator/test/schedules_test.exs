defmodule Testor.SchedulesTest do
  @moduledoc "Cron expressions, and the schedules that queue jobs with them."
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn
  import ExUnit.CaptureLog
  alias Testor.{Config, Cron, Jobs, Schedules}
  alias Testor.Auth.{Guard, Password}
  alias Testor.Web.Router

  @password "correct horse battery"

  defp at(text), do: text |> DateTime.from_iso8601() |> elem(1)

  describe "cron" do
    test "fields, ranges, lists, steps and shorthands" do
      {:ok, spec} = Cron.parse("*/15 9-17 * * 1-5")
      assert Cron.matches?(spec, at("2026-11-25T09:30:00Z"))
      refute Cron.matches?(spec, at("2026-11-25T09:31:00Z"))
      refute Cron.matches?(spec, at("2026-11-28T09:30:00Z"))
      refute Cron.matches?(spec, at("2026-11-25T18:00:00Z"))

      {:ok, daily} = Cron.parse("@daily")
      assert Cron.next(daily, at("2026-11-25T10:00:00Z")) == at("2026-11-26T00:00:00Z")
      {:ok, list} = Cron.parse("0,30 1,2 * 1,12 *")
      assert Cron.next(list, at("2026-11-25T10:00:00Z")) == at("2026-12-01T01:00:00Z")

      # 7 is Sunday too; with a day and a weekday, either matches.
      {:ok, sunday} = Cron.parse("0 0 * * 7")
      assert Cron.matches?(sunday, at("2026-11-29T00:00:00Z"))
      {:ok, either} = Cron.parse("0 0 13 * 5")
      assert Cron.matches?(either, at("2026-11-13T00:00:00Z"))
      assert Cron.matches?(either, at("2026-11-27T00:00:00Z"))
      refute Cron.matches?(either, at("2026-11-26T00:00:00Z"))
      {:ok, monthly} = Cron.parse("0 0 1 * *")
      refute Cron.matches?(monthly, at("2026-11-02T00:00:00Z"))
      {:ok, steps} = Cron.parse("0 0-12/6 * * *")
      assert MapSet.to_list(steps.hour) |> Enum.sort() == [0, 6, 12]

      # Never: no 30th of February in the year ahead.
      {:ok, never} = Cron.parse("0 0 30 2 *")
      assert Cron.next(never, at("2026-11-25T10:00:00Z")) == nil
      # Within the minute: the next one, not this one.
      {:ok, every} = Cron.parse("* * * * *")
      assert Cron.next(every, at("2026-11-25T10:00:30Z")) == at("2026-11-25T10:01:00Z")
    end

    test "what is not an expression" do
      for bad <- [
            "* * * *",
            "60 * * * *",
            "* 24 * * *",
            "5-1 * * * *",
            "*/0 * * * *",
            "a * * * *",
            "1-2-3 * * * *",
            "*/2/3 * * * *",
            "1/x * * * *"
          ] do
        assert {:error, _} = Cron.parse(bad), bad
      end

      assert {:error, "a cron expression is a string"} = Cron.parse(5)
    end
  end

  describe "schedules" do
    setup do
      Guard.reset()
      :sys.replace_state(Jobs, fn _ -> %{} end)

      on_exit(fn ->
        File.rm(Path.join(Config.data_dir(), "config.json"))
        :sys.replace_state(Jobs, fn _ -> %{} end)
        Application.delete_env(:testor, :auth)
      end)
    end

    defp config(schedules, enabled \\ true) do
      File.write!(
        Path.join(Config.data_dir(), "config.json"),
        JSON.encode!(%{"execution" => %{"enabled" => enabled}, "schedules" => schedules})
      )
    end

    @nightly %{
      "name" => "nightly",
      "cron" => "0 2 * * *",
      "project" => "web",
      "kind" => "test",
      "labels" => ["linux"],
      "ref" => "main"
    }

    test "queue a job at their minute, none while the last is not over" do
      config([@nightly, %{"name" => "hourly", "cron" => "@hourly", "project" => "api", "kind" => "lint"}])

      assert [
               %{
                 "project" => "web",
                 "requestedBy" => "schedule:nightly",
                 "labels" => ["linux"],
                 "ref" => "main"
               },
               %{"project" => "api"}
             ] =
               Schedules.fire(at("2026-11-26T02:00:00Z"))

      assert Schedules.fire(at("2026-11-26T02:01:00Z")) == []
      # The last ones are still queued.
      capture_log(fn -> assert Schedules.fire(at("2026-11-27T02:00:00Z")) == [] end)

      for job <- Jobs.list(), do: Jobs.request_cancel(job["id"])
      assert [%{"project" => "web"}, _] = Schedules.fire(at("2026-11-27T02:00:00Z"))
    end

    test "nothing while jobs are off; a job testor refuses is logged" do
      config([@nightly], false)
      assert Schedules.fire(at("2026-11-26T02:00:00Z")) == []

      config([Map.put(@nightly, "ref", "-x")])
      log = capture_log(fn -> assert Schedules.fire(at("2026-11-26T02:00:00Z")) == [] end)
      assert log =~ "could not queue its job"
    end

    test "listed with their next time; those not valid say why, once" do
      config([
        @nightly,
        @nightly,
        %{"name" => "bad cron", "cron" => "* *"},
        %{"name" => "x", "cron" => "@daily", "project" => "a b", "kind" => "t"},
        %{"name" => "y", "cron" => "@daily", "project" => "a", "kind" => "t", "labels" => "linux"},
        %{"name" => "z", "cron" => "@daily", "project" => "a", "kind" => "t", "ref" => 5},
        %{"name" => "never", "cron" => "0 0 30 2 *", "project" => "a", "kind" => "t"},
        "nope"
      ])

      listed = Schedules.list(at("2026-11-25T10:00:00Z"))
      assert %{"name" => "nightly", "next" => "2026-11-26T02:00:00Z"} = hd(listed)
      assert Enum.at(listed, 1)["error"] =~ "another schedule"
      assert Enum.at(listed, 2)["error"] =~ "name"
      assert Enum.at(listed, 3)["error"] =~ "project and kind"
      assert Enum.at(listed, 4)["error"] =~ "labels"
      assert Enum.at(listed, 5)["error"] =~ "ref"
      assert %{"name" => "never", "next" => nil} = Enum.at(listed, 6)
      assert Enum.at(listed, 7)["error"] =~ "an object"

      log = capture_log(fn -> Schedules.fire(at("2026-11-25T10:00:00Z")) end)
      assert log =~ "another schedule has this name"
      assert capture_log(fn -> Schedules.fire(at("2026-11-25T10:01:00Z")) end) == ""

      File.write!(Path.join(Config.data_dir(), "config.json"), JSON.encode!(%{"schedules" => "daily"}))
      assert [%{"error" => "schedules is a list" <> _}] = Schedules.list()
      File.rm!(Path.join(Config.data_dir(), "config.json"))
      assert Schedules.list() == []
    end

    test "the minute's tick, and over HTTP for the projects one sees" do
      config([])
      # A tick schedules the next one (once here: they are off again after this test).
      Application.put_env(:testor, :schedule_ticks, true)
      on_exit(fn -> Application.put_env(:testor, :schedule_ticks, false) end)
      send(Schedules, :tick)
      send(Schedules, :tick)
      send(Schedules, :other)
      assert %{last: %DateTime{}} = :sys.get_state(Schedules)

      config([@nightly, Map.merge(@nightly, %{"name" => "other", "project" => "secret"})])
      hash = Password.hash(@password, 1000)

      Application.put_env(:testor, :auth, %{
        "users" => %{"web" => %{"password" => hash, "projects" => ["web"]}}
      })

      conn =
        conn(:get, "/api/v1/schedules")
        |> put_req_header("authorization", "Basic " <> Base.encode64("web:#{@password}"))
        |> Router.call(Router.init([]))

      assert %{"data" => [%{"name" => "nightly"}]} = JSON.decode!(conn.resp_body)
    end
  end
end
