defmodule Testor.StorageCLITest do
  @moduledoc "A home moved into a bucket (Testor.Storage.CLI): once, resumably, checked there, and back."
  use ExUnit.Case, async: false
  import Testor.Test.Helpers
  alias Testor.{Attestation, Audit, Config, Store}
  alias Testor.Storage.CLI
  alias Testor.Test.FakeS3

  @moduletag :tmp_dir

  setup do
    FakeS3.reset()
    System.put_env("AWS_ACCESS_KEY_ID", "AKIDTEST")
    System.put_env("AWS_SECRET_ACCESS_KEY", "secret")
    config = Path.join(Config.data_dir(), "config.json")

    File.write!(
      config,
      JSON.encode!(%{
        "storage" => %{
          "type" => "s3",
          "bucket" => "runs",
          "region" => "us-east-1",
          "endpoint" => FakeS3.endpoint(),
          "pathStyle" => true
        }
      })
    )

    on_exit(fn ->
      File.rm(config)
      for var <- ~w(AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY), do: System.delete_env(var)
      Testor.Aws.reset()
    end)

    me = self()
    %{out: fn line -> send(me, {:out, line}) end}
  end

  defp signed_run do
    id = record(%{})
    log(id, " ✓ tests/a.test.ts (1 test) 1ms\n")
    shots = Path.join(Config.shots_dir(), id)
    File.mkdir_p!(shots)
    File.write!(Path.join(shots, "a.png"), "png")
    finish(id)
    wait_until(fn -> Attestation.exists?(id) end)
    on_exit(fn -> Store.delete(id) end)
    id
  end

  defp puts_of(key), do: Enum.count(FakeS3.requests(), &match?({"PUT", "/runs/" <> ^key, _, _}, &1))

  test "a home moves into the bucket once, is checked there, and comes back", %{out: out, tmp_dir: tmp} do
    id = signed_run()
    running = record(%{})
    on_exit(fn -> Store.settle(running, "cancelled") end)
    # An object already there at the same size (a bucket that keeps no checksum) is kept.
    FakeS3.put_object("screenshots/#{id}/a.png", "png")
    Audit.record("storage-cli-test", %{})
    Audit.flush()

    assert {:ok, %{runs: 1, kept: 1}} = CLI.migrate(only: [id], out: out)
    assert_received {:out, "1 runs stored" <> _}
    keys = FakeS3.keys()

    for key <- ["runs/#{id}.json", "logs/#{id}.log", "attestations/#{id}.dsse.json"],
        do: assert(key in keys, key)

    refute "runs/#{running}.json" in keys
    assert Enum.any?(keys, &String.starts_with?(&1, "audit/#{Testor.Cluster.instance()}/"))
    assert JSON.decode!(FakeS3.object("runs/#{id}.json").data)["stored"] == true
    assert Store.refresh(id)["stored"] == true

    # Again: what the bucket holds with the same checksum is not sent twice.
    assert {:ok, %{runs: 1}} = CLI.migrate(only: [id], out: out)
    assert puts_of("logs/#{id}.log") == 1

    assert {:ok, %{runs: 1, objects: objects, unsigned: 0}} = CLI.verify(only: [id], out: out)
    assert objects >= 2

    assert {:ok, 1} = CLI.export(tmp, only: [id], out: out)
    assert File.read!(Path.join([tmp, "logs", "#{id}.log"])) =~ "tests/a.test.ts"
    assert File.exists?(Path.join([tmp, "runs", "#{id}.json"]))
    # Again: what is there already is left alone.
    assert {:ok, 1} = CLI.export(tmp, only: [id], out: out)
  end

  test "verify names what changed, went missing or is not signed by this testor", %{out: out} do
    id = signed_run()
    {:ok, _} = CLI.migrate(only: [id], out: out)

    FakeS3.put_object("logs/#{id}.log", "changed\n")
    assert {:error, [{^id, "logs/" <> changed}]} = CLI.verify(only: [id], out: out)
    assert changed =~ "has changed"
    assert_received {:out, "0 runs verified" <> _}

    FakeS3.put_object("logs/#{id}.log", File.read!(Config.log_file(id)))

    Agent.update(
      Testor.Test.FakeS3.State,
      &update_in(&1.objects, fn o -> Map.delete(o, "screenshots/#{id}/a.png") end)
    )

    assert {:error, [{^id, "screenshots/" <> missing}]} = CLI.verify(only: [id], out: out)
    assert missing =~ "is missing"

    envelope = JSON.decode!(FakeS3.object("attestations/#{id}.dsse.json").data)

    forged =
      put_in(envelope, ["signatures", Access.at(0), "sig"], Base.encode64(:crypto.strong_rand_bytes(64)))

    FakeS3.put_object("attestations/#{id}.dsse.json", JSON.encode!(forged))
    assert {:error, [{^id, "its attestation's signature" <> _}]} = CLI.verify(only: [id], out: out)

    FakeS3.put_object("attestations/#{id}.dsse.json", "not json")
    assert {:error, [{^id, "its attestation cannot be read"}]} = CLI.verify(only: [id], out: out)

    Agent.update(
      Testor.Test.FakeS3.State,
      &update_in(&1.objects, fn o -> Map.delete(o, "attestations/#{id}.dsse.json") end)
    )

    assert {:ok, %{unsigned: 1}} = CLI.verify(only: [id], out: out)
  end

  test "config.json from TESTOR_CONFIG_FILE (a ConfigMap), not the home's", %{tmp_dir: tmp} do
    path = Path.join(tmp, "config.json")
    File.write!(path, JSON.encode!(%{"runs" => %{"maxRuns" => 7}}))
    Application.put_env(:testor, :config_file, path)
    on_exit(fn -> Application.delete_env(:testor, :config_file) end)
    assert Config.config_file() == path
    assert Config.retention()["runs"]["maxRuns"] == 7
  end

  test "failures: named, and the run sent again next time", %{out: out, tmp_dir: tmp} do
    id = signed_run()
    Audit.record("storage-cli-test", %{})
    Audit.flush()
    FakeS3.fail(true)
    assert {:error, "1 runs and " <> missed} = CLI.migrate(only: [id], out: out)
    refute missed =~ "and 0 audit files"
    assert_received {:out, line}
    assert line =~ id
    FakeS3.fail(false)

    {:ok, _} = CLI.migrate(only: [id], out: out)

    FakeS3.answer(fn method, key, _ ->
      if method == "GET" and key == "logs/#{id}.log", do: {500, "<Error><Code>InternalError</Code></Error>"}
    end)

    assert {:ok, 1} = CLI.export(tmp, only: [id], out: out)
    assert_received {:out, "logs/" <> why}
    assert why =~ "answered 500"
    FakeS3.answer(nil)

    File.rm!(Path.join(Config.data_dir(), "config.json"))
    assert {:error, ~s(config.json has no "storage" of type "s3")} = CLI.migrate()
    assert {:error, _} = CLI.verify()
    assert {:error, _} = CLI.export(tmp)
  end
end
