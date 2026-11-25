defmodule Testor.JobsTest do
  @moduledoc "Jobs: the queue, leases, heartbeats, expiry, cancelling, and their API with its scopes."
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn
  import ExUnit.CaptureLog
  import Testor.Test.Helpers
  alias Testor.{Config, Jobs, Store}
  alias Testor.Auth.{Guard, Password}
  alias Testor.Web.Router

  @password "correct horse battery"
  @opts Router.init([])

  defp config(execution) do
    File.write!(Path.join(Config.data_dir(), "config.json"), JSON.encode!(%{"execution" => execution}))
  end

  setup do
    Guard.reset()
    :sys.replace_state(Jobs, fn _ -> %{} end)
    File.rm_rf!(Jobs.dir())
    File.mkdir_p!(Jobs.dir())
    config(%{"enabled" => true, "leaseSeconds" => 30, "maxAttempts" => 2})

    on_exit(fn ->
      File.rm(Path.join(Config.data_dir(), "config.json"))
      :sys.replace_state(Jobs, fn _ -> %{} end)
      Application.delete_env(:testor, :auth)
    end)
  end

  defp job!(project, kind \\ "test", extra \\ %{}) do
    {:ok, job} = Jobs.enqueue(Map.merge(%{"project" => project, "kind" => kind}, extra), "ada")
    # Ids hold the second and random bytes; the oldest is the smallest id.
    Process.sleep(2)
    job
  end

  defp as(conn, user),
    do: put_req_header(conn, "authorization", "Basic " <> Base.encode64("#{user}:#{@password}"))

  defp post_json(path, body, user) do
    conn(:post, path, JSON.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> as(user)
    |> Router.call(@opts)
  end

  defp body(conn), do: JSON.decode!(conn.resp_body)

  describe "the queue" do
    test "off until execution.enabled; jobs are checked" do
      config(%{"enabled" => false})
      assert Jobs.enqueue(%{"project" => "p", "kind" => "k"}, "ada") == {:error, :disabled}
      config(%{"enabled" => true})

      for {params, message} <- [
            {%{"kind" => "k"}, "project"},
            {%{"project" => "a b", "kind" => "k"}, "project"},
            {%{"project" => "p", "kind" => "k;rm"}, "kind"},
            {%{"project" => "p", "kind" => "k", "labels" => "gpu"}, "labels"},
            {%{"project" => "p", "kind" => "k", "labels" => ["ok", "not ok"]}, "labels"},
            {%{"project" => "p", "kind" => "k", "ref" => "--upload-pack=x"}, "ref"},
            {%{"project" => "p", "kind" => "k", "ref" => 5}, "ref"}
          ] do
        assert {:error, text} = Jobs.enqueue(params, "ada")
        assert text =~ message
      end

      assert {:ok,
              %{
                "status" => "queued",
                "labels" => ["gpu"],
                "ref" => "main",
                "requestedBy" => "ada",
                "attempts" => 0
              } = job} =
               Jobs.enqueue(
                 %{"project" => "p", "kind" => "k", "labels" => ["gpu", "gpu"], "ref" => "main"},
                 "ada"
               )

      assert Jobs.get(job["id"]) == job
      assert [^job] = Jobs.list("queued")
      assert Jobs.list("passed") == []
    end

    test "agents take the oldest job they can: labels, and one job per project at a time" do
      gpu = job!("app", "gpu-tests", %{"labels" => ["gpu"]})
      first = job!("app")
      second = job!("app", "lint")
      other = job!("lib")

      assert {:ok, %{"id" => id, "status" => "leased", "agent" => "a1", "attempts" => 1}} =
               Jobs.lease("a1", [])

      assert id == first["id"]
      # app is busy now: the next job anyone can take is lib's.
      assert {:ok, %{"id" => lib}} = Jobs.lease("a2", ["gpu"])
      assert lib == other["id"]
      assert Jobs.lease("a3", ["gpu"]) == :none

      {:ok, _} = Jobs.finish(first["id"], "a1", %{"exitCode" => 0})
      assert {:ok, %{"id" => next}} = Jobs.lease("a1", [])
      assert next == second["id"]
      {:ok, _} = Jobs.finish(second["id"], "a1", %{"exitCode" => 0})
      assert Jobs.lease("a1", []) == :none
      assert {:ok, %{"id" => with_gpu}} = Jobs.lease("a3", ["gpu", "linux"])
      assert with_gpu == gpu["id"]
    end

    test "heartbeats keep a lease, link the run and pass on a cancel; only the holder may" do
      job = job!("linked")
      {:ok, _} = Jobs.lease("a1", [])
      assert Jobs.heartbeat(job["id"], "a2") == {:error, :not_yours}
      assert Jobs.heartbeat("nope", "a1") == {:error, :not_found}
      assert {:ok, %{"cancel" => false}} = Jobs.heartbeat(job["id"], "a1")
      assert %{"status" => "running", "startedAt" => _} = Jobs.get(job["id"])
      refute Map.has_key?(Jobs.get(job["id"]), "runId")

      run = record(%{"project" => "linked", "job" => job["id"], "pid" => 0})
      on_exit(fn -> Store.delete(run) end)
      assert {:ok, %{"cancel" => false}} = Jobs.heartbeat(job["id"], "a1")
      assert %{"runId" => ^run} = Jobs.get(job["id"])

      capture_log(fn -> assert {:ok, %{"cancelRequested" => true}} = Jobs.cancel(job["id"]) end)
      # The run was cancelled the usual way.
      assert %{"status" => "cancelled"} = Store.get(run)
      assert {:ok, %{"cancel" => true}} = Jobs.heartbeat(job["id"], "a1")

      assert {:ok, %{"status" => "cancelled", "exitCode" => nil}} =
               Jobs.finish(job["id"], "a1", %{"exitCode" => "x"})

      assert Jobs.heartbeat(job["id"], "a1") == {:error, :ended}
      assert Jobs.finish(job["id"], "a1", %{}) == {:error, :ended}
    end

    test "a job that ended before the store read its run finds it when read" do
      job = job!("quick")
      {:ok, _} = Jobs.lease("a1", [])
      {:ok, done} = Jobs.finish(job["id"], "a1", %{"exitCode" => 0})
      refute Map.has_key?(done, "runId")
      assert [%{"id" => _} = listed] = Jobs.list("passed")
      refute Map.has_key?(listed, "runId")

      run = record(%{"project" => "quick", "job" => job["id"], "status" => "passed"})
      on_exit(fn -> Store.delete(run) end)
      assert %{"runId" => ^run} = Jobs.get(job["id"])
      assert [%{"runId" => ^run}] = Jobs.list("passed")
      assert Jobs.get("nope") == nil
    end

    test "results: passed, failed, an error kept short" do
      a = job!("results-a")
      b = job!("results-b")
      c = job!("results-c")
      for _ <- 1..3, do: {:ok, _} = Jobs.lease("a1", [])

      assert {:ok, %{"status" => "passed", "exitCode" => 0, "endedAt" => _} = done} =
               Jobs.finish(a["id"], "a1", %{"exitCode" => 0})

      refute Map.has_key?(done, "leaseUntil")
      assert {:ok, %{"status" => "failed", "exitCode" => 3}} = Jobs.finish(b["id"], "a1", %{"exitCode" => 3})

      assert {:ok, %{"status" => "failed", "error" => error}} =
               Jobs.finish(c["id"], "a1", %{"error" => String.duplicate("x", 900)})

      assert String.length(error) == 500
      d = job!("results-d")
      {:ok, _} = Jobs.lease("a1", [])

      assert {:ok, %{"error" => "%{\"not\" => \"text\"}"}} =
               Jobs.finish(d["id"], "a1", %{"error" => %{"not" => "text"}})
    end

    test "cancelling a queued job, an ended one, a missing one" do
      job = job!("cancel-me")
      assert {:ok, %{"status" => "cancelled"}} = Jobs.cancel(job["id"])
      assert Jobs.cancel(job["id"]) == {:error, :ended}
      assert Jobs.cancel("nope") == {:error, :not_found}
      assert Jobs.lease("a1", []) == :none
    end

    test "a job whose agent stops answering goes back to the queue, then expires" do
      job = job!("lost")
      {:ok, _} = Jobs.lease("a1", [])
      later = System.os_time(:second) + 3600

      log =
        capture_log(fn ->
          jobs = Jobs.sweep(:sys.get_state(Jobs), later)
          :sys.replace_state(Jobs, fn _ -> jobs end)
        end)

      assert log =~ "queued again"
      assert %{"status" => "queued", "attempts" => 1, "error" => _} = Jobs.get(job["id"])
      refute Map.has_key?(Jobs.get(job["id"]), "agent")

      {:ok, %{"attempts" => 2}} = Jobs.lease("a2", [])
      capture_log(fn -> :sys.replace_state(Jobs, &Jobs.sweep(&1, later)) end)
      assert %{"status" => "expired", "endedAt" => _} = Jobs.get(job["id"])

      # A job being cancelled is not tried again.
      held = job!("lost-cancelled")
      {:ok, _} = Jobs.lease("a1", [])
      {:ok, _} = Jobs.cancel(held["id"])
      capture_log(fn -> :sys.replace_state(Jobs, &Jobs.sweep(&1, later)) end)
      assert %{"status" => "expired"} = Jobs.get(held["id"])

      # The timer sweeps too; a fresh lease is left alone.
      fresh = job!("fresh")
      {:ok, _} = Jobs.lease("a1", [])
      send(Jobs, :sweep)
      assert %{"status" => "leased"} = Jobs.get(fresh["id"])
    end

    test "jobs survive a restart; a file that is not a job is left out" do
      job = job!("kept")
      File.write!(Path.join(Jobs.dir(), "broken.json"), "{nope")
      assert {:ok, jobs} = Jobs.init(nil)
      assert jobs == %{job["id"] => job}
    end
  end

  describe "the API" do
    setup do
      hash = Password.hash(@password, 1000)

      Application.put_env(:testor, :auth, %{
        "users" => %{
          "ada" => %{"password" => hash, "role" => "admin"},
          "val" => %{"password" => hash, "role" => "viewer"},
          "bot" => %{"password" => hash, "role" => "agent"},
          "bot2" => %{"password" => hash, "role" => "agent"}
        }
      })

      Application.put_env(:testor, :lease_poll_ms, 20)
      on_exit(fn -> Application.delete_env(:testor, :lease_poll_ms) end)
    end

    test "admins queue and cancel jobs; viewers and agents cannot" do
      assert %{status: 201} =
               created = post_json("/api/v1/jobs", %{"project" => "api", "kind" => "test"}, "ada")

      id = body(created)["id"]
      assert %{status: 403} = post_json("/api/v1/jobs", %{"project" => "api", "kind" => "test"}, "val")
      assert %{status: 403} = post_json("/api/v1/jobs", %{"project" => "api", "kind" => "test"}, "bot")
      assert %{status: 400} = post_json("/api/v1/jobs", %{"project" => "a b"}, "ada")

      bad =
        conn(:post, "/api/v1/jobs", "{nope")
        |> put_req_header("content-type", "application/json")
        |> as("ada")
        |> Router.call(@opts)

      assert bad.status == 400

      assert %{"data" => [%{"id" => ^id}]} =
               conn(:get, "/api/v1/jobs?status=queued") |> as("val") |> Router.call(@opts) |> body()

      assert %{status: 400} = conn(:get, "/api/v1/jobs?status=nope") |> as("val") |> Router.call(@opts)
      assert %{"id" => ^id} = conn(:get, "/api/v1/jobs/#{id}") |> as("val") |> Router.call(@opts) |> body()
      assert %{status: 404} = conn(:get, "/api/v1/jobs/nope") |> as("val") |> Router.call(@opts)

      assert %{status: 200} = post_json("/api/v1/jobs/#{id}/cancel", %{}, "ada")
      assert %{status: 409} = post_json("/api/v1/jobs/#{id}/cancel", %{}, "ada")
      assert %{status: 404} = post_json("/api/v1/jobs/nope/cancel", %{}, "ada")

      config(%{"enabled" => false})

      assert %{status: 403} =
               disabled = post_json("/api/v1/jobs", %{"project" => "api", "kind" => "test"}, "ada")

      assert body(disabled)["error"]["code"] == "execution_disabled"
    end

    test "agents lease, beat and finish; others cannot" do
      assert %{status: 204} = post_json("/api/v1/agent/lease", %{"labels" => ["x"], "wait" => 0}, "bot")
      # Waiting: nothing comes within a moment.
      assert %{status: 204} = post_json("/api/v1/agent/lease", %{"wait" => 1}, "bot")
      assert %{status: 403} = post_json("/api/v1/agent/lease", %{}, "ada")

      %{"id" => id} = job!("agent-api")

      assert %{status: 200} =
               leased = post_json("/api/v1/agent/lease", %{"labels" => "not a list", "wait" => 3}, "bot")

      assert body(leased)["id"] == id

      assert %{"cancel" => false} = post_json("/api/v1/agent/jobs/#{id}/heartbeat", %{}, "bot") |> body()
      assert %{status: 409} = post_json("/api/v1/agent/jobs/#{id}/heartbeat", %{}, "bot2")
      assert %{status: 404} = post_json("/api/v1/agent/jobs/nope/heartbeat", %{}, "bot")

      bad =
        conn(:post, "/api/v1/agent/jobs/#{id}/finish", "{nope")
        |> put_req_header("content-type", "application/json")
        |> as("bot")
        |> Router.call(@opts)

      assert bad.status == 400

      badlease =
        conn(:post, "/api/v1/agent/lease", "{nope")
        |> put_req_header("content-type", "application/json")
        |> as("bot")
        |> Router.call(@opts)

      assert badlease.status == 400

      assert %{"status" => "passed"} =
               post_json("/api/v1/agent/jobs/#{id}/finish", %{"exitCode" => 0}, "bot") |> body()

      assert %{status: 409} = post_json("/api/v1/agent/jobs/#{id}/finish", %{"exitCode" => 0}, "bot")
    end

    test "with authentication off nobody queues or takes jobs" do
      Application.put_env(:testor, :auth, %{})

      json =
        &(conn(:post, &1, "{}") |> put_req_header("content-type", "application/json") |> Router.call(@opts))

      assert %{status: 403} = json.("/api/v1/jobs")
      assert %{status: 403} = json.("/api/v1/agent/lease")
      assert %{status: 403} = json.("/api/v1/agent/jobs/job-1/heartbeat")
    end
  end
end
