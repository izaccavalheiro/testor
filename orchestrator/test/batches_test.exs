defmodule Testor.BatchesTest do
  @moduledoc """
  Sharding and impact analysis (docs/sharding.md, docs/impact.md): plans, batches of shard
  jobs merged into one signed run, the merge itself, and tests ranked for a change.
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn
  import ExUnit.CaptureLog
  import Testor.Test.Helpers
  alias Testor.{Batches, Config, Files, Impact, Jobs, Reports, Shards, Snapshots, Store}
  alias Testor.Auth.{Guard, Password}
  alias Testor.Reports.Merge
  alias Testor.Web.Router

  @opts Router.init([])
  @password "correct horse battery"

  setup do
    Guard.reset()
    Jobs.reset()
    for dir <- ["cas", "snapshots"], do: File.rm_rf!(Path.join(Config.data_dir(), dir))

    File.write!(
      Path.join(Config.data_dir(), "config.json"),
      JSON.encode!(%{"execution" => %{"enabled" => true}})
    )

    hash = Password.hash(@password, 1000)

    Application.put_env(:testor, :auth, %{
      "users" => %{
        "ada" => %{"password" => hash, "role" => "admin"},
        "val" => %{"password" => hash, "role" => "viewer"}
      }
    })

    on_exit(fn ->
      File.rm(Path.join(Config.data_dir(), "config.json"))
      Application.delete_env(:testor, :auth)
      Jobs.reset()
    end)
  end

  defp sha(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)

  defp snapshot!(project, paths, branch \\ "main") do
    entries =
      for path <- paths do
        tmp = Path.join(System.tmp_dir!(), "b-#{System.unique_integer([:positive])}")
        File.write!(tmp, path)
        :ok = Snapshots.put_blob(sha(path), tmp)
        File.rm(tmp)
        %{"path" => path, "sha256" => sha(path), "size" => byte_size(path)}
      end

    {:ok, %{"id" => id}} = Snapshots.offer(project, %{"files" => entries, "branch" => branch})
    id
  end

  # A finished run with spec rows (and maybe more), as the store keeps it.
  defp run!(attrs, specs \\ []) do
    id = record(Map.merge(%{"status" => "running"}, attrs))
    if specs != [], do: Files.write_json(Reports.specs_file(id), %{"specs" => specs})
    on_exit(fn -> Store.delete(id) end)
    id
  end

  defp as(conn, user),
    do: put_req_header(conn, "authorization", "Basic " <> Base.encode64("#{user}:#{@password}"))

  describe "plans" do
    test "LPT: the heaviest first, onto the lightest shard; balanced and deterministic" do
      assert Shards.plan([{"a", 5}, {"b", 4}, {"c", 3}, {"d", 3}, {"e", 1}], 2) == [
               ["a", "d"],
               ["b", "c", "e"]
             ]

      assert Shards.plan([], 3) == [[], [], []]

      for seed <- 1..20 do
        :rand.seed(:exsss, {seed, seed, seed})
        weights = for i <- 1..40, do: {"f#{i}", :rand.uniform(1000)}
        n = rem(seed, 7) + 2
        bins = Shards.plan(weights, n)
        assert bins == Shards.plan(Enum.reverse(weights), n)
        w = Map.new(weights)
        loads = Enum.map(bins, fn files -> files |> Enum.map(&w[&1]) |> Enum.sum() end)
        total = weights |> Enum.map(&elem(&1, 1)) |> Enum.sum()
        # LPT's bound: no shard over the mean by more than the heaviest file.
        assert Enum.max(loads) <= total / n + Enum.max(Map.values(w))
        assert bins |> List.flatten() |> Enum.sort() == weights |> Enum.map(&elem(&1, 0)) |> Enum.sort()
      end
    end

    test "weights: test files by their p75 time, unknown ones by the median; files to mutate by their mutants" do
      manifest = %{
        "files" => [
          %{"path" => "a.test.ts"},
          %{"path" => "b.test.ts"},
          %{"path" => "c.test.ts"},
          %{"path" => "src/x.ts"}
        ]
      }

      assert Enum.sort(Shards.weighted("weights", "test", manifest)) == [
               {"a.test.ts", 1},
               {"b.test.ts", 1},
               {"c.test.ts", 1}
             ]

      for d <- [100, 200, 300] do
        id =
          run!(%{"project" => "weights", "kind" => "test"}, [
            %{"file" => "a.test.ts", "status" => "passed", "durationMs" => d},
            %{"file" => "b.test.ts", "status" => "passed", "durationMs" => 10 * d}
          ])

        finish(id)
      end

      assert Enum.sort(Shards.weighted("weights", "test", manifest)) == [
               {"a.test.ts", 300},
               {"b.test.ts", 3000},
               {"c.test.ts", 3000}
             ]

      m = run!(%{"project" => "weights", "kind" => "mutation"})

      Files.write_json(Reports.detail_file(m), %{
        "files" => [%{"file" => "src/x.ts", "killed" => 7, "survived" => 2}, %{"file" => "src/y.ts"}]
      })

      finish(m, "passed", %{"mutation" => %{"score" => 77.0}})
      assert Enum.sort(Shards.weighted("weights", "mutation", manifest)) == [{"src/x.ts", 9}, {"src/y.ts", 1}]
      File.rm(Reports.detail_file(m))
      assert Shards.weighted("weights", "mutation", manifest) == []

      assert Shards.test_file?("tests/test_x.py") and Shards.test_file?("pkg/x_test.go") and
               not Shards.test_file?("src/x.ts")
    end
  end

  describe "the merge" do
    test "specs, mutation, coverage and time across shards" do
      a =
        run!(%{"project" => "m", "startedAt" => "2026-01-01T00:00:00Z"}, [
          %{"file" => "a.test.ts", "status" => "passed", "tests" => 1}
        ])

      b =
        run!(%{"project" => "m", "startedAt" => "2026-01-01T00:00:01Z"}, [
          %{"file" => "b.test.ts", "status" => "failed", "tests" => 2}
        ])

      Files.write_json(Reports.detail_file(a), %{
        "files" => [%{"file" => "src/a.ts", "killed" => 3}],
        "survivors" => []
      })

      Files.write_json(Reports.detail_file(b), %{
        "files" => [%{"file" => "src/a.ts", "survived" => 1}],
        "survivors" => [%{"file" => "src/a.ts"}]
      })

      Files.write_json(Reports.coverage_file(a), %{
        "files" => [%{"file" => "src/a.ts", "lines" => 50.0}, %{"file" => "src/b.ts", "lines" => 10.0}]
      })

      Files.write_json(Reports.coverage_file(b), %{
        "files" => [%{"file" => "src/a.ts", "lines" => 80.0, "branches" => 40.0}]
      })

      runs = [
        Map.merge(Store.get(a), %{
          "durationMs" => 1000,
          "endedAt" => "2026-01-01T00:00:02Z",
          "mutation" => %{"counts" => %{"killed" => 3}}
        }),
        Map.merge(Store.get(b), %{
          "durationMs" => 2000,
          "endedAt" => "2026-01-01T00:00:05Z",
          "mutation" => %{"counts" => %{"survived" => 1}}
        }),
        %{"id" => "nothing", "startedAt" => nil}
      ]

      merged = Merge.merge(runs)
      assert merged["summary"] == %{"specs" => 2, "passed" => 1, "failed" => 1, "skipped" => 0, "tests" => 3}
      assert merged["durationMs"] == 5000
      assert merged["cpuMs"] == 3000

      assert %{"score" => 75.0, "overlaps" => ["src/a.ts"], "total" => 4, "source" => "shards"} =
               merged["mutation"]

      assert %{"survivorsKept" => 1} = merged["mutationDetail"]

      assert %{"lines" => 45.0, "branches" => 40.0, "functions" => nil, "approximate" => true} =
               merged["coverage"]

      assert %{"score" => nil, "coveredScore" => nil} =
               Merge.merge([%{"id" => "nothing", "mutation" => %{}}])["mutation"]

      assert Merge.merge([%{"id" => "nothing"}]) |> Map.take(["mutation", "coverage", "durationMs"]) == %{
               "mutation" => nil,
               "coverage" => nil,
               "durationMs" => nil
             }

      for id <- [a, b], file <- [Reports.detail_file(id), Reports.coverage_file(id)], do: File.rm(file)
    end
  end

  describe "batches" do
    test "shards lease at once, run their plan's files, and merge into one signed run" do
      for d <- [100, 400] do
        id =
          run!(%{"project" => "shop", "kind" => "test"}, [
            %{"file" => "a.test.ts", "status" => "passed", "durationMs" => d},
            %{"file" => "b.test.ts", "status" => "passed", "durationMs" => d}
          ])

        finish(id)
      end

      snap = snapshot!("shop", ["a.test.ts", "b.test.ts", "c.test.ts", "src/x.ts"])

      assert {:ok,
              %{
                "batch" => true,
                "status" => "running",
                "children" => [s1, s2],
                "plan" => [_, _],
                "shardJobs" => [_, _]
              } = parent} =
               Jobs.enqueue(
                 %{"project" => "shop", "kind" => "test", "snapshot" => snap, "shards" => 2},
                 "ada"
               )

      assert {:ok, %{"id" => ^s1, "shard" => %{"index" => 1, "total" => 2}, "select" => %{"files" => f1}}} =
               Jobs.lease("a1", [])

      assert {:ok, %{"id" => ^s2, "workspace" => "shard-2", "select" => %{"files" => f2}}} =
               Jobs.lease("a2", [])

      assert Enum.sort(f1 ++ f2) == ["a.test.ts", "b.test.ts", "c.test.ts"]
      assert Jobs.lease("a3", []) == :none

      r1 =
        run!(%{"project" => "shop", "job" => s1, "shard" => %{"index" => 1, "total" => 2}}, [
          %{
            "file" => hd(f1),
            "status" => "passed",
            "tests" => 1,
            "cases" => [%{"name" => "ok", "status" => "passed"}]
          }
        ])

      r2 =
        run!(%{"project" => "shop", "job" => s2, "shard" => %{"index" => 2, "total" => 2}}, [
          %{"file" => hd(f2), "status" => "passed", "tests" => 1}
        ])

      Files.write_json(Reports.coverage_file(r1), %{"files" => [%{"file" => "src/x.ts", "lines" => 90.0}]})
      on_exit(fn -> File.rm(Reports.coverage_file(r1)) end)
      finish(r1)
      finish(r2)
      {:ok, _} = Jobs.finish(s1, "a1", %{"exitCode" => 0})
      assert Batches.settle(parent["id"]) == :pending
      {:ok, _} = Jobs.finish(s2, "a2", %{"exitCode" => 0})

      %{"runId" => merged} =
        wait_until(fn ->
          match?(%{"status" => "passed"}, Jobs.get(parent["id"])) && Jobs.get(parent["id"])
        end)

      on_exit(fn -> Store.delete(merged) end)
      assert %{"shardJobs" => [%{"status" => "passed"}, %{"status" => "passed"}]} = Jobs.get(parent["id"])

      run =
        wait_until(fn -> match?(%{"summary" => %{"specs" => 2}}, Store.get(merged)) && Store.get(merged) end)

      assert %{
               "status" => "passed",
               "job" => job,
               "batch" => %{"shards" => [%{"run" => ^r1}, %{"run" => ^r2}]},
               "specsFrom" => "reports"
             } = run

      assert job == parent["id"]
      assert wait_until(fn -> File.exists?(Path.join(Config.attestations_dir(), merged <> ".dsse.json")) end)
      # Settled once.
      assert Batches.settle(parent["id"]) == :pending
    end

    test "a shard that fails fails the batch; cancelling the parent cancels the shards" do
      {:ok, %{"id" => p, "children" => [s1, s2]}} =
        Jobs.enqueue(%{"project" => "red", "kind" => "test", "shards" => 2}, "ada")

      {:ok, _} = Jobs.lease("a1", [])
      r1 = run!(%{"project" => "red", "job" => s1, "shard" => %{"index" => 1, "total" => 2}})
      finish(r1, "failed")
      {:ok, _} = Jobs.finish(s1, "a1", %{"exitCode" => 1})
      capture_log(fn -> {:ok, _} = Jobs.cancel(p) end)
      assert %{"status" => "cancelled"} = Jobs.get(s2)

      %{"runId" => merged} =
        wait_until(fn -> match?(%{"status" => "cancelled"}, Jobs.get(p)) && Jobs.get(p) end)

      on_exit(fn -> Store.delete(merged) end)

      assert %{"batch" => %{"shards" => [%{"status" => "failed"}, %{"status" => "cancelled"}]}} =
               wait_until(fn -> Store.get(merged) end)

      {:ok, %{"id" => p2, "children" => [t1, _t2]}} =
        Jobs.enqueue(%{"project" => "lost", "kind" => "test", "shards" => 2}, "ada")

      for _ <- 1..2, do: {:ok, _} = Jobs.lease("a1", [])
      # Its run never ends (its agent went): the batch does not wait for it for ever.
      Application.put_env(:testor, :batch_wait_tries, 2)
      on_exit(fn -> Application.delete_env(:testor, :batch_wait_tries) end)
      stuck = run!(%{"project" => "lost", "job" => t1})
      {:ok, _} = Jobs.finish(t1, "a1", %{"exitCode" => 0})

      File.write!(
        Path.join(Config.data_dir(), "config.json"),
        JSON.encode!(%{"execution" => %{"enabled" => true, "maxAttempts" => 1}})
      )

      capture_log(fn -> Jobs.sweep_now(System.os_time(:second) + 3600) end)

      %{"runId" => lost} =
        wait_until(fn -> match?(%{"status" => "failed"}, Jobs.get(p2)) && Jobs.get(p2) end, 45_000)

      on_exit(fn -> Store.delete(lost) end)

      assert %{"batch" => %{"shards" => [%{"status" => "passed"} = first, %{"status" => "expired"}]}} =
               wait_until(fn -> Store.get(lost) end)

      refute Map.has_key?(first, "run")
      finish(stuck)
    end

    test "what a batch may ask for" do
      for {params, text} <- [
            {%{"shards" => 1}, "2 to 64"},
            {%{"shards" => 65}, "2 to 64"},
            {%{"shards" => 2, "select" => %{"files" => ["a"]}}, "a batch takes no select"},
            {%{"order" => "random"}, "order"},
            {%{"impact" => %{"first" => 0}}, "impact is"}
          ] do
        assert {:error, message} =
                 Jobs.enqueue(Map.merge(%{"project" => "p", "kind" => "test"}, params), "ada")

        assert message =~ text
      end
    end
  end

  describe "impact" do
    test "co-failure, coverage, naming, recency; then the rest, shortest first" do
      old =
        run!(%{"project" => "imp", "changedFiles" => ["src/cart.ts"]}, [
          %{"file" => "tests/cart.flow.test.ts", "status" => "failed", "durationMs" => 50},
          %{"file" => "tests/slow.test.ts", "status" => "passed", "durationMs" => 9000}
        ])

      finish(old, "failed", %{"startedAt" => "2026-01-01T00:00:00Z"})

      newer =
        run!(%{"project" => "imp", "changedFiles" => ["src/cart.ts"]}, [
          %{"file" => "tests/cart.flow.test.ts", "status" => "failed", "durationMs" => 50},
          %{"file" => "tests/fast.test.ts", "status" => "passed", "durationMs" => 5}
        ])

      finish(newer, "failed")
      Files.write_json(Reports.tests_file(newer), %{"src/cart.ts" => ["tests/covers.test.ts"]})
      on_exit(fn -> File.rm(Reports.tests_file(newer)) end)

      ranked = Impact.rank("imp", ["src/cart.ts", "tests/new.test.ts", "src/price.ts"], 10)
      files = Enum.map(ranked, & &1["file"])
      # The changed spec first, then what failed with the change before.
      assert Enum.take(files, 2) == ["tests/new.test.ts", "tests/cart.flow.test.ts"]
      assert %{"reasons" => reasons} = Enum.at(ranked, 1)
      assert "co-failed with src/cart.ts" in reasons and "failed recently" in reasons
      assert "tests/new.test.ts" in files and "tests/covers.test.ts" in files
      assert Enum.take(files, -2) == ["tests/fast.test.ts", "tests/slow.test.ts"]
      # Spec rows kept in the record, and a run whose start cannot be read (half weight).
      synthetic = [
        %{
          "id" => "synthetic",
          "status" => "failed",
          "changedFiles" => ["a.ts"],
          "specs" => [%{"file" => "a.flow.test.ts", "status" => "failed"}]
        }
      ]

      assert [%{"file" => "a.flow.test.ts", "score" => 2.5}] = Impact.rank("x", ["a.ts"], 10, synthetic)
      assert Impact.named?("tests/cart.test.ts", "src/cart.ts") and Impact.named?("test_cart.py", "cart.py")
      refute Impact.named?("src/cart.ts", "src/cart.ts")

      assert %{"runs" => 2, "apfd" => apfd, "medianRank" => 1} = Impact.replay("imp")
      assert apfd > 0.5
      assert %{"runs" => 0, "apfd" => nil} = Impact.replay("nobody")
      assert {:error, _} = Impact.changed(["../x"])
      assert {:error, _} = Impact.changed("x")

      body = JSON.encode!(%{"changed" => ["src/cart.ts"], "limit" => 2})

      conn =
        conn(:post, "/api/v1/projects/imp/impact", body)
        |> put_req_header("content-type", "application/json")
        |> as("val")
        |> Router.call(@opts)

      assert %{"data" => [%{"file" => "tests/cart.flow.test.ts"}, _]} = JSON.decode!(conn.resp_body)

      bad =
        conn(:post, "/api/v1/projects/imp/impact", JSON.encode!(%{"changed" => ["/etc"]}))
        |> put_req_header("content-type", "application/json")
        |> as("val")
        |> Router.call(@opts)

      assert bad.status == 400

      nojson =
        conn(:post, "/api/v1/projects/imp/impact", "{x")
        |> put_req_header("content-type", "application/json")
        |> as("val")
        |> Router.call(@opts)

      assert nojson.status == 400

      principal = %{sub: "val", scopes: ["read"], via: :basic}

      assert {:ok, %{"structuredContent" => %{"specs" => [%{"file" => "tests/cart.flow.test.ts"} | _]}}} =
               Testor.MCP.Tools.call(
                 "get_impacted_tests",
                 %{"project" => "imp", "changed" => ["src/cart.ts"]},
                 principal,
                 ""
               )

      assert {:ok, %{"isError" => true}} =
               Testor.MCP.Tools.call("get_impacted_tests", %{"changed" => []}, principal, "")

      other = %{sub: "val", scopes: ["read"], via: :basic, projects: ["elsewhere"]}

      assert {:ok, %{"structuredContent" => %{"specs" => []}}} =
               Testor.MCP.Tools.call(
                 "get_impacted_tests",
                 %{"project" => "imp", "changed" => ["src/cart.ts"]},
                 other,
                 ""
               )
    end

    test "jobs ordered by impact, and their changed files" do
      snapshot!("ord", ["tests/a.test.ts", "src/a.ts"])
      snap = snapshot!("ord", ["tests/a.test.ts", "src/a.ts", "src/b.ts"])

      assert {:ok, %{"changedFiles" => ["src/b.ts"], "impact" => %{"first" => 5}} = job} =
               Jobs.enqueue(
                 %{
                   "project" => "ord",
                   "kind" => "test",
                   "snapshot" => snap,
                   "order" => "impact",
                   "impact" => %{"first" => 5}
                 },
                 "ada"
               )

      refute Map.has_key?(job, "testOrder")

      r =
        run!(%{"project" => "ord"}, [%{"file" => "tests/b.test.ts", "status" => "passed", "durationMs" => 3}])

      finish(r)

      assert {:ok, %{"testOrder" => ["tests/b.test.ts"]}} =
               Jobs.enqueue(
                 %{"project" => "ord", "kind" => "t2", "snapshot" => snap, "order" => "impact"},
                 "ada"
               )
    end
  end
end
