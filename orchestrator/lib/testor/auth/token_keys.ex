defmodule Testor.Auth.TokenKeys do
  @moduledoc """
  The Ed25519 keys testor signs its tokens with (`EdDSA`, RFC 8037), published as a JSON Web
  Key Set (RFC 7517) at `/.well-known/jwks.json`: a hub, a gateway or any service verifies a
  testor token with the public keys, without holding a secret that could also mint one.

  `token-keys.json` in the secrets folder, created on first use, readable by its owner only:

      {"keys": [{"seed": "<base64, 32 bytes>", "created": 1764000000},
                {"seed": "...", "created": 1763000000, "retired": 1764000000}]}

  The first key signs. A retired key (`Testor.Auth.CLI.roll_token_key/0`) still verifies the
  tokens it signed before it was retired, so they live out their time, and is dropped once
  they have all expired; a token it signed later is refused. A key's id (`kid`) is its JWK
  thumbprint (RFC 7638).

  `TESTOR_TOKEN_KEY` (a base64 seed of 32 bytes) replaces the file, for replicas that share one
  key from a secret store.
  """
  require Logger
  alias Testor.Config

  @env "TESTOR_TOKEN_KEY"

  def file, do: Path.join(Config.secrets_dir(), "token-keys.json")
  def env, do: @env

  @doc """
  The key ring: `%{signing: %{kid, seed}, verify: %{kid => %{public, retired}}}`. Creates the
  file on first use; raises when it, or `TESTOR_TOKEN_KEY`, cannot be read.
  """
  def load! do
    case System.get_env(@env) do
      nil -> from_entries(read_entries!())
      "" -> from_entries(read_entries!())
      seed -> from_entries([%{"seed" => seed}], @env)
    end
  end

  @doc "A ring of `seeds` (raw 32 bytes), the first signing; none retired. For tests."
  def from_seeds([_ | _] = seeds),
    do: from_entries(Enum.map(seeds, &%{"seed" => Base.encode64(&1)}))

  defp from_entries(entries, where \\ nil) do
    keys =
      for entry <- entries do
        seed = seed!(entry["seed"], where || file())
        {public, _} = :crypto.generate_key(:eddsa, :ed25519, seed)
        retired = if is_integer(entry["retired"]), do: entry["retired"]
        %{kid: kid(public), seed: seed, public: public, retired: retired}
      end

    [signing | _] = keys

    %{
      signing: Map.take(signing, [:kid, :seed]),
      verify: Map.new(keys, &{&1.kid, %{public: &1.public, retired: &1.retired}})
    }
  end

  defp seed!(text, where) do
    case is_binary(text) && Base.decode64(String.trim(text)) do
      {:ok, seed} when byte_size(seed) == 32 -> seed
      _ -> raise "#{where} holds a key that is not a base64 Ed25519 seed of 32 bytes"
    end
  end

  defp read_entries! do
    path = file()
    if not File.exists?(path), do: create(path)

    with {:ok, text} <- File.read(path),
         {:ok, %{"keys" => [_ | _] = entries}} <- JSON.decode(Config.strip_bom(text)),
         true <- Enum.all?(entries, &is_map/1) do
      entries
    else
      {:error, reason} when is_atom(reason) -> raise "cannot read #{path}: #{:file.format_error(reason)}"
      _ -> raise "#{path} is not a key list"
    end
  end

  # Exclusive: when two requests create it at once, both read the one that was written first.
  defp create(path) do
    File.mkdir_p!(Path.dirname(path))

    with :ok <- File.write(path, encode([entry(now())]), [:exclusive]) do
      _ = File.chmod(path, 0o600)
      Logger.info("auth: created #{path}")
    end
  end

  @doc """
  Puts a new signing key first and retires the others; drops those retired more than
  `max_ttl` seconds ago, whose tokens have all expired. Returns the new key's id.
  """
  def roll!(max_ttl) do
    now = now()

    kept =
      for entry <- read_entries!(),
          retired = entry["retired"] || now,
          retired + max_ttl > now,
          do: Map.put(entry, "retired", retired)

    write!([entry(now) | kept])
  end

  @doc "Replaces every key with a new one: tokens they signed stop working. Returns its id."
  def reset!, do: write!([entry(now())])

  defp write!(entries) do
    path = file()
    File.mkdir_p!(Path.dirname(path))
    tmp = path <> ".tmp"
    File.write!(tmp, encode(entries))
    _ = File.chmod(tmp, 0o600)
    File.rename!(tmp, path)
    from_entries(entries).signing.kid
  end

  defp entry(now), do: %{"seed" => Base.encode64(:crypto.strong_rand_bytes(32)), "created" => now}
  defp encode(entries), do: JSON.encode!(%{"keys" => entries})
  defp now, do: System.system_time(:second)

  @doc "The public keys as a JSON Web Key Set."
  def jwks(nil), do: %{"keys" => []}

  def jwks(%{verify: verify, signing: %{kid: signing}}) do
    keys =
      verify
      # The signing key first, as verifiers that take the first key expect.
      |> Enum.sort_by(fn {kid, _} -> kid != signing end)
      |> Enum.map(fn {kid, %{public: public}} ->
        jwk(public) |> Map.merge(%{"kid" => kid, "alg" => "EdDSA", "use" => "sig"})
      end)

    %{"keys" => keys}
  end

  defp jwk(public), do: %{"kty" => "OKP", "crv" => "Ed25519", "x" => b64(public)}

  @doc "A key's id: its JWK thumbprint (RFC 7638), the SHA-256 of its members in order."
  def kid(public) do
    canonical = ~s({"crv":"Ed25519","kty":"OKP","x":"#{b64(public)}"})
    :crypto.hash(:sha256, canonical) |> b64()
  end

  defp b64(bytes), do: Base.url_encode64(bytes, padding: false)
end
