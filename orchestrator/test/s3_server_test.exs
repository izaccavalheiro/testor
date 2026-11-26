defmodule Testor.S3ServerTest do
  @moduledoc """
  The object store contract against a real S3 server: versitygw, which checks SigV4 signatures
  and SHA-256 checksums. Tagged `brokers`, run where TESTOR_BROKERS=1 (CI's brokers job starts
  it): TESTOR_S3_ENDPOINT, a bucket `testor-ci`, TESTOR_S3_ACCESS_KEY and TESTOR_S3_SECRET_KEY.
  """
  use ExUnit.Case, async: false
  alias Testor.Blob
  alias Testor.Blob.S3

  @moduletag :brokers
  @moduletag :tmp_dir

  setup do
    System.put_env("AWS_ACCESS_KEY_ID", System.fetch_env!("TESTOR_S3_ACCESS_KEY"))
    System.put_env("AWS_SECRET_ACCESS_KEY", System.fetch_env!("TESTOR_S3_SECRET_KEY"))

    on_exit(fn ->
      System.delete_env("AWS_ACCESS_KEY_ID")
      System.delete_env("AWS_SECRET_ACCESS_KEY")
      Application.delete_env(:testor, :s3_multipart_over)
      Application.delete_env(:testor, :s3_part_size)
    end)

    {:ok, cfg} =
      S3.config(%{
        "bucket" => "testor-ci",
        "region" => "us-east-1",
        "endpoint" => System.fetch_env!("TESTOR_S3_ENDPOINT"),
        "pathStyle" => true,
        "prefix" => "run-#{System.unique_integer([:positive])}"
      })

    %{cfg: cfg}
  end

  test "put, get, head, list, presign, delete", %{cfg: cfg, tmp_dir: tmp} do
    file = Path.join(tmp, "a.log")
    File.write!(file, "line one\n")
    assert :ok = S3.put(cfg, "logs/r1.log", {:file, file})
    assert :ok = S3.put(cfg, "runs/r1.json", ~s({"id":"r1"}))
    assert :ok = S3.put(cfg, "screenshots/r1/a b/shot.png", "png")

    assert {:ok, ~s({"id":"r1"})} = S3.get(cfg, "runs/r1.json", :binary)
    assert :ok = S3.get(cfg, "logs/r1.log", {:file, Path.join(tmp, "copy.log")})
    assert File.read!(Path.join(tmp, "copy.log")) == "line one\n"
    assert {:ok, %{size: 9}} = S3.head(cfg, "logs/r1.log")
    assert S3.get(cfg, "logs/none.log", :binary) == :not_found
    assert S3.head(cfg, "logs/none.log") == :not_found

    assert {:ok, objects} = S3.list(cfg, "")
    assert Enum.map(objects, & &1.key) == ["logs/r1.log", "runs/r1.json", "screenshots/r1/a b/shot.png"]

    assert {:ok, url} = S3.presign(cfg, "screenshots/r1/a b/shot.png", 60, type: "image/png")
    assert {:ok, {{_, 200, _}, _, ~c"png"}} = :httpc.request(String.to_charlist(url))

    assert {:ok, deleted, []} = Blob.delete_prefix(S3, cfg, "")
    assert length(deleted) == 3
    assert {:ok, []} = S3.list(cfg, "")
  end

  test "a large file in parts", %{cfg: cfg, tmp_dir: tmp} do
    # S3's smallest part is 5 MB (but the last).
    Application.put_env(:testor, :s3_multipart_over, 6 * 1_048_576)
    Application.put_env(:testor, :s3_part_size, 5 * 1_048_576)
    big = Path.join(tmp, "big.bin")
    data = :crypto.strong_rand_bytes(11 * 1_048_576)
    File.write!(big, data)

    assert :ok = S3.put(cfg, "artifacts/r1/big.bin", {:file, big})
    assert {:ok, %{size: size}} = S3.head(cfg, "artifacts/r1/big.bin")
    assert size == byte_size(data)
    assert {:ok, ^data} = S3.get(cfg, "artifacts/r1/big.bin", :binary)
    {:ok, _, _} = Blob.delete_prefix(S3, cfg, "")
  end
end
