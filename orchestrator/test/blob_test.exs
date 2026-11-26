defmodule Testor.BlobTest do
  @moduledoc "The object store port: one contract for a folder and for S3, then what only S3 does."
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias Testor.{Aws, Blob}
  alias Testor.Aws.SigV4
  alias Testor.Blob.S3
  alias Testor.Test.FakeS3

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    FakeS3.reset()
    System.put_env("AWS_ACCESS_KEY_ID", "AKIDTEST")
    System.put_env("AWS_SECRET_ACCESS_KEY", "secret")

    on_exit(fn ->
      for var <- ~w(AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN), do: System.delete_env(var)
      Aws.reset()
      Application.delete_env(:testor, :s3_multipart_over)
      Application.delete_env(:testor, :s3_part_size)
    end)

    {:ok, s3} =
      S3.config(%{
        "bucket" => "runs",
        "region" => "us-east-1",
        "endpoint" => FakeS3.endpoint(),
        "pathStyle" => true,
        "prefix" => "/team/"
      })

    %{files: {Blob.Files, %{root: Path.join(tmp, "blobs")}}, s3: {S3, s3}, tmp: tmp}
  end

  for store <- [:files, :s3] do
    test "#{store}: put, get, head, list, delete", %{unquote(store) => {adapter, cfg}, tmp: tmp} do
      source = Path.join(tmp, "source.log")
      File.write!(source, "line one\n")

      assert :ok = adapter.put(cfg, "logs/r1.log", {:file, source})
      assert :ok = adapter.put(cfg, "runs/r1.json", ~s({"id":"r1"}))
      assert :ok = adapter.put(cfg, "screenshots/r1/a b/shot.png", "png")
      # Written again: replaced.
      assert :ok = adapter.put(cfg, "runs/r1.json", ~s({"id":"r1","status":"passed"}))

      assert {:ok, ~s({"id":"r1","status":"passed"})} = adapter.get(cfg, "runs/r1.json", :binary)
      copy = Path.join([tmp, "out", "copy.log"])
      assert :ok = adapter.get(cfg, "logs/r1.log", {:file, copy})
      assert File.read!(copy) == "line one\n"
      assert {:ok, %{size: 9}} = adapter.head(cfg, "logs/r1.log")

      assert adapter.get(cfg, "logs/none.log", :binary) == :not_found
      assert adapter.get(cfg, "logs/none.log", {:file, copy}) == :not_found
      assert adapter.head(cfg, "logs/none.log") == :not_found

      assert {:ok, [%{key: "screenshots/r1/a b/shot.png", size: 3}]} = adapter.list(cfg, "screenshots/r1/")
      assert {:ok, [%{key: "runs/r1.json"}]} = adapter.list(cfg, "runs/r1")
      assert {:ok, all} = adapter.list(cfg, "")
      assert Enum.map(all, & &1.key) == ["logs/r1.log", "runs/r1.json", "screenshots/r1/a b/shot.png"]
      assert {:ok, []} = adapter.list(cfg, "nothing/")

      assert {:ok, ["screenshots/r1/a b/shot.png"], []} = Blob.delete_prefix(adapter, cfg, "screenshots/r1/")
      assert {:ok, [], []} = Blob.delete_prefix(adapter, cfg, "screenshots/r1/")
      assert adapter.head(cfg, "screenshots/r1/a b/shot.png") == :not_found
      assert {:ok, ["logs/r1.log"], []} = adapter.delete(cfg, ["logs/r1.log"])
      assert {:ok, [%{key: "runs/r1.json"}]} = adapter.list(cfg, "")
    end
  end

  test "keys: relative, without empty, dot or dot-dot parts" do
    assert Blob.key?("logs/r1.log") and Blob.key?("artifacts/r1/report/index.html")

    for bad <- ["", "/logs/x", "logs//x", "logs/./x", "logs/../x", "logs\\x", "a" <> <<0>>, nil],
        do: refute(Blob.key?(bad), inspect(bad))
  end

  test "files: what a folder refuses, and how it cleans up", %{files: {adapter, cfg}, tmp: tmp} do
    assert {:error, :bad_key} = adapter.put(cfg, "../escape", "x")
    assert {:error, :bad_key} = adapter.get(cfg, "../escape", :binary)
    assert {:error, :bad_key} = adapter.head(cfg, "../escape")
    assert {:ok, [], ["../escape"]} = adapter.delete(cfg, ["../escape"])
    assert {:error, :enoent} = adapter.put(cfg, "logs/x.log", {:file, Path.join(tmp, "missing")})
    assert adapter.presign(cfg, "logs/x.log", 60, []) == :none

    # A folder where the file would go: the write fails, and leaves no temporary file.
    File.mkdir_p!(Path.join([cfg.root, "runs", "taken.json", "inside"]))
    assert {:error, _} = adapter.put(cfg, "runs/taken.json", "x")
    assert {:ok, []} = adapter.list(cfg, "runs/")
    assert :ok = adapter.put(cfg, "runs/r.json", "x")
    target = Path.join(tmp, "target")
    File.mkdir_p!(Path.join(target, "inside"))
    assert {:error, _} = adapter.get(cfg, "runs/r.json", {:file, target})

    # Deleting a folder's last file removes the folders it leaves empty.
    :ok = adapter.put(cfg, "screenshots/r2/deep/a.png", "x")
    {:ok, _, _} = adapter.delete(cfg, ["screenshots/r2/deep/a.png"])
    refute File.exists?(Path.join(cfg.root, "screenshots"))

    # A link inside the folder is not followed.
    outside = Path.join(tmp, "outside")
    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "secret"), "x")

    case File.ln_s(outside, Path.join(cfg.root, "link")) do
      :ok -> assert {:error, :bad_key} = adapter.get(cfg, "link/secret", :binary)
      {:error, _} -> :ok
    end
  end

  test "s3: a large file goes in parts, each with its checksum", %{s3: {adapter, cfg}, tmp: tmp} do
    Application.put_env(:testor, :s3_multipart_over, 10)
    Application.put_env(:testor, :s3_part_size, 8)
    big = Path.join(tmp, "big.bin")
    File.write!(big, "0123456789abcdefghijklmnop")

    assert :ok = adapter.put(cfg, "artifacts/r1/big.bin", {:file, big})
    assert FakeS3.object("team/artifacts/r1/big.bin").data == File.read!(big)
    parts = for {"PUT", _, "partNumber=" <> _, _} <- FakeS3.requests(), do: :part
    assert length(parts) == 4

    # A part refused: the upload is aborted.
    FakeS3.fail_parts(true)
    assert {:error, "answered 500: SlowDown"} = adapter.put(cfg, "artifacts/r1/other.bin", {:file, big})
    assert Enum.any?(FakeS3.requests(), &match?({"DELETE", _, "uploadId=" <> _, _}, &1))
    # S3 can answer the completion 200 with an error in it.
    FakeS3.fail_parts(:complete)
    assert {:error, "answered 200: InternalError"} = adapter.put(cfg, "artifacts/r1/other.bin", {:file, big})
    FakeS3.fail_parts(false)
    # The completion refused, or an upload started without an id.
    FakeS3.answer(fn method, _, q ->
      if method == "POST" and q["uploadId"], do: {503, "<Error><Code>SlowDown</Code></Error>"}
    end)

    assert {:error, "answered 503: SlowDown"} = adapter.put(cfg, "artifacts/r1/other.bin", {:file, big})
    FakeS3.answer(fn method, _, q -> if method == "POST" and q["uploads"], do: {200, "<Nothing/>"} end)
    assert {:error, "unexpected answer"} = adapter.put(cfg, "artifacts/r1/other.bin", {:file, big})
    FakeS3.answer(nil)
    # The upload not started at all.
    FakeS3.fail(true)
    assert {:error, "answered 500: InternalError"} = adapter.put(cfg, "artifacts/r1/other.bin", {:file, big})
  end

  test "s3: listing in pages, deleting with keys Object Lock keeps", %{s3: {adapter, cfg}} do
    for n <- 1..5, do: :ok = adapter.put(cfg, "logs/r#{n}.log", "x")
    FakeS3.page(2)
    assert {:ok, objects} = adapter.list(cfg, "logs/")
    assert Enum.map(objects, & &1.key) == for(n <- 1..5, do: "logs/r#{n}.log")

    FakeS3.lock(["team/logs/r2.log"])

    log =
      capture_log(fn ->
        assert {:ok, deleted, ["logs/r2.log"]} = Blob.delete_prefix(adapter, cfg, "logs/")
        assert length(deleted) == 4
      end)

    assert log =~ "1 objects were kept"
    assert FakeS3.keys() == ["team/logs/r2.log"]
  end

  test "s3: every object signed, its checksum sent, encrypted as configured", %{s3: {adapter, cfg}} do
    :ok = adapter.put(cfg, "runs/r.json", "{}")
    {"PUT", "/runs/team/runs/r.json", _, headers} = List.last(FakeS3.requests())
    assert {"x-amz-checksum-sha256", Base.encode64(:crypto.hash(:sha256, "{}"))} in headers
    refute List.keymember?(headers, "x-amz-server-side-encryption", 0)

    kms = %{cfg | encryption: "aws:kms", kms_key_id: "arn:aws:kms:k"}
    :ok = adapter.put(kms, "runs/r.json", "{}")
    {_, _, _, headers} = List.last(FakeS3.requests())
    assert {"x-amz-server-side-encryption", "aws:kms"} in headers
    assert {"x-amz-server-side-encryption-aws-kms-key-id", "arn:aws:kms:k"} in headers

    :ok = adapter.put(%{cfg | encryption: "aws:kms", kms_key_id: nil}, "runs/r.json", "{}")
    {_, _, _, headers} = List.last(FakeS3.requests())
    refute List.keymember?(headers, "x-amz-server-side-encryption-aws-kms-key-id", 0)

    :ok = adapter.put(%{cfg | encryption: "AES256"}, "runs/r.json", "{}")
    {_, _, _, headers} = List.last(FakeS3.requests())
    assert {"x-amz-server-side-encryption", "AES256"} in headers
  end

  test "s3: presigned links open the object until they expire", %{s3: {adapter, cfg}} do
    :ok = adapter.put(cfg, "artifacts/r/a.bin", "payload")

    assert {:ok, url} = adapter.presign(cfg, "artifacts/r/a.bin", 300, filename: "a.bin")
    assert url =~ "X-Amz-Signature=" and url =~ "X-Amz-Expires=300"
    assert url =~ "response-content-disposition=attachment%3B%20filename%3D%22a.bin%22"
    assert {:ok, {{_, 200, _}, _, ~c"payload"}} = :httpc.request(String.to_charlist(url))

    assert {:ok, url} =
             adapter.presign(%{cfg | public_endpoint: "https://files.example.com"}, "x/y.png", 60,
               type: "image/png"
             )

    assert url =~ "https://files.example.com/runs/team/x/y.png?" and
             url =~ "response-content-type=image%2Fpng"

    System.delete_env("AWS_ACCESS_KEY_ID")
    assert adapter.presign(cfg, "x", 60, []) == :none
  end

  test "SigV4 presigns as AWS's documentation says" do
    url =
      SigV4.presign(
        "GET",
        URI.parse("https://examplebucket.s3.amazonaws.com/test.txt"),
        %{key: "AKIAIOSFODNN7EXAMPLE", secret: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"},
        "us-east-1",
        "s3",
        ~U[2013-05-24 00:00:00Z],
        86_400
      )

    assert url =~ "X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404"

    # A session token is part of what is signed.
    token =
      SigV4.presign(
        "GET",
        URI.parse("https://h.example/k"),
        %{key: "K", secret: "S", token: "T"},
        "r",
        "s3",
        ~U[2013-05-24 00:00:00Z],
        60
      )

    assert token =~ "X-Amz-Security-Token=T"
  end

  test "s3: failures are errors, never crashes", %{s3: {adapter, cfg}, tmp: tmp} do
    FakeS3.fail(true)
    file = Path.join(tmp, "f")
    File.write!(file, "x")

    for result <- [
          adapter.put(cfg, "k", "x"),
          adapter.put(cfg, "k", {:file, file}),
          adapter.get(cfg, "k", :binary),
          adapter.get(cfg, "k", {:file, Path.join(tmp, "g")}),
          adapter.head(cfg, "k"),
          adapter.list(cfg, ""),
          adapter.delete(cfg, ["k"])
        ],
        do: assert({:error, "answered 500" <> _} = result)

    refute File.exists?(Path.join(tmp, "g"))
    assert {:error, :enoent} = adapter.put(cfg, "k", {:file, Path.join(tmp, "missing")})

    gone = %{cfg | endpoint: "http://127.0.0.1:1"}
    assert {:error, "failed (" <> _} = adapter.get(gone, "k", :binary)

    System.delete_env("AWS_ACCESS_KEY_ID")
    assert {:error, "no credentials" <> _} = adapter.head(cfg, "k")
  end

  test "s3: its config, and the URLs it makes" do
    base = %{"bucket" => "runs", "region" => "eu-west-1"}
    assert {:ok, cfg} = S3.config(base)
    assert cfg.endpoint == "https://s3.eu-west-1.amazonaws.com" and cfg.public_endpoint == cfg.endpoint
    assert cfg.prefix == "" and cfg.path_style == false

    assert URI.to_string(S3.object_uri(cfg, cfg.endpoint, "logs/a b.log")) ==
             "https://runs.s3.eu-west-1.amazonaws.com/logs/a%20b.log"

    assert URI.to_string(S3.object_uri(cfg, cfg.endpoint, nil)) == "https://runs.s3.eu-west-1.amazonaws.com/"

    for {bad, why} <- [
          {%{base | "bucket" => "No"}, "bucket"},
          {Map.delete(base, "region"), "region"},
          {Map.put(base, "endpoint", "ftp://x"), "endpoint"},
          {Map.put(base, "publicEndpoint", "nope"), "publicEndpoint"},
          {Map.put(base, "encryption", "rot13"), "encryption"}
        ] do
      assert {:error, message} = S3.config(bad)
      assert String.starts_with?(message, why)
    end

    assert {:error, "it is an object"} = S3.config("runs")

    assert S3.content_type("a.jsonl") == ~c"application/x-ndjson"
    assert S3.content_type("a.log") == ~c"text/plain; charset=utf-8"
    assert S3.content_type("a.json") == ~c"application/json"
    assert S3.content_type("a.png") == ~c"image/png"
  end
end
