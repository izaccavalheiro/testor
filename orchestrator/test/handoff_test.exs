defmodule Testor.HandoffTest do
  @moduledoc """
  Handing test load off (docs/handoff.md): scoped and affected jobs, jobs per workspace, exec
  mode's signed claim, the result cache, the failure digest, a log read from an offset with its
  stream marks, and watch sessions.
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn
  import ExUnit.CaptureLog
  import Testor.Test.Helpers
  alias Testor.{Config, Digest, Gates, Jobs, ResultCache, Select, Snapshots, Store}
  alias Testor.Auth.{Guard, JobTokens, Password}
  alias Testor.Web.Router

  @opts Router.init([])
  @password "correct horse battery"

  setup_all do
    File.rm(JobTokens.file())
    capture_log(fn -> JobTokens.load!() end)
    ring = JobTokens.load!()
    File.rm(JobTokens.file())
    %{ring: ring}
  end

  setup do
    Guard.reset()
    Jobs.reset()
    for dir <- ["cas", "snapshots", "results"], do: File.rm_rf!(Path.join(Config.data_dir(), dir))
    config(%{})
    hash = Password.hash(@password, 1000)

    Application.put_env(:testor, :auth, %{
      "users" => %{
        "ada" => %{"password" => hash, "role" => "admin"},
        "own" => %{"password" => hash, "role" => "exec-admin"},
        "val" => %{"password" => hash, "role" => "viewer"},
        "lib-admin" => %{"password" => hash, "role" => "admin", "projects" => ["lib"]},
        "bot" => %{"password" => hash, "role" => "agent"}
      }
    })

    Application.put_env(:testor, :lease_poll_ms, 20)

    on_exit(fn ->
      File.rm(Path.join(Config.data_dir(), "config.json"))
      Application.delete_env(:testor, :auth)
      Application.delete_env(:testor, :auth_job_token_keys)
      Application.delete_env(:testor, :lease_poll_ms)
      :persistent_term.erase({Testor.Auth, :settings})
      Jobs.reset()
    end)
  end

  defp config(extra) do
    base = %{"execution" => %{"enabled" => true}}
    File.write!(Path.join(Config.data_dir(), "config.json"), JSON.encode!(Map.merge(base, extra)))
  end

  defp sha(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)

  defp as(conn, user),
    do: put_req_header(conn, "authorization", "Basic " <> Base.encode64("#{user}:#{@password}"))

  defp call(method, path, body, user) do
    conn(method, path, body)
    |> put_req_header("content-type", "application/json")
    |> as(user)
    |> Router.call(@opts)
  end

  defp body(conn), do: JSON.decode!(conn.resp_body)

  # A stored snapshot of `files` (path => contents) on `branch`: its id.
  defp snapshot!(project, files, branch \\ "main") do
    for {_path, data} <- files do
      tmp = Path.join(System.tmp_dir!(), "h-#{System.unique_integer([:positive])}")
      File.write!(tmp, data)
      :ok = Snapshots.put_blob(sha(data), tmp)
      File.rm(tmp)
    end

    entries =
      for {path, data} <- files, do: %{"path" => path, "sha256" => sha(data), "size" => byte_size(data)}

    {:ok, %{"id" => id, "stored" => true}} =
      Snapshots.offer(project, %{"files" => entries, "branch" => branch})

    id
  end

  describe "select" do
    test "what a selection may hold" do
      assert Select.check(nil) == {:ok, nil}

      assert {:ok, %{"files" => ["a.test.ts"], "names" => ["adds"]}} =
               Select.check(%{"files" => ["a.test.ts", "a.test.ts"], "names" => ["adds"]})

      assert {:ok, %{"affected" => "then-all"}} = Select.check(%{"affected" => "then-all"})

      for {bad, text} <- [
            {%{"other" => 1}, "has files"},
            {%{"files" => ["../x"]}, "select.files"},
            {%{"files" => List.duplicate("a", 2001)}, "select.files"},
            {%{"names" => ["a\nb"]}, "select.names"},
            {%{"names" => [String.duplicate("n", 201)]}, "select.names"},
            {%{"affected" => "yes"}, "affected"},
            {%{}, "names files"},
            {"x", "an object"}
          ] do
        assert {:error, message} = Select.check(bad)
        assert message =~ text
      end
    end

    test "jobs keep their selection and other options; one job per project and workspace" do
      assert {:ok,
              %{
                "select" => %{"files" => ["a.test.ts"]},
                "workspace" => "wt-1",
                "failFast" => true,
                "cache" => false
              }} =
               Jobs.enqueue(
                 %{
                   "project" => "app",
                   "kind" => "test",
                   "select" => %{"files" => ["a.test.ts"]},
                   "workspace" => "wt-1",
                   "failFast" => true,
                   "cache" => false
                 },
                 "ada"
               )

      {:ok, _} = Jobs.enqueue(%{"project" => "app", "kind" => "test", "workspace" => "wt-2"}, "ada")
      {:ok, _} = Jobs.enqueue(%{"project" => "app", "kind" => "test", "workspace" => "wt-2"}, "ada")
      # Two worktrees at once; the second job of wt-2 waits for the first.
      assert {:ok, %{"workspace" => "wt-1"}} = Jobs.lease("a1", [])
      assert {:ok, %{"workspace" => "wt-2"}} = Jobs.lease("a2", [])
      assert Jobs.lease("a3", []) == :none

      for {params, text} <- [
            {%{"select" => %{"files" => ["/etc/passwd"]}}, "select.files"},
            {%{"select" => %{"affected" => true}}, "needs a snapshot"},
            {%{"workspace" => "a b"}, "workspace"},
            {%{"failFast" => "yes"}, "failFast"},
            {%{"watch" => false}, "watch is true"},
            {%{"argv" => []}, "argv"},
            {%{"argv" => ["a\0b"]}, "argv"},
            {%{"watch" => true}, "a watch session runs a snapshot"}
          ] do
        assert {:error, message} =
                 Jobs.enqueue(Map.merge(%{"project" => "app", "kind" => "test"}, params), "ada")

        assert message =~ text
      end
    end
  end

  describe "affected" do
    test "the files that changed since the branch's last snapshot, else the default branch's" do
      first = snapshot!("app", %{"src/a.ts" => "a", "src/a.test.ts" => "t"})
      "sha256:" <> first_hex = first
      # No base yet.
      assert Snapshots.changed("app", first_hex, "main") == :none
      second = snapshot!("app", %{"src/a.ts" => "a2", "src/a.test.ts" => "t", "src/b.ts" => "b"})
      "sha256:" <> hex = second
      assert Snapshots.changed("app", hex, "main") == {:ok, ["src/a.ts", "src/b.ts"]}
      # Sent again: the pointer stays.
      ^second = snapshot!("app", %{"src/a.ts" => "a2", "src/a.test.ts" => "t", "src/b.ts" => "b"})
      assert Snapshots.changed("app", hex, "main") == {:ok, ["src/a.ts", "src/b.ts"]}
      # A new branch counts from main's.
      feature = snapshot!("app", %{"src/a.ts" => "a3", "src/a.test.ts" => "t", "src/b.ts" => "b"}, "feat/x")
      "sha256:" <> feature_hex = feature
      assert Snapshots.changed("app", feature_hex, "feat/x") == {:ok, ["src/a.ts"]}
      assert Snapshots.changed("app", feature_hex, nil) == {:ok, ["src/a.ts"]}

      assert {:ok,
              %{"select" => %{"affected" => "then-all", "changed" => ["src/a.ts"]}, "branch" => "feat/x"}} =
               Jobs.enqueue(
                 %{
                   "project" => "app",
                   "kind" => "test",
                   "snapshot" => feature,
                   "select" => %{"affected" => "then-all"}
                 },
                 "ada"
               )

      # Without a base: affected without changed, a full run.
      solo = snapshot!("solo", %{"a.ts" => "a"})

      assert {:ok, %{"select" => select}} =
               Jobs.enqueue(
                 %{
                   "project" => "solo",
                   "kind" => "t2",
                   "snapshot" => solo,
                   "select" => %{"affected" => true}
                 },
                 "ada"
               )

      refute Map.has_key?(select, "changed")
    end

    test "too many changes make a full run" do
      many = Map.new(1..2001, &{"f#{&1}.txt", "#{&1}"})
      snapshot!("big", %{"x" => "x"})
      "sha256:" <> hex = snapshot!("big", many)
      assert Snapshots.changed("big", hex, "main") == :none
    end
  end

  describe "exec mode" do
    test "argv needs the exec scope, and jobTokens' key to sign who asked", %{ring: ring} do
      job = %{"project" => "app", "kind" => "exec", "argv" => ["npx", "vitest", "run", "a b.test.ts"]}
      assert %{status: 403} = call(:post, "/api/v1/jobs", JSON.encode!(job), "ada")
      assert %{status: 400} = refused = call(:post, "/api/v1/jobs", JSON.encode!(job), "own")
      assert body(refused)["error"]["message"] =~ "jobTokens"

      Application.put_env(:testor, :auth_job_token_keys, ring)

      Application.put_env(
        :testor,
        :auth,
        put_in(Application.get_env(:testor, :auth), ["jobTokens"], %{
          "issuer" => "https://t.example.com",
          "audiences" => ["x"]
        })
      )

      log =
        capture_log(fn ->
          assert %{status: 201} = created = call(:post, "/api/v1/jobs", JSON.encode!(job), "own")
          send(self(), {:job, body(created)})
        end)

      assert_received {:job, %{"argv" => argv, "claim" => claim}}
      assert argv == job["argv"]
      [header, payload, signature] = String.split(claim, ".")

      %{"sub" => "user:own", "project" => "app", "argv_sha256" => hash} =
        payload |> Base.url_decode64!(padding: false) |> JSON.decode!()

      assert hash == Jobs.argv_hash(argv)
      {:RSAPrivateKey, _, n, e, _, _, _, _, _, _, _} = ring.signing.key

      assert :public_key.verify(
               header <> "." <> payload,
               :sha256,
               Base.url_decode64!(signature, padding: false),
               {:RSAPublicKey, n, e}
             )

      _ = log
    end
  end

  describe "the result cache" do
    test "a job of the same snapshot and inputs is answered from the run that passed" do
      snap = snapshot!("cached", %{"a.test.ts" => "t"})
      job = %{"project" => "cached", "kind" => "test", "snapshot" => snap, "labels" => ["linux"]}
      {:ok, first} = Jobs.enqueue(job, "ada")
      {:ok, _} = Jobs.lease("a1", ["linux"])
      run = record(%{"project" => "cached", "job" => first["id"], "status" => "passed"})
      on_exit(fn -> Store.delete(run) end)
      cache = %{"inputs" => "h1", "mode" => "passed"}
      {:ok, _} = Jobs.finish(first["id"], "a1", %{"exitCode" => 0, "cache" => cache})

      assert {:ok, %{"status" => "passed", "cached" => %{"job" => origin}, "runId" => ^run, "exitCode" => 0}} =
               Jobs.enqueue(job, "ada")

      assert origin == first["id"]
      assert Jobs.lease("a1", ["linux"]) == :none
      # Asked not to, or another selection: run again.
      assert {:ok, %{"status" => "queued"}} = Jobs.enqueue(Map.put(job, "cache", false), "ada")
      assert {:ok, %{"status" => "queued"}} = Jobs.enqueue(Map.put(job, "select", %{"names" => ["x"]}), "ada")

      # A failure is not kept unless "all".
      Jobs.reset()
      {:ok, %{"id" => second}} = Jobs.enqueue(Map.put(job, "kind", "lint"), "ada")
      {:ok, _} = Jobs.lease("a1", ["linux"])
      {:ok, _} = Jobs.finish(second, "a1", %{"exitCode" => 1, "cache" => cache})
      assert {:ok, %{"status" => "queued"}} = Jobs.enqueue(Map.put(job, "kind", "lint"), "ada")
      # The agent's inputs changed (its command entry): the old result is not used.
      assert ResultCache.record(
               %{"snapshot" => snap, "project" => "cached", "kind" => "test"},
               %{"cache" => %{"inputs" => "h2", "mode" => "passed"}},
               "passed"
             ) == :ok

      assert {:ok, %{"status" => "queued"}} = Jobs.enqueue(job, "ada")

      fail = %{"snapshot" => snap, "project" => "cached", "kind" => "e2e", "id" => "job-x"}

      assert ResultCache.record(
               fail,
               %{"cache" => %{"inputs" => "h", "mode" => "all"}, "exitCode" => 2},
               "failed"
             ) == :ok

      assert {:ok, %{"status" => "failed", "exitCode" => 2}} = ResultCache.lookup(fail)

      assert ResultCache.record(
               fail,
               %{"cache" => %{"inputs" => "h", "mode" => "all"}, "noCache" => true},
               "passed"
             ) == :skip

      assert ResultCache.record(%{"kind" => "x"}, %{}, "passed") == :skip
      assert ResultCache.lookup(fail, System.os_time(:second) + 8 * 86_400) == :miss

      # Expired entries go.
      for path <-
            Path.wildcard(
              String.replace(Path.join([Config.data_dir(), "results", "cached", "*.json"]), "\\", "/")
            ),
          do: File.touch!(path, System.os_time(:second) - 9 * 86_400)

      assert ResultCache.sweep() >= 2
    end
  end

  describe "the digest" do
    test "counts, failures with their messages, the project's frames" do
      specs = [
        %{
          "file" => "src/a.test.ts",
          "status" => "failed",
          "tests" => 2,
          "cases" => [
            %{"name" => "adds", "status" => "failed", "message" => "expected 3\nto be 4"},
            %{"name" => "ok", "status" => "passed"}
          ]
        },
        %{"file" => "src/b.test.ts", "status" => "failed", "tests" => 1},
        %{"file" => "src/c.test.ts", "status" => "passed", "tests" => 1}
      ]

      log = """
      \e[31m    at Object.<anonymous> (src/a.ts:12:3)\e[0m
          at run (node_modules/vitest/dist/x.js:1:1)
          at src/a.ts:12:3
        File "tests/test_x.py", line 7, in test_x
        File "/usr/lib/python3/site-packages/pytest.py", line 9
      pkg/x_test.go:31: wrong
         at App.Tests.Calc() in C:\\src\\Calc.cs:line 5
      """

      digest =
        Digest.build(
          %{
            "id" => "r1",
            "project" => "web",
            "kind" => "test",
            "status" => "failed",
            "exitCode" => 1,
            "durationMs" => 1500,
            "select" => %{"files" => ["x"]}
          },
          specs,
          log
        )

      assert %{
               "counts" => %{"specs" => 3, "failed" => 2},
               "failures" => [%{"name" => "adds", "message" => _}, %{"file" => "src/b.test.ts"}]
             } = digest

      assert digest["frames"] == ["src/a.ts:12", "tests/test_x.py:7", "pkg/x_test.go:31", "C:/src/Calc.cs:5"]
      text = Digest.text(digest)

      assert text =~
               "web test: failed (exit 1) in 1.5 s; 3 spec files, 1 passed, 2 failed, 0 skipped (scoped)"

      assert text =~ "FAIL src/a.test.ts > adds\n  expected 3\n  to be 4"
      assert text =~ "  at src/a.ts:12"

      assert Digest.text(%{digest | "durationMs" => nil, "failures" => []} |> Map.delete("select")) =~
               "(exit 1); 3 spec"
    end

    test "through the API, and in a log read from an offset with its stream marks" do
      id = record(%{"project" => "web"})
      log(id, "hello\nwarn\n")
      File.write!(Path.join(Config.logs_dir(), id <> ".streams"), "oe")
      finish(id, "failed")
      on_exit(fn -> Store.delete(id) end)

      assert %{"status" => "failed", "counts" => %{}} =
               call(:get, "/api/v1/runs/#{id}/digest", "", "val") |> body()

      assert call(:get, "/api/v1/runs/#{id}/digest?format=text", "", "val").resp_body =~ "web test: failed"
      assert %{status: 404} = call(:get, "/api/v1/runs/nope/digest", "", "val")

      from = call(:get, "/api/v1/runs/#{id}/log?offset=6", "", "val")
      assert from.resp_body == "warn\n"
      assert get_resp_header(from, "x-log-size") == ["11"]
      assert call(:get, "/api/v1/runs/#{id}/log?offset=99", "", "val").resp_body == ""
      assert call(:get, "/api/v1/runs/#{id}/streams?offset=1", "", "val").resp_body == "e"
      assert call(:get, "/api/v1/runs/#{id}/log", "", "val").resp_body =~ "hello"
    end
  end

  describe "scoped runs" do
    test "gates and statuses leave them out, unless a gate allows them" do
      assert Gates.full?(%{})
      refute Gates.full?(%{"select" => %{"files" => ["a"]}})
      refute Gates.full?(%{"session" => "job-1"})
    end
  end

  describe "stream marks from an agent" do
    test "appended at their size, o and e only" do
      {:ok, job} = Jobs.enqueue(%{"project" => "marks", "kind" => "test"}, "ada")
      {:ok, _} = Jobs.lease("bot", [])
      run = record(%{"project" => "marks", "job" => job["id"], "remote" => "bot"})
      on_exit(fn -> Store.delete(run) end)
      Jobs.bind_run(job["id"], "bot", run)

      post = fn query, data ->
        call(:post, "/api/v1/agent/jobs/#{job["id"]}/streams?#{query}", data, "bot")
      end

      assert %{"size" => 3} = post.("offset=0", "ooe") |> body()
      assert %{status: 409} = post.("offset=0", "o")
      assert %{status: 400} = post.("offset=3", "x")
      assert %{status: 400} = post.("", "o")
      assert %{status: 413} = post.("offset=3", String.duplicate("o", 300_000))
      assert File.read!(Path.join(Config.logs_dir(), run <> ".streams")) == "ooe"
      # Ended, so its on_exit can delete it (testor keeps a running run).
      finish(run)
    end
  end

  describe "watch sessions" do
    test "opened, fed snapshots, followed by its agent, ended" do
      first = snapshot!("live", %{"a.ts" => "1"})
      second = snapshot!("live", %{"a.ts" => "2"})
      open = fn body, user -> call(:post, "/api/v1/watches", JSON.encode!(body), user) end

      assert %{status: 403} = open.(%{"project" => "live", "snapshot" => first}, "val")
      assert %{status: 403} = open.(%{"project" => "live", "snapshot" => first}, "lib-admin")

      assert %{status: 400} =
               conn(:post, "/api/v1/watches", "{nope")
               |> put_req_header("content-type", "application/json")
               |> as("ada")
               |> Router.call(@opts)

      assert %{status: 400} = open.(%{"project" => "live"}, "ada")
      assert %{status: 201} = opened = open.(%{"project" => "live", "snapshot" => first}, "ada")
      assert %{"id" => id, "watch" => true, "kind" => "watch", "seq" => 0} = body(opened)
      {:ok, _} = Jobs.lease("bot", [])

      changes = fn after_seq ->
        call(:get, "/api/v1/agent/jobs/#{id}/changes?after=#{after_seq}&wait=0", "", "bot")
      end

      assert %{status: 204} = changes.(0)
      assert %{status: 204} = call(:get, "/api/v1/agent/jobs/#{id}/changes?after=0&wait=1", "", "bot")
      assert %{status: 404} = call(:post, "/api/v1/watches/#{id}/heartbeat", "", "lib-admin")

      assert %{status: 400} =
               conn(:post, "/api/v1/watches/#{id}/changes", "{nope")
               |> put_req_header("content-type", "application/json")
               |> as("ada")
               |> Router.call(@opts)

      change = fn body -> call(:post, "/api/v1/watches/#{id}/changes", JSON.encode!(body), "ada") end
      assert %{status: 400} = change.(%{"snapshot" => "sha256:" <> sha("none")})
      assert %{status: 400} = change.(%{})
      assert %{"seq" => 1} = change.(%{"snapshot" => second}) |> body()
      assert %{"seq" => 1, "snapshot" => ^second} = changes.(0) |> body()
      assert %{status: 404} = call(:get, "/api/v1/agent/jobs/nope/changes", "", "bot")
      assert %{"seq" => 1} = call(:post, "/api/v1/watches/#{id}/heartbeat", "", "ada") |> body()
      assert %{status: 404} = call(:post, "/api/v1/watches/nope/heartbeat", "", "ada")

      {:ok, plain} = Jobs.enqueue(%{"project" => "other", "kind" => "test"}, "ada")
      assert Jobs.watch_seen(plain["id"]) == {:error, :not_found}

      assert %{status: 200} = call(:delete, "/api/v1/watches/#{id}", "", "ada")
      {:ok, _} = Jobs.finish(id, "bot", %{"exitCode" => 0})
      assert %{status: 409} = change.(%{"snapshot" => second})
      assert %{status: 404} = call(:delete, "/api/v1/watches/#{id}", "", "ada")

      config(%{"execution" => %{"enabled" => false}})
      assert %{status: 403} = open.(%{"project" => "live", "snapshot" => first}, "ada")
    end

    test "a session whose client stopped calling ends" do
      snap = snapshot!("idle", %{"a.ts" => "1"})

      {:ok, %{"id" => id}} =
        Jobs.enqueue(%{"project" => "idle", "kind" => "watch", "snapshot" => snap, "watch" => true}, "ada")

      Jobs.sweep_now(System.os_time(:second) + 16 * 60)
      assert wait_until(fn -> Jobs.get(id)["status"] == "cancelled" end)
    end
  end
end
