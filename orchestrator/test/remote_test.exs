defmodule Testor.RemoteTest do
  @moduledoc "Runs recorded on other machines: records, log chunks, files, cancelling, lost agents."
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn
  import ExUnit.CaptureLog
  import Testor.Test.Helpers
  alias Testor.{Config, Files, Jobs, Store}
  alias Testor.Auth.{Guard, Password}
  alias Testor.Web.Router

  @password "correct horse battery"
  @opts Router.init([])

  setup do
    Guard.reset()
    :sys.replace_state(Jobs, fn _ -> %{} end)
    File.rm_rf!(Jobs.dir())
    File.mkdir_p!(Jobs.dir())

    File.write!(
      Path.join(Config.data_dir(), "config.json"),
      JSON.encode!(%{"execution" => %{"enabled" => true}, "artifacts" => %{"maxRunMB" => 1}})
    )

    hash = Password.hash(@password, 1000)

    Application.put_env(:testor, :auth, %{
      "users" => %{
        "ada" => %{"password" => hash, "role" => "admin"},
        "bot" => %{"password" => hash, "role" => "agent"},
        "bot2" => %{"password" => hash, "role" => "agent"}
      }
    })

    on_exit(fn ->
      File.rm(Path.join(Config.data_dir(), "config.json"))
      :sys.replace_state(Jobs, fn _ -> %{} end)
      Application.delete_env(:testor, :auth)
    end)

    {:ok, job} = Jobs.enqueue(%{"project" => "far-app", "kind" => "test"}, "ada")
    {:ok, _} = Jobs.lease("bot", [])
    %{job: job["id"]}
  end

  defp as(conn, user),
    do: put_req_header(conn, "authorization", "Basic " <> Base.encode64("#{user}:#{@password}"))

  defp put_run(job, run, user \\ "bot") do
    conn(:put, "/api/v1/agent/jobs/#{job}/run", JSON.encode!(run))
    |> put_req_header("content-type", "application/json")
    |> as(user)
    |> Router.call(@opts)
  end

  defp log(job, offset, data) do
    conn(:post, "/api/v1/agent/jobs/#{job}/log?offset=#{offset}", data)
    |> put_req_header("content-type", "text/plain")
    # Basic credentials need the CSRF header; the agent sends a Bearer token instead.
    |> put_req_header("x-testor", "1")
    |> as("bot")
    |> Router.call(@opts)
  end

  defp file(job, path, data) do
    conn(:put, "/api/v1/agent/jobs/#{job}/files/#{path}", data)
    |> put_req_header("content-type", "application/octet-stream")
    |> put_req_header("x-testor", "1")
    |> as("bot")
    |> Router.call(@opts)
  end

  defp body(conn), do: JSON.decode!(conn.resp_body)

  # A run still running cannot be deleted: settle it first, so no test leaves one behind.
  defp cleanup(run) do
    Store.settle(run, "cancelled")
    Store.delete(run)
  end

  defp record_of(run_id, extra \\ %{}) do
    Map.merge(
      %{
        "id" => run_id,
        "project" => "evil",
        "kind" => "evil",
        "job" => "evil",
        "pid" => 4242,
        "command" => "npm test",
        "status" => "running",
        "startedAt" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "actor" => %{"user" => "ci"}
      },
      extra
    )
  end

  test "a remote run is recorded with the job's project, task and job, and no pid", %{job: job} do
    run = run_id()
    on_exit(fn -> cleanup(run) end)

    assert %{status: 409} = conn = log(job, 0, "too early")
    assert body(conn)["error"]["code"] == "no_run"

    assert %{status: 200} = put_run(job, record_of(run))
    wait_until(fn -> Store.get(run) end)

    assert %{
             "project" => "far-app",
             "kind" => "test",
             "job" => ^job,
             "remote" => "bot",
             "pid" => nil,
             "actor" => %{"user" => "ci"}
           } =
             Store.get(run)

    assert %{"runId" => ^run} = Jobs.get(job)

    # The tracker leaves it alone: its process is not on this machine.
    Process.sleep(3_500)
    assert %{"status" => "running"} = Store.get(run)

    # The log, in chunks at offsets.
    assert %{status: 200} = log(job, 0, " ✓ tests/a.test.ts (2 tests) 3ms\n")
    size = byte_size(" ✓ tests/a.test.ts (2 tests) 3ms\n")
    assert %{status: 409} = stale = log(job, 0, "again")
    assert get_resp_header(stale, "x-log-size") == ["#{size}"]
    assert %{"size" => _} = log(job, size, "line two\n") |> body()
    assert %{status: 400} = log(job, "x", "no offset")

    # Files.
    assert %{"bytes" => 3} = file(job, "screenshots/e2e/login.png", "png") |> body()
    assert %{status: 400} = file(job, "screenshots/notes.txt", "text")
    assert %{status: 400} = file(job, "elsewhere/a.png", "png")
    assert %{status: 400} = file(job, "artifacts/../../auth.json", "{}")
    assert %{status: 400} = file(job, "artifacts/" <> Enum.map_join(1..40, "/", &"d#{&1}") <> "/f", "x")
    assert %{"bytes" => 5} = file(job, "artifacts/coverage/index.html", "<html") |> body()
    # Sent again (a retry): replaced, and counted once against the run's limit.
    assert %{"bytes" => 6} = file(job, "artifacts/coverage/index.html", "<html>") |> body()
    assert %{status: 413} = file(job, "artifacts/big.bin", :binary.copy("x", 2 * 1024 * 1024))

    # The end: its record, final; nothing changes after it.
    assert %{status: 200} =
             put_run(job, record_of(run, %{"status" => "passed", "exitCode" => 0, "durationMs" => 9}))

    wait_until(fn -> match?(%{"status" => "passed", "summary" => %{"specs" => 1}}, Store.get(run)) end)
    assert [%{"path" => "e2e/login.png"}] = Files.screenshots(run)
    assert [%{"path" => "coverage", "kind" => "report"}] = Files.artifacts(run)
    assert Files.tail(Config.log_file(run), 1000).text =~ "line two"

    assert %{status: 409} = final = put_run(job, record_of(run))
    assert body(final)["error"]["code"] == "final"
    assert %{status: 409} = log(job, 0, "late")
  end

  test "records the agent cannot write", %{job: job} do
    run = run_id()
    on_exit(fn -> cleanup(run) end)
    assert %{status: 400} = put_run(job, record_of("../../x"))
    assert %{status: 400} = put_run(job, record_of(run, %{"status" => "weird"}))
    assert %{status: 409} = put_run(job, record_of(run), "bot2")
    assert %{status: 404} = put_run("job-nope", record_of(run))
    assert %{status: 403} = put_run(job, record_of(run), "ada")

    # A run that is another job's.
    other = run_id()
    File.mkdir_p!(Config.runs_dir())
    Files.write_json(Config.run_file(other), %{"id" => other, "job" => "job-other", "status" => "running"})
    on_exit(fn -> File.rm(Config.run_file(other)) end)
    assert %{status: 409} = put_run(job, record_of(other))

    assert %{status: 200} = put_run(job, record_of(run))
    assert %{status: 409} = taken = put_run(job, record_of(run_id()))
    assert body(taken)["error"]["code"] == "other_run"

    bad =
      conn(:put, "/api/v1/agent/jobs/#{job}/run", "{nope")
      |> put_req_header("content-type", "application/json")
      |> as("bot")
      |> Router.call(@opts)

    assert bad.status == 400
  end

  test "limits on chunks, logs and files", %{job: job} do
    run = run_id()
    on_exit(fn -> cleanup(run) end)
    put_run(job, record_of(run))
    Application.put_env(:testor, :remote_chunk_max, 4)
    Application.put_env(:testor, :remote_file_max, 4)
    Application.put_env(:testor, :remote_log_max, 6)

    on_exit(fn ->
      for key <- [:remote_chunk_max, :remote_file_max, :remote_log_max],
          do: Application.delete_env(:testor, key)
    end)

    assert %{status: 413} = log(job, 0, "12345")
    assert %{status: 200} = log(job, 0, "1234")
    assert %{status: 413} = log(job, 4, "567")
    assert %{status: 413} = file(job, "artifacts/x.txt", "12345")
  end

  test "cancelling a remote run asks its agent; a lost agent aborts its run", %{job: job} do
    run = run_id()
    on_exit(fn -> cleanup(run) end)
    put_run(job, record_of(run))
    wait_until(fn -> Store.get(run) end)

    # Through the run, or through the job: the agent hears it; the run waits for its record.
    assert {:ok, %{"status" => "running"}} = Testor.Web.Actions.cancel(run)
    assert %{"cancelRequested" => true} = Jobs.get(job)
    assert {:ok, _} = Jobs.cancel(job)
    assert %{"status" => "running"} = Store.get(run)
    assert {:ok, %{"cancel" => true}} = Jobs.heartbeat(job, "bot")

    # The agent stops answering: the job expires (or is tried again) and the run is aborted.
    capture_log(fn -> :sys.replace_state(Jobs, &Jobs.sweep(&1, System.os_time(:second) + 3600)) end)
    assert %{"status" => "aborted"} = Store.get(run)
    # The job no longer holds the run (a new attempt binds its own); reading it shows its last.
    refute Map.has_key?(:sys.get_state(Jobs)[job], "runId")
    assert %{"runId" => ^run} = Jobs.get(job)
  end

  test "binding a run needs the job held", %{job: job} do
    assert Jobs.bind_run("job-nope", "bot", run_id()) == {:error, :not_found}
    assert Jobs.bind_run(job, "bot2", run_id()) == {:error, :not_yours}
  end

  test "a remote run whose job is gone is cancelled here" do
    run = record(%{"remote" => "bot", "job" => "job-gone", "pid" => nil})
    on_exit(fn -> cleanup(run) end)
    capture_log(fn -> assert {:ok, %{"status" => "cancelled"}} = Testor.Web.Actions.cancel(run) end)
  end
end
