defmodule Testor.SnapshotsTest do
  @moduledoc """
  Content-addressed snapshots (Testor.Snapshots), the incremental state store (Testor.States),
  their API, jobs that name a snapshot, and the queue's preference for a warm agent: in the
  home, and in a bucket (the fake S3).
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn
  import ExUnit.CaptureLog
  alias Testor.{Config, Jobs, Snapshots, States, Storage}
  alias Testor.Auth.{Guard, Password}
  alias Testor.Test.FakeS3
  alias Testor.Web.Router

  @opts Router.init([])
  @password "correct horse battery"

  setup do
    Guard.reset()
    Jobs.reset()
    home = Config.data_dir()
    for dir <- ["cas", "snapshots", "state", "tmp"], do: File.rm_rf!(Path.join(home, dir))
    config(%{})
    hash = Password.hash(@password, 1000)

    Application.put_env(:testor, :auth, %{
      "users" => %{
        "ada" => %{"password" => hash, "role" => "admin"},
        "val" => %{"password" => hash, "role" => "viewer"},
        "bot" => %{"password" => hash, "role" => "agent"},
        "libbot" => %{"password" => hash, "role" => "agent", "projects" => ["lib"]}
      }
    })

    on_exit(fn ->
      File.rm(Path.join(home, "config.json"))
      Storage.configure(%{type: :files})
      Application.delete_env(:testor, :auth)
      Jobs.reset()
    end)
  end

  defp config(extra) do
    base = %{"execution" => %{"enabled" => true}}
    File.write!(Path.join(Config.data_dir(), "config.json"), JSON.encode!(Map.merge(base, extra)))
  end

  defp s3(presign \\ true) do
    FakeS3.reset()
    System.put_env("AWS_ACCESS_KEY_ID", "AKIDTEST")
    System.put_env("AWS_SECRET_ACCESS_KEY", "secret")

    raw = %{
      "type" => "s3",
      "bucket" => "cas",
      "region" => "us-east-1",
      "endpoint" => FakeS3.endpoint(),
      "pathStyle" => true
    }

    {:ok, cfg} = Testor.Blob.S3.config(raw)
    Storage.configure(Map.merge(cfg, %{type: :s3, presign: presign, cache_bytes: 1_000_000_000}))

    on_exit(fn ->
      FakeS3.answer(nil)
      for var <- ~w(AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY), do: System.delete_env(var)
      Testor.Aws.reset()
    end)
  end

  # Path.wildcard reads a backslash as an escape: Windows' paths go with forward slashes.
  defp glob(parts), do: parts |> Path.join() |> String.replace("\\", "/") |> Path.wildcard()

  defp sha(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)

  defp entry(path, data, mode \\ "644"),
    do: %{"path" => path, "sha256" => sha(data), "mode" => mode, "size" => byte_size(data)}

  defp as(conn, user),
    do: put_req_header(conn, "authorization", "Basic " <> Base.encode64("#{user}:#{@password}"))

  defp call(method, path, body, user, type \\ "application/json") do
    conn(method, path, body)
    |> put_req_header("content-type", type)
    |> put_req_header("x-testor", "1")
    |> as(user)
    |> Router.call(@opts)
  end

  defp body(conn), do: JSON.decode!(conn.resp_body)

  defp upload(data, user \\ "ada"),
    do: call(:put, "/api/v1/blobs/sha256:#{sha(data)}", data, user, "application/octet-stream")

  # A snapshot of two files, every content uploaded: its id.
  defp snapshot!(project, extra \\ %{}) do
    files = [entry("src/a.js", "a"), entry("run.sh", "#!/bin/sh", "755")]
    for data <- ["a", "#!/bin/sh"], do: :ok = put(data)
    {:ok, %{"id" => id, "stored" => true}} = Snapshots.offer(project, Map.put(extra, "files", files))
    id
  end

  defp put(data) do
    path = Path.join(System.tmp_dir!(), "blob-#{System.unique_integer([:positive])}")
    File.write!(path, data)
    on_exit(fn -> File.rm(path) end)
    Snapshots.put_blob(sha(data), path)
  end

  describe "manifests" do
    test "ids, missing contents, then the manifest kept" do
      files = [entry("b.txt", "b"), entry("a/x.txt", "x", "755"), entry("a/y.txt", "b")]

      assert {:ok, %{"id" => "sha256:" <> hex = id, "missing" => missing, "stored" => false}} =
               Snapshots.offer("app", %{"files" => files})

      assert missing == Enum.sort([sha("b"), sha("x")])
      assert Snapshots.manifest("app", hex) == :not_found
      assert :ok = put("b")
      assert {:ok, %{"missing" => [only]}} = Snapshots.offer("app", %{"files" => Enum.reverse(files)})
      assert only == sha("x")
      assert :ok = put("x")
      # Twice is fine: it is there already.
      assert :ok = put("x")

      assert {:ok, %{"id" => ^id, "missing" => [], "stored" => true}} =
               Snapshots.offer("app", %{
                 "files" => files,
                 "branch" => "feat/x",
                 "commit" => String.duplicate("a", 40)
               })

      assert {:ok, %{"files" => kept, "branch" => "feat/x", "bytes" => 3, "project" => "app"}} =
               Snapshots.manifest("app", hex)

      assert Enum.map(kept, & &1["path"]) == ["a/x.txt", "a/y.txt", "b.txt"]
      # The mode is 644 unless said, and part of the id.
      plain = Enum.map(files, &Map.delete(&1, "mode"))
      assert {:ok, %{"id" => other}} = Snapshots.offer("app", %{"files" => plain})
      assert other != id
      assert {:ok, %{"id" => _, "stored" => true}} = Snapshots.offer("app", %{"files" => []})
    end

    test "what a manifest may not hold" do
      config(%{"snapshots" => %{"maxFiles" => 3, "maxFileMB" => 1, "maxMB" => 1}})
      ok = entry("a", "a")

      for {params, message} <- [
            {%{}, "files is a list"},
            {%{"files" => [1]}, "files is a list"},
            {%{"files" => List.duplicate(ok, 4)}, "3 files at most"},
            {%{"files" => [%{ok | "sha256" => "abc"}]}, "64 hex"},
            {%{"files" => [Map.put(ok, "mode", "777")]}, "mode"},
            {%{"files" => [%{ok | "size" => -1}]}, "size"},
            {%{"files" => [%{ok | "size" => 2_000_000}]}, "maxFileMB"},
            {%{"files" => [%{ok | "size" => 700_000}, %{ok | "path" => "b", "size" => 700_000}]}, "maxMB"},
            {%{"files" => [ok, %{ok | "path" => "A"}]}, "case"},
            {%{"files" => [ok, %{ok | "path" => "a/b"}]}, "below a path that is a file"},
            {%{"files" => [ok], "branch" => "-x"}, "branch"},
            {%{"files" => [ok], "commit" => "abc"}, "commit"}
          ] do
        assert {:error, text} = Snapshots.offer("app", params)
        assert text =~ message
      end

      for path <- [
            "",
            "/abs",
            "a//b",
            "./a",
            "a/../b",
            "..",
            ".git/hooks/pre-commit",
            "x/.GIT/config",
            "a\\b",
            "C:/x",
            "a:b",
            "a\nb",
            "dot.",
            "space ",
            String.duplicate("a", 1025),
            <<0xFF>>,
            5
          ] do
        refute Snapshots.path?(path), inspect(path)
        assert {:error, _} = Snapshots.offer("app", %{"files" => [%{ok | "path" => path}]})
      end

      assert Snapshots.path?(".gitignore")
      assert Snapshots.parse_id("sha256:" <> sha("a")) == {:ok, sha("a")}
      assert Snapshots.parse_id("sha256:abc") == :error
      assert Snapshots.parse_id(nil) == :error
    end

    test "contents are checked against their hash and size" do
      config(%{"snapshots" => %{"maxFileMB" => 1}})
      path = Path.join(System.tmp_dir!(), "blob-big")
      File.write!(path, :binary.copy("x", 1_100_000))
      on_exit(fn -> File.rm(path) end)
      assert Snapshots.put_blob(sha("x"), path) == {:error, :too_large}
      File.write!(path, "y")
      assert Snapshots.put_blob(sha("x"), path) == {:error, :digest}
      assert Snapshots.blob(sha("x")) == :not_found
      :ok = put("x")
      assert {:file, file} = Snapshots.blob(sha("x"))
      assert File.read!(file) == "x"
    end

    test "retention: old manifests, then contents no manifest names" do
      id = snapshot!("old")
      "sha256:" <> hex = id
      kept = snapshot!("new", %{"branch" => "main"})
      :ok = put("orphan")
      :ok = put("fresh orphan")
      long_ago = System.os_time(:second) - 30 * 86_400
      File.touch!(Storage.local_path(Snapshots.manifest_key("old", hex)), long_ago)
      File.touch!(Storage.local_path(Snapshots.blob_key(sha("orphan"))), long_ago)
      File.touch!(Storage.local_path(Snapshots.blob_key(sha("a"))), long_ago)

      assert Snapshots.sweep() == %{"snapshots" => 1, "blobs" => 1}
      assert Snapshots.manifest("old", hex) == :not_found
      assert {:ok, _} = Snapshots.manifest("new", kept |> String.replace_prefix("sha256:", ""))
      # Named by the kept snapshot, or too young to be judged.
      assert {:file, _} = Snapshots.blob(sha("a"))
      assert {:file, _} = Snapshots.blob(sha("fresh orphan"))
      assert Snapshots.blob(sha("orphan")) == :not_found
      assert %{"removed" => %{"snapshots" => 0, "blobs" => 0, "states" => 0}} = Testor.Janitor.run("test")
    end
  end

  describe "in a bucket" do
    test "manifests, contents, links to them, retention" do
      s3()
      id = snapshot!("app")
      "sha256:" <> hex = id
      assert {:ok, %{"files" => [_, _]}} = Snapshots.manifest("app", hex)
      assert {:redirect, url} = Snapshots.blob(sha("a"))
      assert url =~ "X-Amz-Signature"
      redirect = call(:get, "/api/v1/agent/blobs/sha256:#{sha("a")}", "", "bot")
      assert redirect.status == 302
      assert [location] = get_resp_header(redirect, "location")
      assert location =~ "X-Amz-Signature"
      assert Snapshots.blob(sha("none")) == :not_found

      # Listed without dates: nothing is old.
      FakeS3.age(Snapshots.manifest_key("app", hex), System.os_time(:second) - 30 * 86_400)
      assert Snapshots.sweep() == %{"snapshots" => 1, "blobs" => 0}

      FakeS3.answer(fn
        "GET", "", %{"list-type" => "2"} ->
          {200,
           "<ListBucketResult><Contents><Key>cas/sha256/aa/x</Key><Size>1</Size></Contents></ListBucketResult>"}

        _, _, _ ->
          nil
      end)

      assert Snapshots.sweep() == %{"snapshots" => 0, "blobs" => 0}
      FakeS3.answer(nil)

      FakeS3.fail(true)
      log = capture_log(fn -> assert Snapshots.sweep() == %{"snapshots" => 0, "blobs" => 0} end)
      assert log =~ "retention skipped"
      assert States.sweep() == 0
      FakeS3.fail(false)
    end

    test "without presigned links, testor sends a content and keeps no copy" do
      s3(false)
      :ok = put("secret-free")
      conn = call(:get, "/api/v1/agent/blobs/sha256:#{sha("secret-free")}", "", "bot")
      assert conn.status == 200
      assert conn.resp_body == "secret-free"
      refute File.exists?(Storage.local_path(Snapshots.blob_key(sha("secret-free"))))
    end

    test "a store that fails" do
      s3()

      FakeS3.answer(fn
        "PUT", "snapshots/" <> _, _ -> {500, "<Error/>"}
        "PUT", "state/" <> _, _ -> {500, "<Error/>"}
        _, _, _ -> nil
      end)

      assert {:error, {:store, _}} = Snapshots.offer("app", %{"files" => []})

      assert %{status: 503} =
               call(:post, "/api/v1/projects/app/snapshots", JSON.encode!(%{"files" => []}), "ada")

      {:ok, job} = Jobs.enqueue(%{"project" => "app", "kind" => "test"}, "ada")
      {:ok, _} = Jobs.lease("bot", [])

      assert %{status: 503} =
               call(
                 :put,
                 "/api/v1/agent/projects/app/state/t?job=#{job["id"]}&branch=main",
                 "x",
                 "bot",
                 "application/octet-stream"
               )

      FakeS3.fail(true)
      assert %{status: 503} = upload("z")
      FakeS3.fail(false)
    end
  end

  describe "the API" do
    test "snapshots: sent by who may execute, read by agents" do
      files = [entry("a.txt", "hello")]

      assert %{status: 403} =
               call(:post, "/api/v1/projects/app/snapshots", JSON.encode!(%{"files" => files}), "val")

      assert %{status: 400} = call(:post, "/api/v1/projects/.../snapshots", "{}", "ada")

      assert %{status: 400} =
               call(:post, "/api/v1/projects/app/snapshots", JSON.encode!(%{"files" => 1}), "ada")

      assert %{status: 200} =
               offered =
               call(:post, "/api/v1/projects/app/snapshots", JSON.encode!(%{"files" => files}), "ada")

      assert %{"missing" => [missing], "id" => id} = body(offered)
      assert missing == sha("hello")

      assert %{status: 403} = upload("hello", "bot")
      assert %{status: 404} = call(:put, "/api/v1/blobs/md5:abc", "hello", "ada")
      assert %{status: 400} = call(:put, "/api/v1/blobs/sha256:#{sha("other")}", "hello", "ada")
      assert %{status: 201} = upload("hello")

      assert %{status: 201} =
               call(:post, "/api/v1/projects/app/snapshots", JSON.encode!(%{"files" => files}), "ada")

      manifest = "/api/v1/agent/projects/app/snapshots/"
      assert %{"files" => [%{"path" => "a.txt"}]} = call(:get, manifest <> id, "", "bot") |> body()
      assert %{status: 403} = call(:get, manifest <> id, "", "val")
      # An agent restricted to other projects.
      assert %{status: 403} = call(:get, manifest <> id, "", "libbot")
      assert %{status: 404} = call(:get, manifest <> "sha256:#{sha("none")}", "", "bot")
      assert %{status: 404} = call(:get, manifest <> "nope", "", "bot")
      assert %{status: 400} = call(:get, "/api/v1/agent/projects/a%20b/snapshots/nope", "", "bot")

      blob = "/api/v1/agent/blobs/sha256:"
      assert %{status: 200, resp_body: "hello"} = call(:get, blob <> sha("hello"), "", "bot")
      assert %{status: 404} = call(:get, blob <> sha("none"), "", "bot")
      assert %{status: 403} = call(:get, blob <> sha("hello"), "", "val")
      assert %{status: 404} = call(:get, "/api/v1/agent/blobs/x", "", "bot")
    end

    test "with authentication off, nobody sends or reads snapshots" do
      Application.put_env(:testor, :auth, %{})

      for {method, path} <- [
            {:post, "/api/v1/projects/app/snapshots"},
            {:put, "/api/v1/blobs/x"},
            {:get, "/api/v1/projects/app/state/x"},
            {:get, "/api/v1/agent/blobs/x"},
            {:get, "/api/v1/agent/projects/app/snapshots/x"},
            {:get, "/api/v1/agent/projects/app/state/x"},
            {:put, "/api/v1/agent/projects/app/state/x"}
          ] do
        conn = conn(method, path, "{}") |> put_req_header("x-testor", "1") |> Router.call(@opts)
        assert %{"error" => %{"code" => "authentication_required"}} = body(conn)
      end
    end

    test "contents are streamed in, within snapshots.maxFileMB" do
      config(%{"snapshots" => %{"maxFileMB" => 2}})
      big = :binary.copy("b", 1_500_000)
      assert %{status: 201} = upload(big)
      assert {:file, path} = Snapshots.blob(sha(big))
      assert File.read!(path) == big
      config(%{"snapshots" => %{"maxFileMB" => 1}})
      too_big = :binary.copy("c", 1_100_000)
      assert %{status: 413} = upload(too_big)
      assert glob([Config.data_dir(), "tmp", "upload-*"]) == []
    end

    test "state: written by the agent holding a job of the project, read back per branch" do
      config(%{"state" => %{"maxMB" => 1}})
      {:ok, job} = Jobs.enqueue(%{"project" => "app", "kind" => "mutation"}, "ada")
      {:ok, other} = Jobs.enqueue(%{"project" => "lib", "kind" => "mutation"}, "ada")
      {:ok, _} = Jobs.lease("bot", [])
      {:ok, _} = Jobs.lease("bot", [])

      put_state = fn project, name, query, data ->
        call(
          :put,
          "/api/v1/agent/projects/#{project}/state/#{name}?#{query}",
          data,
          "bot",
          "application/octet-stream"
        )
      end

      get_state = fn query, user ->
        prefix = if user == "bot", do: "/api/v1/agent", else: "/api/v1"
        call(:get, "#{prefix}/projects/app/state/stryker.json?#{query}", "", user)
      end

      assert %{status: 404} = get_state.("branch=main", "bot")
      assert %{status: 403} = put_state.("app", "stryker.json", "branch=main", "{}")
      assert %{status: 403} = put_state.("app", "stryker.json", "job=#{other["id"]}&branch=main", "{}")
      assert %{status: 403} = put_state.("app", "stryker.json", "job=../x&branch=main", "{}")
      # Without a branch: the default branch's.
      assert %{status: 200} = put_state.("app", "stryker.json", "job=#{job["id"]}", "{}")
      assert %{status: 400} = put_state.("app", "stryker.json", "job=#{job["id"]}&branch=-x", "{}")
      assert %{status: 400} = put_state.("app", "..", "job=#{job["id"]}&branch=main", "{}")

      assert %{status: 413} =
               put_state.("app", "big", "job=#{job["id"]}&branch=main", :binary.copy("x", 1_100_000))

      assert %{status: 403} =
               call(:put, "/api/v1/agent/projects/app/state/s?job=#{job["id"]}&branch=main", "{}", "ada")

      assert %{status: 400} = call(:get, "/api/v1/projects/.../state/s", "", "val")

      assert %{status: 200} = put_state.("app", "stryker.json", "job=#{job["id"]}&branch=main", "main's")
      assert %{status: 200} = put_state.("app", "stryker.json", "job=#{job["id"]}&branch=feat/x", "feat's")

      # A branch's first run gets the default branch's state.
      assert %{status: 200, resp_body: "main's"} = first = get_state.("branch=feat/new", "bot")
      assert get_resp_header(first, "x-testor-state-branch") == ["main"]
      assert %{resp_body: "feat's"} = get_state.("branch=feat/x", "val")
      assert %{resp_body: "main's"} = get_state.("", "bot")
      assert %{status: 400} = get_state.("branch=-bad", "bot")

      assert States.put("app", "main", "x", :binary.copy("x", 1_100_000)) == {:error, :too_large}
      refute States.name?("...")
      assert States.get("other", "main", "stryker.json") == :not_found

      # Retention: a branch's old state goes, the default branch's stays.
      long_ago = System.os_time(:second) - 60 * 86_400

      for path <- glob([Config.data_dir(), "state", "app", "*", "*"]),
          do: File.touch!(path, long_ago)

      assert States.sweep() == 1
      assert %{resp_body: "main's"} = get_state.("branch=feat/x", "bot")
    end
  end

  describe "jobs" do
    test "a job names a snapshot of its project, not with a ref" do
      id = snapshot!("app", %{"branch" => "feat/x", "commit" => String.duplicate("b", 40)})

      assert {:ok, %{"snapshot" => ^id, "branch" => "feat/x", "commit" => _}} =
               Jobs.enqueue(%{"project" => "app", "kind" => "test", "snapshot" => id}, "ada")

      assert {:ok, job} = Jobs.enqueue(%{"project" => "app", "kind" => "test", "snapshot" => nil}, "ada")
      refute Map.has_key?(job, "snapshot")

      for params <- [
            %{"project" => "lib", "snapshot" => id},
            %{"project" => "app", "snapshot" => "sha256:" <> sha("none")},
            %{"project" => "app", "snapshot" => "nope"},
            %{"project" => "a b", "snapshot" => id},
            %{"project" => 5, "snapshot" => id},
            %{"project" => "app", "snapshot" => 5}
          ] do
        assert {:error, text} = Jobs.enqueue(Map.put(params, "kind", "test"), "ada")
        assert text =~ "snapshot is the id"
      end

      assert {:error, "a job names a ref or a snapshot, not both"} =
               Jobs.enqueue(%{"project" => "app", "kind" => "test", "snapshot" => id, "ref" => "main"}, "ada")
    end

    test "the queue waits a moment for the agent that ran the project last" do
      config(%{"execution" => %{"enabled" => true, "warmSeconds" => 1}})
      {:ok, first} = Jobs.enqueue(%{"project" => "warm", "kind" => "test"}, "ada")
      {:ok, _} = Jobs.lease("a1", ["linux"])
      {:ok, _} = Jobs.finish(first["id"], "a1", %{"exitCode" => 0})
      # a1 is idle, asking for jobs: the next job of the project waits for it, a moment.
      assert Jobs.lease("a1", ["linux"]) == :none
      {:ok, second} = Jobs.enqueue(%{"project" => "warm", "kind" => "test"}, "ada")
      assert Jobs.lease("a2", ["gpu"]) == :none
      Process.sleep(1_100)
      assert {:ok, %{"id" => id}} = Jobs.lease("a2", ["gpu"])
      assert id == second["id"]
      {:ok, _} = Jobs.finish(second["id"], "a2", %{"exitCode" => 0})

      # a2 ran it last and is idle, but cannot take a job for linux: a1 takes it at once.
      assert Jobs.lease("a2", ["gpu"]) == :none
      {:ok, third} = Jobs.enqueue(%{"project" => "warm", "kind" => "test", "labels" => ["linux"]}, "ada")
      assert {:ok, %{"id" => id}} = Jobs.lease("a1", ["linux"])
      assert id == third["id"]
      {:ok, _} = Jobs.finish(third["id"], "a1", %{"exitCode" => 0})

      config(%{"execution" => %{"enabled" => true, "warmSeconds" => 0}})
      assert Jobs.lease("a1", []) == :none
      {:ok, fourth} = Jobs.enqueue(%{"project" => "warm", "kind" => "test"}, "ada")
      assert {:ok, %{"id" => id}} = Jobs.lease("a2", [])
      assert id == fourth["id"]
    end
  end
end
