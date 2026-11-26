defmodule Testor.Attestation do
  @moduledoc """
  Signed attestations of finished runs: what this testor observed when a run ended, signed so
  that CI, release gates or auditors can rely on it later and notice any change to it.

  An attestation is an [in-toto Statement v1](https://github.com/in-toto/attestation) in a
  [DSSE envelope](https://github.com/secure-systems-lab/dsse), signed with Ed25519:

    * `subject`: the run's log, screenshots and artifacts, each with its SHA-256;
    * `predicate` (type `#{"https://github.com/izaccavalheiro/testor/blob/main/docs/attestation.md#run-v1"}`):
      the run's record (project, task, command, status, exit code, times, spec summary, who
      started it), this runner, and when it was signed.

  The key is `signing.key` in the secrets folder (`TESTOR_SECRETS_DIR`, else the data folder):
  the 32-byte Ed25519 seed in base64, created on first use, readable by its owner only.
  `GET /api/v1/attestation/key` gives the public key (PEM) and its id (SHA-256 of it).

  What a signature proves: that this testor saw these results and files when the run ended,
  and that nothing changed since. The record itself is written by the run's wrapper, in the
  account the tests run as; it is only as trustworthy as that account is separate from the one
  testor runs as (docs/security.md).
  """
  require Logger
  alias Testor.{Config, Files, Store}

  @payload_type "application/vnd.in-toto+json"
  @statement_type "https://in-toto.io/Statement/v1"
  @predicate_type "https://github.com/izaccavalheiro/testor/blob/main/docs/attestation.md#run-v1"
  # DER of an Ed25519 SubjectPublicKeyInfo, before the 32 key bytes (RFC 8410).
  @spki_prefix <<0x30, 0x2A, 0x30, 0x05, 0x06, 0x03, 0x2B, 0x65, 0x70, 0x03, 0x21, 0x00>>
  @record ~w(id project kind command status exitCode error warning startedAt endedAt durationMs summary actor source job screenshots artifacts reports mutation coverage specsFrom reason)

  def predicate_type, do: @predicate_type
  def key_file, do: Path.join(Config.secrets_dir(), "signing.key")
  def file(id), do: Path.join(Config.attestations_dir(), id <> ".dsse.json")
  def exists?(id), do: File.regular?(file(id))

  # --- keys ----------------------------------------------------------------------------------

  @doc "`{public, seed}` of the signing key, created on first use. Raises when it is not valid."
  def keypair do
    path = key_file()
    if not File.exists?(path), do: create_key(path)

    with {:ok, text} <- File.read(path),
         {:ok, seed} when byte_size(seed) == 32 <- Base.decode64(String.trim(text)) do
      {public, _} = :crypto.generate_key(:eddsa, :ed25519, seed)
      {public, seed}
    else
      _ -> raise "#{path} is not a base64 Ed25519 seed of 32 bytes"
    end
  end

  # Exclusive: two runs ending at once both read the key that was written first.
  defp create_key(path) do
    File.mkdir_p!(Path.dirname(path))

    with :ok <- File.write(path, Base.encode64(:crypto.strong_rand_bytes(32)), [:exclusive]) do
      File.chmod(path, 0o600)
    end
  end

  @doc "The public key as PEM (SubjectPublicKeyInfo) and its id, the SHA-256 of its DER."
  def public_key do
    {public, _} = keypair()
    der = @spki_prefix <> public

    %{
      "algorithm" => "ed25519",
      "keyid" => keyid(public),
      "publicKey" => "-----BEGIN PUBLIC KEY-----\n" <> Base.encode64(der) <> "\n-----END PUBLIC KEY-----\n"
    }
  end

  defp keyid(public), do: :crypto.hash(:sha256, @spki_prefix <> public) |> Base.encode16(case: :lower)

  @doc "The 32 bytes of a public key in PEM, as `public_key/0` gives it."
  def decode_pem(pem) do
    with [_, body] <- Regex.run(~r/-----BEGIN PUBLIC KEY-----\s*([A-Za-z0-9+\/=\s]+?)\s*-----END/, pem),
         {:ok, @spki_prefix <> <<public::binary-size(32)>>} <- Base.decode64(String.replace(body, ~r/\s/, "")) do
      {:ok, public}
    else
      _ -> :error
    end
  end

  # --- signing -------------------------------------------------------------------------------

  @doc "Attests run `id` in the background: hashing a run's artifacts can take a while."
  def attest_later(id) do
    # Then copied to object storage, signed, when an archive is set up (Testor.Archive).
    Task.Supervisor.start_child(Testor.TaskSupervisor, fn ->
      safe_attest(id)
      Testor.Archive.maybe(id)
    end)
  end

  @doc "`attest/1`, logging why it failed instead of raising."
  def safe_attest(id) do
    attest(id)
  rescue
    error ->
      Logger.error("attestation: #{id}: #{Exception.message(error)}")
      :error
  end

  @doc "Signs what is known of finished run `id` now and saves it. `{:ok, envelope}`, or `:error` for a run that is unknown or still running."
  def attest(id) do
    case Store.get(id) do
      %{"status" => status} = run when status != "running" ->
        envelope = run |> statement() |> sign()
        File.mkdir_p!(Config.attestations_dir())
        Files.write_json(file(id), envelope)
        {:ok, envelope}

      _ ->
        :error
    end
  end

  @doc "The in-toto statement of a finished run: its files as subjects, its record as predicate."
  def statement(run) do
    id = run["id"]

    files =
      [{"log", Config.log_file(id)}] ++
        files_under("screenshots", Path.join(Config.shots_dir(), id)) ++
        files_under("artifacts", Path.join(Config.artifacts_dir(), id)) ++
        files_under("reports", Testor.Reports.dir(id))

    %{
      "_type" => @statement_type,
      "subject" =>
        for {name, path} <- files, Files.entry(path) != :skip do
          %{"name" => name, "digest" => %{"sha256" => sha256_file(path)}}
        end,
      "predicateType" => @predicate_type,
      "predicate" => %{
        "run" => Map.take(run, @record),
        "runner" => %{
          "host" => hd(Testor.Net.machine_names()),
          "os" => to_string(Testor.OS.family()),
          "testor" => to_string(Application.spec(:testor, :vsn))
        },
        "signedAt" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      }
    }
  end

  defp files_under(area, dir) do
    for file <- Files.walk(dir), do: {area <> "/" <> String.replace(file.rel, "\\", "/"), file.full}
  end

  defp sha256_file(path) do
    path
    |> File.stream!(65_536)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  @doc "A DSSE envelope of `statement`, signed with the signing key."
  def sign(statement) do
    {public, seed} = keypair()
    payload = JSON.encode!(statement)
    signature = :crypto.sign(:eddsa, :none, pae(payload), [seed, :ed25519])

    %{
      "payloadType" => @payload_type,
      "payload" => Base.encode64(payload),
      "signatures" => [%{"keyid" => keyid(public), "sig" => Base.encode64(signature)}]
    }
  end

  @doc "The statement in `envelope` when one of its signatures is `public`'s; else `{:error, reason}`."
  def verify(
        %{"payloadType" => @payload_type, "payload" => payload, "signatures" => [_ | _] = signatures},
        public
      ) do
    with {:ok, payload} <- Base.decode64(payload),
         true <- Enum.any?(signatures, &signed?(&1, payload, public)) || {:error, :signature},
         {:ok, %{"_type" => @statement_type} = statement} <- JSON.decode(payload) do
      {:ok, statement}
    else
      {:error, :signature} -> {:error, :signature}
      _ -> {:error, :malformed}
    end
  end

  def verify(_envelope, _public), do: {:error, :malformed}

  defp signed?(%{"sig" => sig}, payload, public) when is_binary(sig) do
    case Base.decode64(sig) do
      {:ok, sig} -> :crypto.verify(:eddsa, :none, pae(payload), sig, [public, :ed25519])
      :error -> false
    end
  end

  defp signed?(_signature, _payload, _public), do: false

  # DSSE's pre-authentication encoding: what is signed is the type and the payload, with lengths.
  defp pae(payload),
    do: "DSSEv1 #{byte_size(@payload_type)} #{@payload_type} #{byte_size(payload)} " <> payload
end
