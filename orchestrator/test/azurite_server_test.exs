defmodule Testor.AzuriteServerTest do
  @moduledoc """
  The object store contract against Azurite, Azure Blob Storage's emulator, which checks Shared
  Key signatures and MD5s. Tagged `brokers`, run where TESTOR_BROKERS=1 (CI's brokers job starts
  it): TESTOR_AZURITE_ENDPOINT, with Azurite's well-known account and key.
  """
  use ExUnit.Case, async: false
  alias Testor.Blob.Azure

  @moduletag :brokers
  @moduletag :tmp_dir
  @key "Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw=="

  setup do
    System.put_env("AZURE_STORAGE_KEY", @key)

    on_exit(fn ->
      System.delete_env("AZURE_STORAGE_KEY")
      Application.delete_env(:testor, :azure_blocks_over)
      Application.delete_env(:testor, :azure_block_size)
    end)

    {:ok, cfg} =
      Azure.config(%{
        "account" => "devstoreaccount1",
        "container" => "testor-ci",
        "endpoint" => System.fetch_env!("TESTOR_AZURITE_ENDPOINT"),
        "prefix" => "run-#{System.unique_integer([:positive])}"
      })

    :ok = Azure.create_container(cfg)
    %{cfg: cfg}
  end

  test "put, get, head, list, presign, delete", %{cfg: cfg, tmp_dir: tmp} do
    file = Path.join(tmp, "a.log")
    File.write!(file, "line one\n")
    assert :ok = Azure.put(cfg, "logs/r1.log", {:file, file})
    assert :ok = Azure.put(cfg, "runs/r1 x.json", ~s({"id": "r1"}))
    assert {:ok, "line one\n"} = Azure.get(cfg, "logs/r1.log", :binary)
    assert :not_found = Azure.get(cfg, "logs/none.log", :binary)
    assert {:ok, %{size: 9, sha256: sha}} = Azure.head(cfg, "logs/r1.log")
    assert sha == Base.encode64(:crypto.hash(:sha256, "line one\n"))

    assert {:ok, [%{key: "logs/r1.log", size: 9, modified: at}, %{key: "runs/r1 x.json"}]} =
             Azure.list(cfg, "")

    assert is_integer(at)

    # The SAS link works without credentials, for a browser.
    {:ok, url} = Azure.presign(cfg, "runs/r1 x.json", 300, filename: "r1.json")
    assert {:ok, {{_, 200, _}, _, ~c'{"id": "r1"}'}} = :httpc.request(String.to_charlist(url))

    assert {:ok, ["logs/r1.log", "runs/r1 x.json"], []} = Azure.delete(cfg, ["logs/r1.log", "runs/r1 x.json"])
    assert {:ok, []} = Azure.list(cfg, "")
  end

  test "a large file in blocks", %{cfg: cfg, tmp_dir: tmp} do
    Application.put_env(:testor, :azure_blocks_over, 1_048_576)
    Application.put_env(:testor, :azure_block_size, 1_048_576)
    file = Path.join(tmp, "big.bin")
    data = :crypto.strong_rand_bytes(2_500_000)
    File.write!(file, data)
    assert :ok = Azure.put(cfg, "artifacts/big.bin", {:file, file})
    assert {:ok, ^data} = Azure.get(cfg, "artifacts/big.bin", :binary)
  end
end
