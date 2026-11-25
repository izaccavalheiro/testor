defmodule Testor.AttestationTest do
  @moduledoc "Signed attestations of finished runs: signing, verifying, tampering, keys and the API."
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  import Testor.Test.Helpers
  alias Testor.{Attestation, Config, Store}

  setup do
    on_exit(fn -> File.rm(Attestation.key_file()) end)
  end

  defp finished(extra \\ %{}) do
    id = record(%{"project" => "attest"})
    log(id, " ✓ tests/a.test.ts (2 tests) 5ms\n")
    shot = Path.join([Config.shots_dir(), id, "a.png"])
    File.mkdir_p!(Path.dirname(shot))
    File.write!(shot, "png")

    finish(
      id,
      "passed",
      Map.merge(%{"actor" => %{"user" => "ci", "client" => "100.64.0.9", "declared" => "ada@laptop"}}, extra)
    )

    id
  end

  test "a finished run is signed by itself, and the statement says what was observed" do
    id = finished()
    wait_until(fn -> Attestation.exists?(id) end)

    {:ok, envelope} = Testor.Files.read_json(Attestation.file(id))
    {public, _} = Attestation.keypair()
    assert {:ok, statement} = Attestation.verify(envelope, public)

    assert %{
             "_type" => "https://in-toto.io/Statement/v1",
             "predicateType" => type,
             "predicate" => %{"run" => run, "runner" => %{"testor" => _, "os" => _}, "signedAt" => _}
           } = statement

    assert type == Attestation.predicate_type()

    assert %{"id" => ^id, "status" => "passed", "exitCode" => 0, "actor" => %{"declared" => "ada@laptop"}} =
             run

    assert %{"specs" => 1} = run["summary"]

    names = Enum.map(statement["subject"], & &1["name"])
    assert names == ["log", "screenshots/a.png"]
    png = Enum.find(statement["subject"], &(&1["name"] == "screenshots/a.png"))
    assert png["digest"]["sha256"] == :crypto.hash(:sha256, "png") |> Base.encode16(case: :lower)
  end

  test "a run that started and ended between two scans is signed too" do
    id = run_id()
    File.mkdir_p!(Config.runs_dir())

    Testor.Files.write_json(Config.run_file(id), %{
      "id" => id,
      "project" => "attest-quick",
      "kind" => "test",
      "status" => "passed",
      "exitCode" => 0,
      "startedAt" => DateTime.utc_now() |> DateTime.to_iso8601()
    })

    wait_until(fn -> Attestation.exists?(id) end)
  end

  test "changing the payload or using another key fails verification" do
    id = finished()
    {:ok, envelope} = Attestation.attest(id)
    {public, _} = Attestation.keypair()

    statement = envelope["payload"] |> Base.decode64!() |> JSON.decode!()

    forged =
      put_in(statement, ["predicate", "run", "status"], "passed")
      |> put_in(["predicate", "run", "exitCode"], 1)

    tampered = %{envelope | "payload" => Base.encode64(JSON.encode!(forged))}
    assert Attestation.verify(tampered, public) == {:error, :signature}

    {other, _} = :crypto.generate_key(:eddsa, :ed25519)
    assert Attestation.verify(envelope, other) == {:error, :signature}
  end

  test "envelopes that are not valid" do
    {public, _} = Attestation.keypair()
    good = Attestation.sign(%{"_type" => "https://in-toto.io/Statement/v1"})
    assert {:ok, _} = Attestation.verify(good, public)

    assert Attestation.verify(%{}, public) == {:error, :malformed}
    assert Attestation.verify(%{good | "payload" => "%%%"}, public) == {:error, :malformed}

    assert Attestation.verify(%{good | "signatures" => [%{"sig" => "%%%"}, %{}]}, public) ==
             {:error, :signature}

    not_statement = Attestation.sign(%{"_type" => "something else"})
    assert Attestation.verify(not_statement, public) == {:error, :malformed}
  end

  test "a running or unknown run is not attested; a bad key is logged, not raised" do
    running = record(%{"project" => "attest-running"})
    assert Attestation.attest(running) == :error
    assert Attestation.attest("nope") == :error

    id = finished()
    wait_until(fn -> Attestation.exists?(id) end)
    File.write!(Attestation.key_file(), "not a key")
    log = capture_log(fn -> assert Attestation.safe_attest(id) == :error end)
    assert log =~ "not a base64 Ed25519 seed"
    Store.cancel(running)
  end

  test "the public key in PEM round-trips, and its id is the SHA-256 of its DER" do
    {public, _} = Attestation.keypair()
    %{"publicKey" => pem, "keyid" => keyid, "algorithm" => "ed25519"} = Attestation.public_key()
    assert Attestation.decode_pem(pem) == {:ok, public}
    assert Attestation.decode_pem("nope") == :error
    assert byte_size(keyid) == 64

    if not Testor.OS.windows?() do
      assert %{mode: mode} = File.stat!(Attestation.key_file())
      assert Bitwise.band(mode, 0o077) == 0
    end
  end

  test "the API serves the attestation and the key; deleting the run deletes its attestation" do
    id = finished()
    wait_until(fn -> Attestation.exists?(id) end)

    assert %{status: 200} = response = http(:get, "/api/v1/runs/#{id}/attestation")
    assert %{"payloadType" => "application/vnd.in-toto+json"} = json(response)
    assert %{"run" => %{"attested" => true}} = http(:get, "/api/v1/runs/#{id}") |> json()
    assert %{status: 404} = http(:get, "/api/v1/runs/nope/attestation")
    assert %{"algorithm" => "ed25519"} = http(:get, "/api/v1/attestation/key") |> json()

    assert :ok = Store.delete(id)
    refute Attestation.exists?(id)
  end
end
