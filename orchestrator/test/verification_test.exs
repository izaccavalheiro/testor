defmodule Testor.VerificationTest do
  @moduledoc """
  AI-era verification and zero-config (docs/mcp.md, docs/zero-config.md): the MCP tools that
  queue work, with their budget; predictive sizing; preemption; capacity.
  """
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  import Testor.Test.Helpers
  alias Testor.{Budget, Config, Files, Jobs, Reports, Sizing, Snapshots, Store}
  alias Testor.MCP.Tools

  @admin %{sub: "ada", scopes: ["read", "operate", "execute"], via: :basic}
  @viewer %{sub: "val", scopes: ["read"], via: :basic}

  setup do
    Jobs.reset()
    Budget.reset()
    for dir <- ["cas", "snapshots"], do: File.rm_rf!(Path.join(Config.data_dir(), dir))
    config(%{})

    on_exit(fn ->
      File.rm(Path.join(Config.data_dir(), "config.json"))
      Jobs.reset()
      Budget.reset()
    end)
  end

  defp config(extra) do
    File.write!(
      Path.join(Config.data_dir(), "config.json"),
      JSON.encode!(Map.merge(%{"execution" => %{"enabled" => true}}, extra))
    )
  end

  defp call(tool, args, principal \\ @admin) do
    {:ok, result} = Tools.call(tool, args, principal, "http://testor")

    if result["isError"],
      do: {:error, hd(result["content"])["text"]},
      else: {:ok, result["structuredContent"] || hd(result["content"])["text"]}
  end

  defp sha(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)

  defp snapshot!(project, files) do
    entries =
      for {path, data} <- files do
        tmp = Path.join(System.tmp_dir!(), "v-#{System.unique_integer([:positive])}")
        File.write!(tmp, data)
        :ok = Snapshots.put_blob(sha(data), tmp)
        File.rm(tmp)
        %{"path" => path, "sha256" => sha(data), "size" => byte_size(data)}
      end

    {:ok, %{"id" => id}} = Snapshots.offer(project, %{"files" => entries, "branch" => "main"})
    id
  end

  # A finished run of `project`'s `kind` that took `ms` and peaked at `mb`.
  defp history!(project, kind, ms, mb) do
    id = record(%{"project" => project, "kind" => kind})
    finish(id, "passed", %{"durationMs" => ms, "memory" => %{"peakMB" => mb}})
    on_exit(fn -> Store.delete(id) end)
  end

  describe "the budget" do
    test "per minute and per day, per caller" do
      config(%{"mcp" => %{"jobBudget" => %{"perMinute" => 2, "perDay" => 3}}})
      now = 1_000_000
      assert Budget.take("ada", now) == :ok
      assert Budget.take("ada", now) == :ok
      assert {:error, minute} = Budget.take("ada", now)
      assert minute =~ "perMinute"
      assert Budget.left("ada", now) == %{"minute" => 0, "day" => 1}
      assert Budget.take("ada", now + 60) == :ok
      assert {:error, day} = Budget.take("ada", now + 120)
      assert day =~ "perDay"
      assert Budget.take("bob", now) == :ok
      assert Budget.settings() == %{"perMinute" => 2, "perDay" => 3}
    end
  end

  describe "MCP tools that queue work" do
    test "queue_job and offload_change: the execute scope, the project, the budget; never a command" do
      snap = snapshot!("web", %{"a.test.ts" => "a"})
      assert {:error, scope} = call("queue_job", %{"project" => "web", "kind" => "test"}, @viewer)
      assert scope =~ "execute"

      assert {:ok, %{"job" => %{"id" => _, "kind" => "test"}, "budget" => %{"minute" => 9}}} =
               call("queue_job", %{"project" => "web", "kind" => "test", "argv" => ["rm", "-rf", "/"]})

      assert [%{"kind" => "test"} = job] = Jobs.list("queued")
      refute Map.has_key?(job, "argv")

      assert {:ok, %{"job" => %{"snapshot" => ^snap, "kind" => "test"}}} =
               call("offload_change", %{
                 "project" => "web",
                 "snapshot" => snap,
                 "select" => %{"files" => ["a.test.ts"]}
               })

      restricted = %{@admin | sub: "lib"} |> Map.put(:projects, ["lib"])
      assert {:error, project} = call("queue_job", %{"project" => "web", "kind" => "test"}, restricted)
      assert project =~ "lacks the execute scope"
      assert {:error, bad} = call("queue_job", %{"project" => "web", "kind" => "a b"})
      assert bad =~ "kind"

      config(%{"execution" => %{"enabled" => false}})
      assert {:error, off} = call("queue_job", %{"project" => "web", "kind" => "test"})
      assert off =~ "jobs are off"

      config(%{"mcp" => %{"jobBudget" => %{"perMinute" => 0}}})
      assert {:error, spent} = call("queue_job", %{"project" => "web", "kind" => "test"})
      assert spent =~ "perMinute"
    end

    test "run_mutation_check: the changed files only, then the survivors, fenced" do
      snap = snapshot!("lib", %{"src/a.ts" => "a"})

      assert {:error, _} =
               call("run_mutation_check", %{"project" => "lib", "snapshot" => snap, "files" => ["../x"]})

      assert {:error, _} =
               call("run_mutation_check", %{"project" => "lib", "snapshot" => snap, "files" => []})

      assert {:error, _} =
               call("run_mutation_check", %{
                 "project" => "lib",
                 "snapshot" => snap,
                 "files" => ["src/a.ts"],
                 "wait" => 9999
               })

      assert {:ok, %{"job" => %{"status" => "queued"}, "message" => _}} =
               call("run_mutation_check", %{"project" => "lib", "snapshot" => snap, "files" => ["src/a.ts"]})

      Jobs.reset()

      check =
        Task.async(fn ->
          call("run_mutation_check", %{
            "project" => "lib",
            "snapshot" => snap,
            "files" => ["src/a.ts"],
            "wait" => 20
          })
        end)

      %{"id" => job, "select" => %{"files" => ["src/a.ts"]}, "kind" => "mutation"} =
        wait_until(fn -> List.first(Jobs.list("queued")) end)

      {:ok, _} = Jobs.lease("bot", [])
      run = record(%{"project" => "lib", "kind" => "mutation", "job" => job})

      Files.write_json(Reports.detail_file(run), %{
        "survivors" => [%{"file" => "src/a.ts", "line" => 3, "original" => "a + b", "replacement" => "a - b"}]
      })

      on_exit(fn ->
        File.rm(Reports.detail_file(run))
        Store.delete(run)
      end)

      finish(run, "failed", %{"mutation" => %{"score" => 50.0}, "summary" => %{}})
      {:ok, _} = Jobs.finish(job, "bot", %{"exitCode" => 1})

      assert {:ok,
              %{"job" => %{"status" => "failed"}, "mutation" => %{"score" => 50.0}, "survivors" => survivors}} =
               Task.await(check, 30_000)

      assert survivors =~ "<untrusted-output" and survivors =~ "a - b"
    end

    test "sessions: opened, fed, read" do
      first = snapshot!("live", %{"a.ts" => "1"})
      second = snapshot!("live", %{"a.ts" => "2"})

      assert {:ok, %{"job" => %{"id" => session, "watch" => true}}} =
               call("open_session", %{"project" => "live", "snapshot" => first})

      assert {:ok, %{"seq" => 1}} = call("push_change", %{"session" => session, "snapshot" => second})

      assert {:error, "snapshot is sha256:<hex>"} =
               call("push_change", %{"session" => session, "snapshot" => "x"})

      assert {:error, _} =
               call("push_change", %{"session" => session, "snapshot" => "sha256:" <> sha("none")})

      assert {:error, "no session"} = call("push_change", %{"session" => "nope", "snapshot" => second})
      {:ok, %{"job" => %{"id" => plain}}} = call("queue_job", %{"project" => "live", "kind" => "test"})
      assert {:error, "no session"} = call("push_change", %{"session" => plain, "snapshot" => second})

      assert {:error, "no session"} =
               call(
                 "push_change",
                 %{"session" => session, "snapshot" => second},
                 Map.put(@admin, :projects, ["other"])
               )

      run = record(%{"project" => "live", "kind" => "watch", "job" => session, "session" => session})
      finish(run)
      on_exit(fn -> Store.delete(run) end)

      assert {:ok, %{"session" => %{"seq" => 1}, "runs" => [%{"id" => ^run}], "digest" => digest}} =
               call("get_session_results", %{"session" => session})

      assert digest =~ "untrusted-output"
      assert {:error, "no session"} = call("get_session_results", %{"session" => "nope"})
      assert {:error, "no session"} = call("get_session_results", %{"session" => plain})

      assert {:error, "no session"} =
               call(
                 "get_session_results",
                 %{"session" => session},
                 %{@viewer | sub: "x"} |> Map.put(:projects, ["other"])
               )

      capture_log(fn -> Jobs.cancel(session) end)

      assert {:error, "the session has ended"} =
               call("push_change", %{"session" => session, "snapshot" => first})
    end

    test "get_run_digest and get_capacity" do
      id = record(%{"project" => "dig"})
      finish(id, "failed")
      on_exit(fn -> Store.delete(id) end)
      assert {:ok, text} = call("get_run_digest", %{"id" => id}, @viewer)
      assert text =~ "dig test: failed"
      assert {:error, _} = call("get_run_digest", %{"id" => "nope"}, @viewer)

      Jobs.seen("bot/a", ["linux", "gpu"], 4, 1)
      Jobs.seen("bot/b", ["linux"], 1, 0)
      {:ok, j} = Jobs.enqueue(%{"project" => "cap", "kind" => "test", "labels" => ["gpu"]}, "ada")
      {:ok, _} = Jobs.enqueue(%{"project" => "cap2", "kind" => "test"}, "ada")
      {:ok, _} = Jobs.lease("bot", ["gpu"])
      assert j["status"] == "queued"

      assert {:ok,
              %{
                "agents" => 2,
                "agentsByLabel" => %{"linux" => 2, "gpu" => 1},
                "slots" => 5,
                "freeSlots" => 4,
                "queued" => 1,
                "estimatedWaitSeconds" => wait
              }} =
               call("get_capacity", %{}, @viewer)

      assert is_number(wait)
    end
  end

  describe "sizing" do
    test "history: p50 and p95 duration, p95 peak memory" do
      assert Sizing.estimate("sz", "test") == %{"runs" => 0, "p50Ms" => nil, "p95Ms" => nil, "peakMB" => nil}
      for {ms, mb} <- [{60_000, 500}, {120_000, 900}, {1_200_000, 3000}], do: history!("sz", "test", ms, mb)

      assert %{"runs" => 3, "p50Ms" => 120_000, "p95Ms" => 1_200_000, "peakMB" => 3000} =
               Sizing.estimate("sz", "test")
    end

    test "shards auto: a shard per target's worth of the p95, within capacity; a fitting task runs alone" do
      assert {:error, history} =
               Jobs.enqueue(
                 %{"project" => "auto", "kind" => "test", "shards" => "auto", "target" => "5m"},
                 "ada"
               )

      assert history =~ "needs history"

      assert {:error, target} =
               Jobs.enqueue(%{"project" => "auto", "kind" => "test", "shards" => "auto"}, "ada")

      assert target =~ "needs a target"

      assert {:error, _} =
               Jobs.enqueue(
                 %{"project" => "auto", "kind" => "test", "shards" => "auto", "target" => "soon"},
                 "ada"
               )

      assert {:error, _} =
               Jobs.enqueue(%{"project" => 5, "kind" => "test", "shards" => "auto", "target" => "5m"}, "ada")

      history!("auto", "test", 1_200_000, 100)
      Jobs.seen("bot/a", ["linux"], 3, 0)

      assert {:ok, %{"batch" => true, "shards" => 3}} =
               Jobs.enqueue(
                 %{"project" => "auto", "kind" => "test", "shards" => "auto", "target" => "5m"},
                 "ada"
               )

      assert {:ok, %{"shards" => 2}} =
               Jobs.enqueue(%{"project" => "auto", "kind" => "t", "shards" => 2}, "ada")

      assert Sizing.shards("auto", "test", 3600, 8) == {:ok, 1}

      assert {:ok, job} =
               Jobs.enqueue(
                 %{"project" => "auto", "kind" => "test", "shards" => "auto", "target" => "1h"},
                 "ada"
               )

      refute Map.has_key?(job, "shards")
    end

    test "a suggested profile, applied with profile auto" do
      profiles = %{
        "light" => %{"memoryMB" => 1024, "labels" => ["unit"]},
        "heavy" => %{"memoryMB" => 8192, "labels" => ["mutation"]},
        "bad" => %{}
      }

      config(%{"execution" => %{"enabled" => true, "profiles" => profiles}})
      for _ <- 1..2, do: history!("prof", "mutation", 1000, 2000)
      assert Sizing.profile("prof", "mutation", profiles) == {"heavy", ["mutation"]}
      assert Sizing.profile("prof", "mutation", %{"tiny" => %{"memoryMB" => 64}}) == nil
      assert Sizing.profile("none", "mutation", profiles) == nil
      assert Sizing.profile("prof", "mutation", nil) == nil

      assert {:ok, %{"suggestedProfile" => "heavy", "labels" => []}} =
               Jobs.enqueue(%{"project" => "prof", "kind" => "mutation"}, "ada")

      assert {:ok, %{"labels" => ["mutation"]}} =
               Jobs.enqueue(%{"project" => "prof", "kind" => "mutation", "profile" => "auto"}, "ada")

      assert {:error, _} =
               Jobs.enqueue(%{"project" => "prof", "kind" => "mutation", "profile" => "big"}, "ada")
    end
  end

  describe "preemption" do
    test "queued again without spending an attempt, up to execution.maxPreemptions" do
      config(%{"execution" => %{"enabled" => true, "maxPreemptions" => 1}})
      {:ok, %{"id" => id}} = Jobs.enqueue(%{"project" => "spot", "kind" => "mutation"}, "ada")
      {:ok, %{"attempts" => 1}} = Jobs.lease("a1", [])

      log =
        capture_log(fn ->
          assert {:ok, %{"status" => "queued", "preemptions" => 1}} =
                   Jobs.finish(id, "a1", %{"preempted" => true})
        end)

      assert log =~ "preempted"
      assert %{"attempts" => 0, "status" => "queued"} = Jobs.get(id)
      refute Map.has_key?(Jobs.get(id), "agent")
      {:ok, %{"attempts" => 1}} = Jobs.lease("a2", [])

      capture_log(fn ->
        assert {:ok, %{"status" => "failed", "error" => "preempted 2 times"}} =
                 Jobs.finish(id, "a2", %{"preempted" => true})
      end)
    end
  end
end
