defmodule Testor.AzureTest do
  @moduledoc """
  The object store port over Azure Blob Storage (Testor.Blob.Azure) against the fake service
  (Testor.Test.FakeAzure): Shared Key signatures, MD5-checked uploads in one request or in
  blocks, listings in pages, deletes that keep protected blobs, SAS links, Microsoft Entra
  workload identity; and Testor.Storage keeping runs in a container.
  """
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias Testor.Blob.Azure
  alias Testor.Storage
  alias Testor.Test.FakeAzure

  @moduletag :tmp_dir

  setup do
    FakeAzure.reset()
    Azure.reset()
    System.put_env("AZURE_STORAGE_KEY", FakeAzure.key())

    on_exit(fn ->
      for var <-
            ~w(AZURE_STORAGE_KEY AZURE_FEDERATED_TOKEN_FILE AZURE_CLIENT_ID AZURE_TENANT_ID AZURE_AUTHORITY_HOST),
          do: System.delete_env(var)

      Azure.reset()
      Application.delete_env(:testor, :azure_blocks_over)
      Application.delete_env(:testor, :azure_block_size)
      Storage.configure(%{type: :files})
    end)

    {:ok, cfg} =
      Azure.config(%{
        "account" => "devstoreaccount1",
        "container" => "runs",
        "endpoint" => FakeAzure.endpoint() <> "/devstoreaccount1",
        "prefix" => "/t/"
      })

    %{cfg: cfg}
  end

  test "config: an account, a container, an endpoint" do
    assert {:ok, %{bucket: "runs", prefix: "", endpoint: "https://acme.blob.core.windows.net"}} =
             Azure.config(%{"account" => "acme", "container" => "runs"})

    assert {:ok, %{public_endpoint: "https://files.example.com"}} =
             Azure.config(%{
               "account" => "acme",
               "container" => "runs",
               "publicEndpoint" => "https://files.example.com/"
             })

    for {raw, text} <- [
          {%{"container" => "runs"}, "account"},
          {%{"account" => "Acme!", "container" => "runs"}, "account"},
          {%{"account" => "acme", "container" => "A"}, "container"},
          {%{"account" => "acme", "container" => "runs", "endpoint" => "ftp://x"}, "endpoint"},
          {%{"account" => "acme", "container" => "runs", "publicEndpoint" => 5}, "publicEndpoint"}
        ] do
      assert {:error, message} = Azure.config(raw)
      assert message =~ text
    end

    assert Azure.config("x") == {:error, "it is an object"}
  end

  test "put, get, head, list, delete, presign", %{cfg: cfg, tmp_dir: tmp} do
    assert Azure.create_container(cfg) == :ok
    assert Azure.put(cfg, "runs/a b.json", ~s({"x": 1})) == :ok
    file = Path.join(tmp, "a.log")
    File.write!(file, "line\n")
    assert Azure.put(cfg, "logs/a.log", {:file, file}) == :ok
    assert {:error, :enoent} = Azure.put(cfg, "logs/none", {:file, Path.join(tmp, "none")})

    assert Azure.get(cfg, "runs/a b.json", :binary) == {:ok, ~s({"x": 1})}
    assert Azure.get(cfg, "nope", :binary) == :not_found
    assert Azure.get(cfg, "logs/a.log", {:file, Path.join(tmp, "out/a.log")}) == :ok
    assert File.read!(Path.join(tmp, "out/a.log")) == "line\n"
    assert Azure.get(cfg, "nope", {:file, Path.join(tmp, "out/nope")}) == :not_found
    refute File.exists?(Path.join(tmp, "out/nope"))

    sha = Base.encode64(:crypto.hash(:sha256, "line\n"))
    assert Azure.head(cfg, "logs/a.log") == {:ok, %{size: 5, sha256: sha}}
    assert Azure.head(cfg, "nope") == :not_found
    assert Map.keys(FakeAzure.blobs()) |> Enum.sort() == ["t/logs/a.log", "t/runs/a b.json"]

    FakeAzure.page(1)

    assert {:ok, [%{key: "logs/a.log", size: 5, modified: modified}, %{key: "runs/a b.json"}]} =
             Azure.list(cfg, "")

    assert modified == DateTime.to_unix(~U[2026-11-26 10:00:00Z])
    FakeAzure.modified("not a date")
    assert {:ok, [%{modified: nil}, _]} = Azure.list(cfg, "")

    {:ok, url} = Azure.presign(cfg, "logs/a.log", 300, filename: "a.log")
    assert url =~ "sr=b&sp=r" and url =~ "rscd=attachment" and url =~ "&sig="
    {:ok, inline} = Azure.presign(cfg, "logs/a.log", 300, type: "image/png")
    assert inline =~ "rsct=image%2Fpng"

    FakeAzure.lock(["t/runs/a b.json"])

    log =
      capture_log(fn ->
        assert {:ok, ["logs/a.log", "gone"], ["runs/a b.json"]} =
                 Azure.delete(cfg, ["logs/a.log", "gone", "runs/a b.json"])
      end)

    assert log =~ "immutability policy"
    assert {:ok, [], []} = Azure.delete(cfg, [])
  end

  test "large files in blocks, each with its MD5", %{cfg: cfg, tmp_dir: tmp} do
    Application.put_env(:testor, :azure_blocks_over, 100)
    Application.put_env(:testor, :azure_block_size, 64)
    file = Path.join(tmp, "big.bin")
    data = :crypto.strong_rand_bytes(300)
    File.write!(file, data)
    assert Azure.put(cfg, "artifacts/big.bin", {:file, file}) == :ok
    assert Azure.get(cfg, "artifacts/big.bin", :binary) == {:ok, data}
    assert {:ok, %{size: 300, sha256: sha}} = Azure.head(cfg, "artifacts/big.bin")
    assert sha == Base.encode64(:crypto.hash(:sha256, data))

    FakeAzure.fail(true)
    assert {:error, "answered 500 (InternalError)"} = Azure.put(cfg, "artifacts/big2.bin", {:file, file})
  end

  test "failures: the service, the network, credentials", %{cfg: cfg, tmp_dir: tmp} do
    FakeAzure.fail(true)

    for result <- [
          Azure.put(cfg, "a", "x"),
          Azure.get(cfg, "a", :binary),
          Azure.get(cfg, "a", {:file, Path.join(tmp, "a")}),
          Azure.head(cfg, "a"),
          Azure.list(cfg, ""),
          Azure.delete(cfg, ["a"]),
          Azure.create_container(cfg)
        ] do
      assert {:error, "answered 500" <> _} = result
    end

    FakeAzure.fail(false)
    System.put_env("AZURE_STORAGE_KEY", Base.encode64("another key"))
    assert {:error, "answered 403 (AuthenticationFailed)"} = Azure.put(cfg, "a", "x")

    System.delete_env("AZURE_STORAGE_KEY")
    assert {:error, "no Azure credentials" <> _} = Azure.get(cfg, "a", :binary)
    assert Azure.presign(cfg, "a", 60, []) == :none

    {:ok, closed} =
      Azure.config(%{
        "account" => "devstoreaccount1",
        "container" => "runs",
        "endpoint" => "http://127.0.0.1:1/devstoreaccount1"
      })

    System.put_env("AZURE_STORAGE_KEY", FakeAzure.key())
    assert {:error, "failed (" <> _} = Azure.get(closed, "a", :binary)
  end

  test "Microsoft Entra workload identity: a federated token traded for an access token, kept", %{
    cfg: cfg,
    tmp_dir: tmp
  } do
    System.delete_env("AZURE_STORAGE_KEY")
    jwt = Path.join(tmp, "token")
    File.write!(jwt, "federated-jwt\n")
    System.put_env("AZURE_FEDERATED_TOKEN_FILE", jwt)
    System.put_env("AZURE_CLIENT_ID", "client")
    System.put_env("AZURE_TENANT_ID", "tenant")
    System.put_env("AZURE_AUTHORITY_HOST", FakeAzure.endpoint() <> "/")

    assert Azure.put(cfg, "a.txt", "x") == :ok
    assert Azure.get(cfg, "a.txt", :binary) == {:ok, "x"}
    assert FakeAzure.tokens() == 1
    # No SAS links without the account key: testor serves the files itself.
    assert Azure.presign(cfg, "a.txt", 60, []) == :none

    # Near its end, a token is traded again.
    :persistent_term.put({Azure, :token}, {"old", System.os_time(:second) + 60})
    assert Azure.get(cfg, "a.txt", :binary) == {:ok, "x"}
    assert FakeAzure.tokens() == 2

    Azure.reset()
    File.write!(jwt, "wrong")
    assert {:error, "Microsoft Entra did not give an access token" <> _} = Azure.get(cfg, "a.txt", :binary)
  end

  test "Testor.Storage keeps runs in a container" do
    raw = %{
      "type" => "azure",
      "account" => "devstoreaccount1",
      "container" => "runs",
      "endpoint" => FakeAzure.endpoint() <> "/devstoreaccount1"
    }

    File.write!(Testor.Config.config_file(), JSON.encode!(%{"storage" => raw}))
    on_exit(fn -> File.rm(Testor.Config.config_file()) end)

    assert %{type: :azure, bucket: "runs", presign: true} = cfg = Storage.read_config()
    Storage.configure(cfg)
    assert Storage.s3?()
    assert {Azure, ^cfg} = Storage.blob()
    assert Storage.adapter_for(cfg) == Azure
    assert Storage.adapter_for(%{type: :s3}) == Testor.Blob.S3

    File.write!(Testor.Config.config_file(), JSON.encode!(%{"storage" => Map.delete(raw, "account")}))
    log = capture_log(fn -> assert Storage.read_config() == %{type: :files} end)
    assert log =~ "account"
    File.write!(Testor.Config.config_file(), JSON.encode!(%{"storage" => %{"type" => "gcs"}}))
    log = capture_log(fn -> assert Storage.read_config() == %{type: :files} end)
    assert log =~ ~s("azure")
  end
end
