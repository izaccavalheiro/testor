defmodule Testor.ReportsTest do
  @moduledoc "Report files: mutation reports read, summarized, signed, gated, shown, and the log's fallback."
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  import Testor.Test.Helpers
  alias Testor.{Attestation, Badge, Config, Gates, Jobs, Reports, Store}
  alias Testor.Reports.Mutation

  @commit "4a5b6c7d8e9f00112233445566778899aabbccdd"

  # A StrykerJS-like report, schema 2: two files, tests that cover them.
  defp report(extra \\ %{}) do
    Map.merge(
      %{
        "schemaVersion" => "2",
        "thresholds" => %{"high" => 80, "low" => 60},
        "files" => %{
          "src/add.ts" => %{
            "language" => "typescript",
            "source" => "export const add = (a, b) => a + b;\nexport const one = 1;\n",
            "mutants" => [
              mutant("1", "Killed", "ArithmeticOperator", "a - b", {1, 30}, {1, 35}, ["t1"]),
              mutant("2", "Survived", "ArrowFunction", "() => undefined", {1, 20}, {2, 5}, ["t1"]),
              mutant("3", "Timeout", "BlockStatement", "{}", {1, 1}, {1, 2}, []),
              mutant("4", "Ignored", "StringLiteral", "\"\"", {2, 1}, {2, 2}, [])
            ]
          },
          "src/sub.ts" => %{
            "language" => "typescript",
            "mutants" => [
              mutant("5", "NoCoverage", "ArithmeticOperator", "a + b", {1, 1}, {1, 2}, []),
              mutant("6", "CompileError", "X", "y", {1, 1}, {1, 1}, []),
              mutant("7", "Weird", "X", "y", nil, nil, [])
            ]
          }
        },
        "testFiles" => %{"test/add.spec.ts" => %{"tests" => [%{"id" => "t1", "name" => "adds"}]}}
      },
      extra
    )
  end

  defp mutant(id, status, mutator, replacement, from, to, covered) do
    location =
      if from do
        {l1, c1} = from
        {l2, c2} = to
        %{"start" => %{"line" => l1, "column" => c1}, "end" => %{"line" => l2, "column" => c2}}
      end

    %{
      "id" => id,
      "status" => status,
      "mutatorName" => mutator,
      "replacement" => replacement,
      "location" => location,
      "coveredBy" => covered
    }
  end

  describe "Mutation.parse/1" do
    test "counts each status, scores, keeps survivors with their text, and maps tests to sources" do
      assert {:ok, summary, detail, tests} = Mutation.parse(JSON.encode!(report()))

      assert %{
               "score" => 50.0,
               "coveredScore" => 66.67,
               "total" => 6,
               "files" => 2,
               "source" => "report",
               "counts" => %{
                 "killed" => 1,
                 "survived" => 1,
                 "timeout" => 1,
                 "noCoverage" => 1,
                 "ignored" => 1,
                 "compileError" => 1
               }
             } = summary

      assert [
               %{"file" => "src/add.ts", "survived" => 1},
               %{"file" => "src/sub.ts", "noCoverage" => 1, "score" => +0.0, "coveredScore" => nil}
             ] =
               detail["files"]

      assert [
               %{
                 "file" => "src/add.ts",
                 "line" => 1,
                 "endLine" => 2,
                 "status" => "survived",
                 "original" => "(a, b) => a + b; …",
                 "replacement" => "() => undefined",
                 "mutator" => "ArrowFunction"
               },
               %{"file" => "src/sub.ts", "status" => "noCoverage", "original" => nil}
             ] = detail["survivors"]

      assert tests == %{"src/add.ts" => ["test/add.spec.ts"]}
    end

    test "schema 1, hostile and empty reports" do
      v1 = %{
        "schemaVersion" => "1",
        "files" => %{"a.js" => %{"mutants" => [%{"status" => "Survived", "mutatorName" => 5}]}}
      }

      assert {:ok, %{"score" => +0.0, "coveredScore" => +0.0}, %{"survivors" => [s]}, %{}} =
               Mutation.parse(JSON.encode!(v1))

      assert s["mutator"] == nil and s["line"] == nil

      long = String.duplicate("<script>", 100)

      hostile = %{
        "schemaVersion" => "2",
        "files" => %{long => %{"mutants" => ["x", %{"status" => "Killed"}]}, "b" => 1},
        "testFiles" => 7
      }

      assert {:ok, %{"score" => 100.0}, %{"files" => [%{"file" => f}]}, %{}} =
               Mutation.parse(JSON.encode!(hostile))

      assert String.length(f) == 200

      assert {:ok, %{"score" => nil, "coveredScore" => nil, "total" => 0}, _, _} =
               Mutation.parse(~s({"schemaVersion": "2", "files": {}}))

      assert Mutation.parse(~s({"schemaVersion": "2", "files": {"a": )) == {:error, "not JSON"}
      assert Mutation.parse(~s({"files": {}})) == {:error, "no schemaVersion and files"}
      assert Mutation.parse(~s([1])) == {:error, "no schemaVersion and files"}
    end
  end

  describe "Mutation.from_log/1 and progress/1" do
    test "StrykerJS's table and final score, Stryker.NET's score" do
      js = """
      ----------|---------|----------|-----------|------------|----------|----------|
      File      | % score | % covered | # killed | # timeout | # survived | # no cov | # errors |
      All files |   87.50 |    90.00 |        70 |          0 |         10 |        2 |        0 |
       add.ts   |   87.50 |    90.00 |        70 |          0 |         10 |        2 |        0 |
      Final mutation score of 87.5 is greater than or equal to break threshold 60
      """

      assert %{
               "score" => 87.5,
               "coveredScore" => 90.0,
               "counts" => %{
                 "killed" => 70,
                 "survived" => 10,
                 "noCoverage" => 2,
                 "timeout" => 0,
                 "errors" => 0
               },
               "source" => "log"
             } = Mutation.from_log(js)

      six = "All files |  50.00 | 5 | 0 | 5 | 0 | 0 |\n"
      assert %{"score" => 50.0, "coveredScore" => nil, "counts" => %{"killed" => 5}} = Mutation.from_log(six)

      assert %{"score" => 61.25, "source" => "log"} =
               Mutation.from_log("[INF] The final mutation score is 61.25 %\n")

      assert %{"score" => 61.0} = Mutation.from_log("Final mutation score of 61 is lower")
      assert Mutation.from_log("All files | n/a | x |\n") == nil
      assert Mutation.from_log("nothing to see") == nil
    end

    test "progress lines" do
      js =
        "Mutation testing  [=====     ] 42% (elapsed: <1m, remaining: ~1m) 12/30 tested (3 survived, 1 timed out)"

      assert Mutation.progress(js) == %{
               "percent" => 42,
               "tested" => 12,
               "total" => 30,
               "survived" => 3,
               "timedOut" => 1
             }

      net = "│ Testing mutant 12 / 30 │ K 8 │ S 3 │ T 1 │ 40% │ ~1m 00s │"

      assert Mutation.progress(net) == %{
               "percent" => 40,
               "tested" => 12,
               "total" => 30,
               "survived" => 3,
               "timedOut" => 1
             }

      assert %{"percent" => 0} = Mutation.progress("Testing mutant 0 / 0 | K 0 | S 0 | T 0")
      assert Mutation.progress("hello") == nil
    end
  end

  describe "a run's reports" do
    setup do
      on_exit(fn ->
        Application.delete_env(:testor, :report_max_bytes)
        Application.delete_env(:testor, :report_parse_ms)
      end)
    end

    defp with_reports(files) do
      id = run_id()
      File.mkdir_p!(Reports.dir(id))
      for {name, data} <- files, do: File.write!(Path.join(Reports.dir(id), name), data)
      on_exit(fn -> Reports.delete(id) end)
      id
    end

    test "kinds, the summary and the details kept beside them" do
      id = with_reports([{"mutation.json", JSON.encode!(report())}, {"notes.txt", "hello"}, {"empty", ""}])

      assert [
               %{"file" => "empty", "kind" => "file", "bytes" => 0},
               %{"file" => "mutation.json", "kind" => "mutation"},
               %{"file" => "notes.txt"}
             ] =
               Reports.list(id)

      assert Reports.kind(Path.join(Reports.dir(id), "gone.json")) == "file"
      assert %{"reports" => [_, _, _], "mutation" => %{"score" => 50.0}} = Reports.summarize(id, "")
      assert %{"survivors" => [_, _]} = Reports.mutation_detail(id)
      assert {:ok, %{"src/add.ts" => _}} = Testor.Files.read_json(Reports.tests_file(id))

      Reports.delete(id)
      assert Reports.mutation_detail(id) == nil and Reports.list(id) == []
    end

    test "a report that is not one, over the cap or too slow: the log's summary stands in" do
      bad = with_reports([{"m.json", ~s({"schemaVersion": "2", "files": {"a": [}})}])

      assert capture_log(fn ->
               assert %{"mutation" => %{"score" => 40.0, "source" => "log"}} =
                        Reports.summarize(bad, "Final mutation score of 40.00")
             end) =~ "is not a mutation report"

      Application.put_env(:testor, :report_max_bytes, 10)
      big = with_reports([{"m.json", JSON.encode!(report())}])

      assert Reports.summarize(big, "") == %{
               "reports" => [
                 %{
                   "file" => "m.json",
                   "kind" => "mutation",
                   "bytes" => File.stat!(Path.join(Reports.dir(big), "m.json")).size
                 }
               ]
             }

      Application.delete_env(:testor, :report_max_bytes)

      Application.put_env(:testor, :report_parse_ms, 0)
      many = for n <- 1..60_000, into: %{}, do: {"f#{n}.ts", %{"mutants" => [%{"status" => "Killed"}]}}
      slow = with_reports([{"m.json", JSON.encode!(%{"schemaVersion" => "2", "files" => many})}])
      assert capture_log(fn -> Reports.summarize(slow, "") end) =~ "could not be read in time"

      # No reports, no log.
      assert Reports.summarize(run_id()) == %{}
    end

    test "a finished run: the summary in its signed record, the details with its snapshot, gates and badges" do
      config = Path.join(Config.data_dir(), "config.json")
      on_exit(fn -> File.rm(config) end)

      id = run_id()
      File.mkdir_p!(Reports.dir(id))
      File.write!(Path.join(Reports.dir(id), "mutation.json"), JSON.encode!(report()))

      record(%{
        "id" => id,
        "project" => "mut",
        "kind" => "mutation",
        "source" => %{"commit" => @commit, "dirty" => false}
      })

      on_exit(fn -> Store.delete(id) end)
      capture_log(fn -> finish(id, "passed") end)
      wait_until(fn -> Attestation.exists?(id) end)

      assert %{"mutation" => %{"score" => 50.0}, "reports" => [%{"kind" => "mutation"}]} = Store.get(id)
      assert %{"mutation" => %{"survivors" => [_, _]}} = Testor.Views.run_snapshot(id)

      {:ok, envelope} = id |> Attestation.file() |> File.read!() |> JSON.decode()
      {:ok, statement} = Attestation.verify(envelope, elem(Attestation.keypair(), 0))
      assert statement["predicate"]["run"]["mutation"]["score"] == 50.0
      assert Enum.any?(statement["subject"], &(&1["name"] == "reports/mutation.json"))

      gate = %{"name" => "m", "project" => "mut", "kinds" => ["mutation"]}
      assert %{"pass" => true} = Gates.evaluate(gate, @commit) |> elem(1)

      assert %{"pass" => false, "checks" => [%{"reason" => "its mutation score 50.0 is below 80"}]} =
               Gates.evaluate(Map.put(gate, "minMutationScore", 80), @commit) |> elem(1)

      assert %{"pass" => false, "checks" => [%{"reason" => "it left 1 mutants alive (at most 0)"}]} =
               Gates.evaluate(Map.put(gate, "maxSurvivors", 0), @commit) |> elem(1)

      assert %{"pass" => true} =
               Gates.evaluate(Map.merge(gate, %{"minMutationScore" => 50, "maxSurvivors" => 1}), @commit)
               |> elem(1)

      File.write!(
        config,
        JSON.encode!(%{
          "gates" => %{
            "ok" => %{
              "project" => "mut",
              "kinds" => ["mutation"],
              "minMutationScore" => 75.5,
              "maxSurvivors" => 3
            },
            "low" => %{"project" => "mut", "kinds" => ["mutation"], "minMutationScore" => 101},
            "neg" => %{"project" => "mut", "kinds" => ["mutation"], "maxSurvivors" => -1}
          }
        })
      )

      assert {:ok, %{"minMutationScore" => 75.5, "maxSurvivors" => 3}} = Gates.get("ok")
      assert {:error, "minMutationScore" <> _} = Gates.get("low")
      assert {:error, "maxSurvivors" <> _} = Gates.get("neg")

      assert Badge.svg("mut", "mutation", "mutation") =~ ">50.0%<"
      assert Badge.svg("mut", nil, "mutation") =~ "#c62828"
      assert Badge.svg("nobody", nil, "mutation") =~ ">no score<"
    end

    test "badge colours, and a run without a summary" do
      for {score, color} <- [{85.0, "#2e7d32"}, {65.0, "#e65100"}] do
        id =
          record(%{
            "project" => "badge-#{round(score)}",
            "kind" => "mutation",
            "status" => "passed",
            "mutation" => %{"score" => score}
          })

        on_exit(fn -> Store.delete(id) end)
        wait_until(fn -> Store.get(id) end)
        assert Badge.svg("badge-#{round(score)}", nil, "mutation") =~ color
      end

      gate = %{
        "name" => "x",
        "project" => "p",
        "kinds" => ["k"],
        "minMutationScore" => 1,
        "maxSurvivors" => 1
      }

      id = record(%{"project" => "p", "kind" => "k", "source" => %{"commit" => @commit, "dirty" => false}})
      on_exit(fn -> Store.delete(id) end)
      capture_log(fn -> finish(id, "passed") end)
      wait_until(fn -> Attestation.exists?(id) end)

      assert %{"checks" => [%{"reason" => "its mutation score (none) is below 1"}]} =
               Gates.evaluate(gate, @commit) |> elem(1)

      assert %{"checks" => [%{"reason" => "it left an unknown number of mutants alive (at most 1)"}]} =
               Gates.evaluate(Map.delete(gate, "minMutationScore"), @commit) |> elem(1)
    end
  end

  test "a running Stryker run shows its progress live" do
    id = record(%{"project" => "live-mut", "kind" => "mutation"})

    on_exit(fn ->
      Store.settle(id, "cancelled")
      Store.delete(id)
    end)

    log(
      id,
      "Mutation testing  [==   ] 10% (elapsed: <1m, remaining: ~2m) 3/30 tested (1 survived, 0 timed out)\n"
    )

    assert %{"mutationProgress" => %{"tested" => 3, "total" => 30}} =
             wait_until(fn -> Store.get(id) |> Store.with_live() |> then(&(&1["mutationProgress"] && &1)) end)
  end

  test "a job may ask for a clean run, as data" do
    config = Path.join(Config.data_dir(), "config.json")
    File.write!(config, JSON.encode!(%{"execution" => %{"enabled" => true}}))
    Jobs.reset()

    on_exit(fn ->
      Jobs.reset()
      File.rm(config)
    end)

    assert {:ok, %{"clean" => true}} =
             Jobs.enqueue(%{"project" => "p", "kind" => "mutation", "clean" => true}, "ada")

    assert {:ok, job} = Jobs.enqueue(%{"project" => "p", "kind" => "mutation", "clean" => false}, "ada")
    refute Map.has_key?(job, "clean")

    assert {:error, "clean is true or false"} =
             Jobs.enqueue(%{"project" => "p", "kind" => "k", "clean" => "yes"}, "ada")
  end
end
