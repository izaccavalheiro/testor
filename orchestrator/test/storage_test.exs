defmodule Testor.StorageTest do
  @moduledoc """
  Runs kept in a bucket (Testor.Storage, one testor): stored once signed, served from the bucket
  when the home lacks them, the home trimmed and restored, deletions, failures, the audit trail.
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn
  import ExUnit.CaptureLog
  import Testor.Test.Helpers
  alias Testor.{Attestation, Audit, Config, Files, Jobs, Storage, Store, Views}
  alias Testor.Auth.Password
  alias Testor.Test.FakeS3
  alias Testor.Web.Router

  @opts Router.init([])
  @password "correct horse battery"

  setup do
    FakeS3.reset()
    System.put_env("AWS_ACCESS_KEY_ID", "AKIDTEST")
    System.put_env("AWS_SECRET_ACCESS_KEY", "secret")
    # One testor: no index in PostgreSQL even where CI has one (Testor.StorageSharedTest).
    Application.put_env(:testor, :storage_shared, false)

    raw = %{
      "type" => "s3",
      "bucket" => "runs",
      "region" => "us-east-1",
      "endpoint" => FakeS3.endpoint(),
      "pathStyle" => true
    }

    {:ok, s3} = Testor.Blob.S3.config(raw)
    cfg = Map.merge(s3, %{type: :s3, presign: true, cache_bytes: 1_000_000_000})
    Storage.configure(cfg)

    on_exit(fn ->
      Storage.configure(%{type: :files})
      File.rm(Path.join(Config.data_dir(), "config.json"))
      for var <- ~w(AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY), do: System.delete_env(var)
      Testor.Aws.reset()
      Application.delete_env(:testor, :storage_shared)
      Application.delete_env(:testor, :audit_max_bytes)
    end)

    %{cfg: cfg, raw: raw}
  end

  defp get(path), do: conn(:get, path) |> Router.call(@opts)

  # Its init again, as when testor starts.
  defp restart(child) do
    :ok = Supervisor.terminate_child(Testor.Supervisor, child)
    {:ok, _} = Supervisor.restart_child(Testor.Supervisor, child)
  end

  # A run with a log, a screenshot, an HTML report and a download, finished and stored.
  defp stored_run(text \\ "hello from the bucket\n") do
    id = record(%{})
    log(id, " ✓ tests/a.test.ts (1 test) 1ms\n" <> text)
    shots = Path.join(Config.shots_dir(), id)
    File.mkdir_p!(shots)
    File.write!(Path.join(shots, "a.png"), "png")
    art = Path.join([Config.artifacts_dir(), id, "report"])
    File.mkdir_p!(art)
    File.write!(Path.join(art, "index.html"), "<h1>report</h1>")
    File.write!(Path.join(art, "img.png"), "img")
    File.write!(Path.join([Config.artifacts_dir(), id, "data.bin"]), "bin")
    finish(id)
    wait_until(fn -> Store.get(id)["stored"] end)
    on_exit(fn -> Store.delete(id) end)
    id
  end

  # What another testor's home is like: the run's record, none of its files.
  defp forget_files(id) do
    File.rm(Config.log_file(id))
    File.rm_rf!(Path.join(Config.shots_dir(), id))
    File.rm_rf!(Path.join(Config.artifacts_dir(), id))
    File.rm(Attestation.file(id))
    File.rm(Storage.local_path("cache/#{id}"))
  end

  test "a finished run is stored once signed; a home without its files is served from the bucket" do
    id = stored_run()

    for key <- [
          "runs/#{id}.json",
          "logs/#{id}.log",
          "screenshots/#{id}/a.png",
          "artifacts/#{id}/report/index.html",
          "artifacts/#{id}/report/img.png",
          "artifacts/#{id}/data.bin",
          "attestations/#{id}.dsse.json"
        ],
        do: assert(key in FakeS3.keys(), key)

    assert JSON.decode!(FakeS3.object("runs/#{id}.json").data)["stored"] == true
    assert Testor.Query.compact(Store.get(id))["stored"] == true
    forget_files(id)

    snapshot = Views.run_snapshot(id)
    assert snapshot["log"] =~ "hello from the bucket"
    assert snapshot["run"]["attested"]
    assert [%{"path" => "a.png", "bytes" => 3}] = snapshot["screenshots"]
    assert snapshot["artifacts"] |> Enum.map(& &1["path"]) |> Enum.sort() == ["data.bin", "report"]
    assert get("/api/runs/#{id}/log").resp_body =~ "hello from the bucket"

    # Images and downloads: presigned links. What the sandbox shows: fetched and served here.
    shot = get("/shots/#{id}/a.png")
    assert shot.status == 302 and get_resp_header(shot, "cache-control") == ["no-store"]
    [location] = get_resp_header(shot, "location")
    assert {:ok, {{_, 200, _}, _, ~c"png"}} = :httpc.request(String.to_charlist(location))

    html = get("/artifacts/#{id}/report/index.html")
    assert html.status == 200 and html.resp_body == "<h1>report</h1>"
    assert [csp] = get_resp_header(html, "content-security-policy")
    assert csp =~ "sandbox"

    download = get("/artifacts/#{id}/data.bin")
    assert download.status == 302
    assert download |> get_resp_header("location") |> hd() =~ "response-content-disposition=attachment"
    image = get("/artifacts/#{id}/report/img.png")
    assert image |> get_resp_header("location") |> hd() =~ "response-content-type=image%2Fpng"

    # Nothing the run's listing lacks, no presigned link to nothing.
    assert get("/shots/#{id}/none.png").status == 404
    assert get("/artifacts/#{id}/none.bin").status == 404
    assert get("/artifacts/20990101-000000-abcdef/x.bin").status == 404

    # Without presigned links, testor serves everything itself.
    File.rm_rf!(Path.join(Config.shots_dir(), id))
    Storage.configure(%{Storage.config() | presign: false})
    shot = get("/shots/#{id}/a.png")
    assert shot.status == 200 and shot.resp_body == "png"
  end

  test "reports only the bucket holds (sent through another testor) count when the run ends" do
    id = record(%{})
    on_exit(fn -> Store.delete(id) end)
    log(id, "no specs here\n")

    FakeS3.put_object("reports/#{id}/junit.xml", """
    <testsuites><testsuite name="s" file="tests/far.test.ts"><testcase name="one" time="0.1"/></testsuite></testsuites>
    """)

    run = finish(id)
    assert run["specsFrom"] == "reports"
    assert [%{"file" => "tests/far.test.ts"}] = run["specs"]
  end

  test "the home is trimmed to cacheMB; a trimmed run is fetched again", %{cfg: cfg} do
    id = stored_run("trim me\n")
    Storage.configure(%{cfg | cache_bytes: 0})
    assert Storage.trim() > 0
    refute File.exists?(Config.log_file(id))
    refute File.exists?(Path.join(Config.shots_dir(), id))
    assert File.exists?(Config.run_file(id))
    assert Views.run_snapshot(id)["log"] =~ "trim me"

    # Its timer does the same.
    Views.run_snapshot(id)
    assert File.exists?(Config.log_file(id))
    send(Storage, :trim)
    :sys.get_state(Storage)
    refute File.exists?(Config.log_file(id))
    Storage.configure(%{type: :files})
    assert Storage.trim() == 0
  end

  test "records the home lacks are restored from the bucket" do
    id = stored_run()
    File.rm!(Config.run_file(id))
    wait_until(fn -> Store.get(id) == nil end)

    assert :ok = Storage.restore()
    assert File.exists?(Config.run_file(id))
    wait_until(fn -> Store.get(id) end)
    assert :ok = Storage.restore()

    FakeS3.fail(true)
    assert capture_log(fn -> assert :error = Storage.restore() end) =~ "none restored"
  end

  test "a deleted run's objects go, but for those Object Lock keeps" do
    id = stored_run()
    FakeS3.lock(["logs/#{id}.log"])
    capture_log(fn -> assert :ok = Store.delete(id) end)
    assert Enum.filter(FakeS3.keys(), &String.contains?(&1, id)) == ["logs/#{id}.log"]
  end

  test "failures: logged, nothing marked stored" do
    assert Storage.publish("20990101-000000-abcdef") == {:error, "no such run"}

    id = record(%{})
    on_exit(fn -> Store.delete(id) end)
    log(id, "x\n")
    FakeS3.fail(true)

    log =
      capture_log(fn ->
        finish(id)
        wait_until(fn -> Attestation.exists?(id) end)
        Process.sleep(500)
      end)

    assert log =~ "could not be stored"
    refute Store.get(id)["stored"]
    assert {:error, "answered 500" <> _} = Storage.publish(id)

    # A listing that fails is empty, and not kept.
    File.rm_rf!(Path.join(Config.shots_dir(), id))
    assert capture_log(fn -> assert Files.screenshots(id) == [] end) =~ "cannot be listed"

    Storage.configure(%{type: :files})
    assert Storage.publish(id) == :off
    assert Storage.serve("screenshots/#{id}/a.png", "image/png") == :not_found
  end

  test "a file that cannot be sent or fetched" do
    id = record(%{})
    on_exit(fn -> Store.delete(id) end)
    log(id, "x\n")

    refuse = fn key ->
      FakeS3.answer(fn _, k, _ -> if k == key, do: {500, "<Error><Code>InternalError</Code></Error>"} end)
    end

    refuse.("logs/#{id}.log")
    capture_log(fn -> finish(id) end)
    assert {:error, "logs/" <> why} = Storage.publish(id)
    assert why =~ "answered 500"
    FakeS3.answer(nil)
    {:ok, _} = Storage.publish(id)

    # Stored, then lost here: what the bucket will not hand back stays out.
    File.mkdir_p!(Path.join(Config.shots_dir(), id))
    File.write!(Path.join([Config.shots_dir(), id, "a.png"]), "png")
    {:ok, _} = Storage.publish(id)
    forget_files(id)
    refuse.("logs/#{id}.log")
    assert capture_log(fn -> Views.run_snapshot(id) end) =~ "could not be fetched"
    refuse.("screenshots/#{id}/a.png")
    Storage.configure(%{Storage.config() | presign: false})
    assert get("/shots/#{id}/a.png").status == 404
    assert Storage.serve("no-area", nil) == :not_found
    FakeS3.answer(nil)
  end

  test "storage in config.json, read when testor starts" do
    path = Path.join(Config.data_dir(), "config.json")
    write = &File.write!(path, JSON.encode!(%{"storage" => &1}))

    File.rm(path)
    assert Storage.read_config() == %{type: :files}
    write.(%{"type" => "files"})
    assert Storage.read_config() == %{type: :files}

    write.(%{"type" => "s3", "bucket" => "runs", "region" => "r", "cacheMB" => 10, "presign" => false})
    assert %{type: :s3, cache_bytes: 10_485_760, presign: false} = Storage.read_config()
    write.(%{"type" => "s3", "bucket" => "runs", "region" => "r"})
    assert %{cache_bytes: 2_147_483_648, presign: true} = Storage.read_config()

    log =
      capture_log(fn ->
        write.(%{"type" => "s3", "bucket" => "No"})
        assert Storage.read_config() == %{type: :files}
        write.(%{"type" => "gcs"})
        assert Storage.read_config() == %{type: :files}
      end)

    assert log =~ "bucket is a bucket name" and log =~ ~s(type is "files", "s3" or "azure")

    # Started with it: the bucket's runs restored; started without it again: the home.
    write.(%{
      "type" => "s3",
      "bucket" => "runs",
      "region" => "us-east-1",
      "endpoint" => FakeS3.endpoint(),
      "pathStyle" => true
    })

    restart(Storage)
    assert Storage.s3?()
    File.rm!(path)
    restart(Storage)
    refute Storage.s3?()
  end

  test "another testor's run, as the index hands it over" do
    id = run_id()
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    run = %{
      "id" => id,
      "project" => "far",
      "kind" => "test",
      "status" => "running",
      "startedAt" => now,
      "remote" => "pod-1"
    }

    Store.indexed(run, 2)
    wait_until(fn -> Store.get(id) end)
    # An older version is not applied over a newer one.
    Store.indexed(Map.put(run, "status", "failed"), 1)
    :sys.get_state(Store)
    assert Store.get(id)["status"] == "running"

    ended =
      Map.merge(run, %{"status" => "passed", "endedAt" => now, "summary" => %{"specs" => 0}, "stored" => true})

    Store.indexed(ended, 3)
    wait_until(fn -> Store.get(id)["status"] == "passed" end)

    Store.unindexed(id)
    wait_until(fn -> Store.get(id) == nil end)
  end

  test "an agent's files go to the bucket as they arrive; a bucket that refuses is a 503" do
    File.write!(
      Path.join(Config.data_dir(), "config.json"),
      JSON.encode!(%{"execution" => %{"enabled" => true}})
    )

    hash = Password.hash(@password, 1000)

    Application.put_env(:testor, :auth, %{
      "users" => %{
        "ada" => %{"password" => hash, "role" => "admin"},
        "bot" => %{"password" => hash, "role" => "agent"}
      }
    })

    Jobs.reset()

    on_exit(fn ->
      Jobs.reset()
      Application.delete_env(:testor, :auth)
    end)

    {:ok, job} = Jobs.enqueue(%{"project" => "far-app", "kind" => "test"}, "ada")
    {:ok, _} = Jobs.lease("bot", [])
    run = run_id()
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    as = fn conn ->
      conn
      |> put_req_header("authorization", "Basic " <> Base.encode64("bot:#{@password}"))
      |> put_req_header("x-testor", "1")
      |> Router.call(@opts)
    end

    put_run =
      conn(
        :put,
        "/api/v1/agent/jobs/#{job["id"]}/run",
        JSON.encode!(%{"id" => run, "status" => "running", "startedAt" => now})
      )
      |> put_req_header("content-type", "application/json")
      |> as.()

    assert put_run.status == 200

    on_exit(fn ->
      Store.settle(run, "cancelled")
      Store.delete(run)
    end)

    file = fn path ->
      conn(:put, "/api/v1/agent/jobs/#{job["id"]}/files/#{path}", "PNG")
      |> put_req_header("content-type", "application/octet-stream")
      |> as.()
    end

    assert file.("screenshots/a.png").status == 200
    assert "screenshots/#{run}/a.png" in FakeS3.keys()

    FakeS3.fail(true)
    refused = file.("screenshots/b.png")
    assert refused.status == 503 and get_resp_header(refused, "retry-after") == ["5"]
    assert JSON.decode!(refused.resp_body)["error"]["code"] == "storage_unavailable"
    FakeS3.fail(false)
  end

  test "the audit trail goes to the bucket; a new home continues its chain from there" do
    Audit.record("storage-test", %{"n" => 1})
    Audit.ship_now()
    prefix = "audit/#{Testor.Cluster.instance()}/"
    assert Enum.any?(FakeS3.keys(), &String.starts_with?(&1, prefix))

    FakeS3.fail(true)
    Audit.record("storage-test", %{"n" => 2})
    assert capture_log(fn -> Audit.ship_now() end) =~ "could not be sent"
    FakeS3.fail(false)
    send(Audit, :ship)
    :sys.get_state(Audit)

    last = Audit.file() |> File.read!() |> String.split("\n", trim: true) |> List.last()
    File.rm!(Audit.file())
    restart(Audit)
    Audit.record("storage-test", %{"n" => 3})
    assert [%{"prev" => prev}] = Audit.tail(1)
    assert prev == Base.encode16(:crypto.hash(:sha256, last), case: :lower)

    # A file that is renamed is sent first.
    Application.put_env(:testor, :audit_max_bytes, 1)
    before = length(FakeS3.keys())
    Audit.record("storage-test", %{"n" => 4})
    Audit.flush()
    Application.delete_env(:testor, :audit_max_bytes)
    assert length(FakeS3.keys()) > before

    # The renamed files go: the audit tests count theirs.
    prefix = Audit.file() |> Path.basename() |> String.replace_suffix(".jsonl", "-")

    for name <- File.ls!(Config.data_dir()),
        String.starts_with?(name, prefix),
        do: File.rm!(Path.join(Config.data_dir(), name))
  end
end
