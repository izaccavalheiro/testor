defmodule Testor.FlakyTest do
  @moduledoc "Flaky specs: passed and failed on the same clean commit, across runs of a task."
  use ExUnit.Case, async: false
  import Testor.Test.Helpers
  alias Testor.{Config, Files, Query, Store}

  # Finished records as the store keeps them (with summary and specs), so they are not finalized again.
  defp run(kind, source, specs) do
    id = run_id()

    Files.write_json(Config.run_file(id), %{
      "id" => id,
      "project" => "flaky-app",
      "kind" => kind,
      "status" => if(Enum.any?(specs, &(elem(&1, 1) == "failed")), do: "failed", else: "passed"),
      "startedAt" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "summary" => %{},
      "source" => source,
      "specs" => for({file, status} <- specs, do: %{"file" => file, "status" => status})
    })

    wait_until(fn -> Store.get(id) end)
    on_exit(fn -> Store.delete(id) end)
    # Ids are made per second: two runs in one second must still differ.
    Process.sleep(5)
    id
  end

  @clean_a %{"commit" => "aaaa", "branch" => "main", "dirty" => false}
  @clean_b %{"commit" => "bbbb", "branch" => "main", "dirty" => false}
  @dirty_a %{"commit" => "aaaa", "branch" => "main", "dirty" => true}

  test "a spec that passed and failed on one clean commit is flaky; others are not" do
    run("test", @clean_a, [{"a.test.ts", "passed"}, {"b.test.ts", "passed"}, {"c.test.ts", "skipped"}])

    failed =
      run("test", @clean_a, [{"a.test.ts", "failed"}, {"b.test.ts", "passed"}, {"c.test.ts", "skipped"}])

    # b failed on another commit only: a real failure, fixed or not, but not flaky.
    run("test", @clean_b, [{"b.test.ts", "failed"}])
    # A failure with local changes, or without a recorded commit, is no evidence.
    run("test", @dirty_a, [{"b.test.ts", "failed"}])
    run("test", nil, [{"b.test.ts", "failed"}])
    run("e2e", @clean_a, [{"login.spec.ts", "failed"}])
    run("e2e", @clean_a, [{"login.spec.ts", "passed"}])
    run("e2e", @clean_a, [{"login.spec.ts", "failed"}])

    assert [
             %{
               "file" => "login.spec.ts",
               "kind" => "e2e",
               "failed" => 2,
               "passed" => 1,
               "commits" => ["aaaa"]
             },
             %{
               "file" => "a.test.ts",
               "kind" => "test",
               "failed" => 1,
               "passed" => 1,
               "lastFailedRun" => ^failed
             }
           ] = Query.flaky("flaky-app")

    assert [%{"file" => "a.test.ts"}] = Query.flaky("flaky-app", "test")
    assert Query.flaky("no-such-project") == []
  end

  test "through the API and MCP" do
    run("test", @clean_a, [{"x.test.ts", "passed"}])
    run("test", @clean_a, [{"x.test.ts", "failed"}])

    assert %{"data" => [%{"file" => "x.test.ts"}]} =
             http(:get, "/api/v1/projects/flaky-app/flaky?kind=test") |> json()

    principal = Testor.Auth.anonymous()
    assert {:ok, %{"flaky" => [%{"file" => "x.test.ts"}]}} = mcp(%{"project" => "flaky-app"}, principal)
    assert {:error, "project is required"} = mcp(%{}, principal)
    assert {:error, "invalid kind"} = mcp(%{"project" => "flaky-app", "kind" => 5}, principal)
  end

  defp mcp(args, principal) do
    case Testor.MCP.Tools.call("find_flaky_specs", args, principal, "http://x") do
      {:ok, %{"structuredContent" => data, "isError" => false}} -> {:ok, data}
      {:ok, %{"isError" => true, "content" => [%{"text" => text}]}} -> {:error, text}
    end
  end
end
