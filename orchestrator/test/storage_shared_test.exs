defmodule Testor.StorageSharedTest do
  @moduledoc """
  Testors that share no volume (Testor.Storage.Shared): the run index in PostgreSQL, live log
  segments, and what another testor sends over NOTIFY (simulated: a notification from an
  instance of another name).
  """
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  import Testor.Test.Helpers
  alias Testor.{Cluster, Config, Events, Storage, Store}
  alias Testor.Storage.Shared
  alias Testor.Test.FakeS3

  @moduletag :postgres
  @pool Testor.Jobs.Postgres

  setup do
    FakeS3.reset()
    System.put_env("AWS_ACCESS_KEY_ID", "AKIDTEST")
    System.put_env("AWS_SECRET_ACCESS_KEY", "secret")

    raw = %{
      "type" => "s3",
      "bucket" => "runs",
      "region" => "us-east-1",
      "endpoint" => FakeS3.endpoint(),
      "pathStyle" => true
    }

    {:ok, s3} = Testor.Blob.S3.config(raw)
    Storage.configure(Map.merge(s3, %{type: :s3, presign: true, cache_bytes: 1_000_000_000}))
    start_supervised!(Shared)
    Shared.clear()

    on_exit(fn ->
      Storage.configure(%{type: :files})
      for var <- ~w(AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY), do: System.delete_env(var)
      Testor.Aws.reset()
    end)

    :ok
  end

  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp from_other(message) do
    send(
      Shared,
      {:notification, self(), make_ref(), "testor_relay", JSON.encode!(Map.put(message, "o", "testor-b"))}
    )

    :sys.get_state(Shared)
  end

  defp remote_run(id, extra \\ %{}) do
    Map.merge(
      %{
        "id" => id,
        "project" => "far",
        "kind" => "test",
        "status" => "running",
        "startedAt" => now(),
        "remote" => "pod-1",
        "origin" => "testor-b"
      },
      extra
    )
  end

  test "a local run is in the index while it runs and once stored; its log goes on in segments" do
    id = record(%{})
    on_exit(fn -> Store.delete(id) end)
    assert %{"status" => "running", "origin" => origin} = wait_until(fn -> Shared.get(id) end)
    assert origin == Cluster.instance()

    log(id, "hello from here\n")
    finish(id)
    stored = wait_until(fn -> match?(%{"stored" => true}, Shared.get(id)) && Shared.get(id) end)
    assert stored["status"] == "passed"
    assert "logs/#{id}.log" in FakeS3.keys()
    wait_until(fn -> not Enum.any?(FakeS3.keys(), &String.starts_with?(&1, "logs/#{id}/")) end)

    # Deleted: from the index and the bucket.
    :ok = Store.delete(id)
    assert Shared.get(id) == nil
    refute Enum.any?(FakeS3.keys(), &String.contains?(&1, id))
  end

  test "another testor's runs, log segments and events arrive over NOTIFY" do
    id = run_id()
    {:ok, version} = Shared.put(remote_run(id))
    from_other(%{"k" => "run", "id" => id, "v" => version})
    wait_until(fn -> Store.get(id) end)

    # A segment inline; one beyond what this testor has, the ones before it fetched first.
    from_other(%{"k" => "chunk", "id" => id, "at" => 0, "n" => 4, "d" => Base.encode64("one\n")})
    wait_until(fn -> File.read(Config.log_file(id)) == {:ok, "one\n"} end)
    FakeS3.put_object(Shared.segment_key(id, 4), "two\n")
    FakeS3.put_object(Shared.segment_key(id, 8), "three\n")
    from_other(%{"k" => "chunk", "id" => id, "at" => 8, "n" => 6, "d" => Base.encode64("three\n")})
    assert File.read!(Config.log_file(id)) == "one\ntwo\nthree\n"
    # Too large to be inline: read from the bucket. One already here: left out.
    from_other(%{"k" => "chunk", "id" => id, "at" => 14, "n" => 9000, "d" => nil})
    from_other(%{"k" => "chunk", "id" => id, "at" => 0, "n" => 4, "d" => Base.encode64("one\n")})
    assert File.read!(Config.log_file(id)) == "one\ntwo\nthree\n"

    # The dashboard's events.
    Events.subscribe("global")
    from_other(%{"k" => "event", "t" => "global", "e" => "job", "d" => %{"id" => "j1"}})
    assert_receive {:event, "job", %{"id" => "j1"}}
    # A large one is not sent at all; a small one is.
    Events.broadcast("global", "job", %{"id" => "j2", "big" => String.duplicate("x", 9000)})
    Events.broadcast("global", "approval", %{"id" => "a1"})

    # Its own notifications, garbage and kinds it does not know are left alone.
    send(
      Shared,
      {:notification, self(), make_ref(), "testor_relay",
       JSON.encode!(%{"k" => "removed", "id" => id, "o" => Cluster.instance()})}
    )

    send(Shared, {:notification, self(), make_ref(), "testor_relay", "not json"})
    from_other(%{"k" => "mystery"})
    assert Store.get(id)

    from_other(%{"k" => "removed", "id" => id})
    wait_until(fn -> Store.get(id) == nil end)
    Shared.delete(id)
  end

  test "an agent's chunks: a segment each, the size moved only from where the log ends" do
    id = run_id()
    {:ok, _} = Shared.put(remote_run(id))
    assert {:ok, 6} = Shared.append(id, 0, "hello\n", 1000)
    assert Shared.segment_key(id, 0) in FakeS3.keys()
    assert File.read!(Config.log_file(id)) == "hello\n"

    assert {:error, {:offset, 6}} = Shared.append(id, 0, "again", 1000)
    assert {:error, :too_large} = Shared.append(id, 6, "xxxxx", 8)
    assert {:error, :no_run} = Shared.append("20990101-000000-abcdef", 0, "x", 10)

    # Another testor moved it on while this segment was sent: that one won.
    # Too large to go inline with its notification.
    big = String.duplicate("y", 6000)
    assert {:ok, 6006} = Shared.append(id, 6, big, 10_000)
    Postgrex.query!(@pool, "UPDATE testor_runs SET log_size = 6 WHERE id = $1", [id])

    FakeS3.answer(fn
      "PUT", _, _ ->
        Postgrex.query!(@pool, "UPDATE testor_runs SET log_size = 99 WHERE id = $1", [id])
        nil

      _, _, _ ->
        nil
    end)

    assert {:error, {:offset, 99}} = Shared.append(id, 6, "late\n", 1000)
    FakeS3.answer(nil)
    FakeS3.fail(true)
    Postgrex.query!(@pool, "UPDATE testor_runs SET log_size = 6 WHERE id = $1", [id])
    assert {:error, "answered 500" <> _} = Shared.append(id, 6, "x", 1000)
    Shared.delete(id)
  end

  test "a finished run is never made running again; missed changes come with the resync" do
    id = run_id()
    {:ok, _} = Shared.put(remote_run(id, %{"status" => "passed", "summary" => %{}}))
    assert :final = Shared.put(remote_run(id))
    assert Shared.put_version(%{"x" => 1}, remote_run(id)) == %{"x" => 1}
    assert [%{"id" => ^id}] = Enum.filter(Shared.all(), &(&1["id"] == id))

    send(Shared, :resync)
    wait_until(fn -> Store.get(id) end)

    # The index out of reach: logged, tried again next time.
    Postgrex.query!(@pool, "ALTER TABLE testor_runs RENAME TO testor_runs_away", [])

    log =
      capture_log(fn ->
        send(Shared, :resync)
        :sys.get_state(Shared)
      end)

    Postgrex.query!(@pool, "ALTER TABLE testor_runs_away RENAME TO testor_runs", [])
    assert log =~ "cannot be read"

    # Loaded with the store's start.
    :ets.delete(:testor_runs, id)
    :ok = Supervisor.terminate_child(Testor.Supervisor, Store)
    {:ok, _} = Supervisor.restart_child(Testor.Supervisor, Store)
    assert Store.get(id)["status"] == "passed"
    Shared.delete(id)
    Store.unindexed(id)
  end

  test "agents' keys are pinned in PostgreSQL: one testor's pin holds on every other" do
    key = fn ->
      curve = {1, 2, 840, 10045, 3, 1, 7}
      private = :public_key.generate_key({:namedCurve, curve})

      spki =
        :public_key.pem_entry_encode(
          :SubjectPublicKeyInfo,
          {{:ECPoint, elem(private, 4)}, {:namedCurve, curve}}
        )

      :public_key.pem_encode([spki])
    end

    agent = "pod-#{System.unique_integer([:positive])}"
    {pem, other} = {key.(), key.()}
    assert :ok = Testor.AgentKeys.pin(agent, pem)
    assert :ok = Testor.AgentKeys.pin(agent, pem)
    assert {:error, :mismatch} = Testor.AgentKeys.pin(agent, other)
    assert %{^agent => %{"publicKey" => ^pem}} = Testor.AgentKeys.all()
    assert Cluster.get("agent-key", agent)["agent"] == agent
    refute Map.has_key?(Testor.AgentKeys.Local.all(), agent)
    assert Testor.AgentKeys.forget(agent)
    refute Testor.AgentKeys.forget(agent)
    assert :ok = Testor.AgentKeys.pin(agent, other)
    Testor.AgentKeys.forget(agent)
  end

  test "a local run's log: a segment once enough has gathered; failures are logged" do
    id = run_id()
    {:ok, _} = Shared.put(remote_run(id, %{"remote" => nil, "origin" => Cluster.instance()}))
    File.mkdir_p!(Config.logs_dir())
    File.write!(Config.log_file(id), "abc")

    Shared.follow(id, 3, false)
    :sys.get_state(Shared)
    refute Shared.segment_key(id, 0) in FakeS3.keys()
    Shared.follow(id, 3, true)
    :sys.get_state(Shared)
    assert FakeS3.object(Shared.segment_key(id, 0)).data == "abc"

    File.write!(Config.log_file(id), "def", [:append])
    FakeS3.fail(true)

    log =
      capture_log(fn ->
        Shared.follow(id, 6, true)
        :sys.get_state(Shared)
        Shared.catch_up(id)
        assert {:error, _} = Shared.compact(id)
      end)

    # The run ended with the flush before: its log is followed from the start again.
    assert log =~ "could not be sent from 0" and log =~ "cannot be listed"
    FakeS3.fail(false)

    # A segment the bucket will not hand back: the copy stops before it.
    other = run_id()
    FakeS3.put_object(Shared.segment_key(other, 0), "x")

    segment = Shared.segment_key(other, 0)

    FakeS3.answer(fn
      "GET", ^segment, _ -> {500, "<Error><Code>InternalError</Code></Error>"}
      _, _, _ -> nil
    end)

    Shared.catch_up(other)
    refute File.exists?(Config.log_file(other))
    FakeS3.answer(nil)
    # A segment after a gap: the copy waits for the ones before it.
    gap = run_id()
    FakeS3.put_object(Shared.segment_key(gap, 5), "later")
    Shared.catch_up(gap)
    refute File.exists?(Config.log_file(gap))
    assert :ok = Shared.compact(id)
    Shared.delete(id)
  end
end
