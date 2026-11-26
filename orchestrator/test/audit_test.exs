defmodule Testor.AuditTest do
  @moduledoc "The audit trail: chained, signed, verifiable; tampering, rotation, restarts."
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  import Testor.Test.Helpers
  alias Testor.{Attestation, Audit, Config}

  @genesis String.duplicate("0", 64)

  # A fresh trail: no file, and the chain starting over.
  setup do
    Audit.flush()
    File.rm(Audit.file())
    :sys.replace_state(Audit, fn _ -> %{prev: @genesis} end)
    {public, _} = Attestation.keypair()

    on_exit(fn ->
      Audit.flush()
      File.rm(Audit.file())
      :sys.replace_state(Audit, fn _ -> %{prev: @genesis} end)
    end)

    %{public: public}
  end

  defp lines, do: Audit.file() |> File.read!() |> String.split("\n", trim: true)
  defp rewrite(lines), do: File.write!(Audit.file(), Enum.map_join(lines, "", &(&1 <> "\n")))

  test "state-changing requests and failed sign-ins are recorded, chained and signed", %{public: public} do
    assert %{status: 200} = http(:post, "/api/cleanup", headers: [{"x-testor", "1"}], body: "")
    Audit.record("auth_failed", %{"from" => "10.0.0.9", "why" => "test"})

    assert [
             %{
               "event" => "request",
               "method" => "POST",
               "path" => "/api/cleanup",
               "status" => 200,
               "prev" => @genesis
             } = first,
             %{"event" => "auth_failed", "prev" => prev}
           ] = Audit.tail(10)

    assert is_binary(first["requestId"]) and is_binary(first["sig"])
    assert prev == :crypto.hash(:sha256, hd(lines())) |> Base.encode16(case: :lower)
    assert Audit.verify(public) == {:ok, 2}
  end

  test "an edited, removed or garbled entry breaks the trail at that line", %{public: public} do
    for n <- 1..3, do: Audit.record("auth_failed", %{"from" => "10.0.0.#{n}", "why" => "test"})
    Audit.flush()
    [one, two, three] = lines()

    rewrite([one, String.replace(two, "10.0.0.2", "10.0.0.66"), three])
    assert Audit.verify(public) == {:error, 2, :signature}

    rewrite([one, three])
    assert Audit.verify(public) == {:error, 2, :chain}

    rewrite([one, "not json", three])
    assert Audit.verify(public) == {:error, 2, :malformed}

    unsigned = two |> JSON.decode!() |> Map.delete("sig") |> JSON.encode!()
    rewrite([one, unsigned, three])
    assert Audit.verify(public) == {:error, 2, :malformed}

    bad_sig = two |> JSON.decode!() |> Map.put("sig", "%%%") |> JSON.encode!()
    rewrite([one, bad_sig, three])
    assert Audit.verify(public) == {:error, 2, :malformed}

    {other, _} = :crypto.generate_key(:eddsa, :ed25519)
    rewrite([one, two, three])
    assert Audit.verify(other) == {:error, 1, :signature}
    assert Audit.verify(public) == {:ok, 3}
  end

  test "a full file is rotated and the chain goes on; a restart continues it", %{public: public} do
    Application.put_env(:testor, :audit_max_bytes, 1)
    on_exit(fn -> Application.delete_env(:testor, :audit_max_bytes) end)

    Audit.record("auth_failed", %{"why" => "one"})
    Audit.record("auth_failed", %{"why" => "two"})
    Audit.flush()

    current = Path.basename(Audit.file())
    prefix = String.replace_suffix(current, ".jsonl", "-")
    [name] = Config.data_dir() |> File.ls!() |> Enum.filter(&String.starts_with?(&1, prefix))
    rotated = Path.join(Config.data_dir(), name)
    on_exit(fn -> File.rm(rotated) end)
    [old] = rotated |> File.read!() |> String.split("\n", trim: true)
    assert Audit.verify(rotated, public) == {:ok, 1}

    assert Audit.verify(Audit.file(), public, :crypto.hash(:sha256, old) |> Base.encode16(case: :lower)) ==
             {:ok, 1}

    # After a restart the chain starts from the file's last line; an empty or missing file starts over.
    assert {:ok, %{prev: prev}} = Audit.init(nil)
    assert prev == :crypto.hash(:sha256, hd(lines())) |> Base.encode16(case: :lower)
    File.write!(Audit.file(), "")
    assert {:ok, %{prev: @genesis}} = Audit.init(nil)
    File.rm(Audit.file())
    assert {:ok, %{prev: @genesis}} = Audit.init(nil)
    assert Audit.verify(public) == {:ok, 0}
    assert Audit.tail(5) == []
  end

  test "an entry that cannot be signed is logged, not lost silently" do
    File.write!(Attestation.key_file(), "not a key")
    on_exit(fn -> File.rm(Attestation.key_file()) end)

    log =
      capture_log(fn ->
        Audit.record("auth_failed", %{"why" => "x"})
        Audit.flush()
      end)

    assert log =~ "audit: could not record auth_failed"
  end

  test "GET /api/v1/audit gives the last entries and whether the chain holds", %{public: _} do
    Audit.record("auth_failed", %{"why" => "api"})

    assert %{"entries" => [_], "verified" => %{"ok" => true, "entries" => 1}} =
             http(:get, "/api/v1/audit?limit=5") |> json()

    rewrite(["garbage"])

    assert %{
             "entries" => [%{"malformed" => "garbage"}],
             "verified" => %{"ok" => false, "line" => 1, "reason" => "malformed"}
           } = http(:get, "/api/v1/audit") |> json()
  end
end
