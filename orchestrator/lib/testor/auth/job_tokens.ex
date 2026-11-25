defmodule Testor.Auth.JobTokens do
  @moduledoc """
  Identity tokens for jobs (OpenID Connect ID tokens, as GitHub Actions gives its workflows):
  the agent holding a job asks for one (`POST /api/v1/agent/jobs/:id/token`), and the job trades
  it for short-lived cloud credentials (AWS `AssumeRoleWithWebIdentity`, Google workload
  identity federation, Azure federated credentials) or a Vault token (JWT auth), with no
  long-lived key on the runner. Those services trust testor as an identity provider: they
  fetch `<issuer>/.well-known/openid-configuration` and the keys it names.

  `auth.json`:

      "jobTokens": {
        "issuer": "https://testor.example.com",   (testor's root URL as those services reach it)
        "audiences": ["sts.amazonaws.com", "vault"],
        "ttlMinutes": 15                          (1 to 60)
      }

  A token's `sub` is `project:<project>:kind:<kind>`; it also holds `project`, `kind`, `ref`,
  `job_id`, `agent` and `requested_by`. Signed with RS256 (what every cloud's token service
  accepts) by a key of `job-token-keys.json` in the secrets folder, created on first use and
  published with the token keys at `/.well-known/jwks.json`.
  `Testor.Auth.CLI.roll_job_token_key/0` adds a key; the previous ones stay published an hour,
  the longest a token lives.
  """
  require Logger
  alias Testor.Config
  alias Testor.Auth.OIDC

  @max_ttl 3600

  def file, do: Path.join(Config.secrets_dir(), "job-token-keys.json")

  # --- configuration -------------------------------------------------------------------------

  @doc "The `jobTokens` section of `auth.json`, checked; nil when absent or not valid (logged)."
  def config(nil), do: nil

  def config(%{"issuer" => issuer, "audiences" => [_ | _] = audiences} = raw) do
    uri = if is_binary(issuer), do: URI.parse(issuer), else: %URI{}

    cond do
      not OIDC.secure_url?(issuer) or uri.query != nil or uri.fragment != nil ->
        invalid("issuer must be testor's https URL, with no query")

      not Enum.all?(audiences, &(is_binary(&1) and &1 != "")) ->
        invalid("audiences must be strings")

      true ->
        %{
          issuer: String.trim_trailing(issuer, "/"),
          audiences: audiences,
          ttl: ttl(raw["ttlMinutes"])
        }
    end
  end

  def config(_raw), do: invalid("it needs an issuer and a list of audiences")

  defp invalid(why) do
    Logger.warning("auth: jobTokens is not valid (#{why}): jobs get no identity tokens")
    nil
  end

  defp ttl(minutes) when is_number(minutes) and minutes >= 1, do: round(min(minutes * 60, @max_ttl))
  defp ttl(_), do: 900

  @doc "The OpenID Connect discovery document of testor as the issuer of job tokens."
  def discovery(%{issuer: issuer}) do
    %{
      "issuer" => issuer,
      "jwks_uri" => issuer <> "/.well-known/jwks.json",
      "response_types_supported" => ["id_token"],
      "subject_types_supported" => ["public"],
      "id_token_signing_alg_values_supported" => ["RS256"],
      "scopes_supported" => ["openid"],
      "claims_supported" => ~w(iss aud sub iat nbf exp jti project kind ref job_id agent requested_by)
    }
  end

  # --- tokens --------------------------------------------------------------------------------

  @doc """
  A token for `job`, held by `agent`, for `audience`: `{:ok, %{"token", "expires_in"}}`, or
  `{:error, :off | :audience}`.
  """
  def issue(settings, job, agent, audience, now \\ System.system_time(:second))

  def issue(%{job_tokens: %{} = config, job_token_keys: %{signing: signing}}, job, agent, audience, now) do
    if audience in config.audiences do
      claims =
        %{
          "iss" => config.issuer,
          "aud" => audience,
          "sub" => "project:#{job["project"]}:kind:#{job["kind"]}",
          "iat" => now,
          "nbf" => now,
          "exp" => now + config.ttl,
          "jti" => Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false),
          "project" => job["project"],
          "kind" => job["kind"],
          "job_id" => job["id"],
          "agent" => agent,
          "requested_by" => job["requestedBy"]
        }
        |> then(&if(is_binary(job["ref"]), do: Map.put(&1, "ref", job["ref"]), else: &1))

      {:ok, %{"token" => sign(claims, signing), "expires_in" => config.ttl}}
    else
      {:error, :audience}
    end
  end

  def issue(_settings, _job, _agent, _audience, _now), do: {:error, :off}

  defp sign(claims, %{kid: kid, key: key}) do
    header = JSON.encode!(%{"alg" => "RS256", "typ" => "JWT", "kid" => kid})
    input = b64(header) <> "." <> b64(JSON.encode!(claims))
    input <> "." <> b64(:public_key.sign(input, :sha256, key))
  end

  # --- keys ----------------------------------------------------------------------------------

  @doc "The key ring: `%{signing: %{kid, key}, public: [%{kid, n, e}]}`. Creates the file on first use."
  def load! do
    path = file()
    if not File.exists?(path), do: create(path)

    with {:ok, text} <- File.read(path),
         {:ok, %{"keys" => [_ | _] = entries}} <- JSON.decode(Config.strip_bom(text)) do
      keys = Enum.map(entries, &decode!(&1, path))
      [signing | _] = keys
      %{signing: Map.take(signing, [:kid, :key]), public: Enum.map(keys, &Map.take(&1, [:kid, :n, :e]))}
    else
      {:error, reason} when is_atom(reason) -> raise "cannot read #{path}: #{:file.format_error(reason)}"
      _ -> raise "#{path} is not a key list"
    end
  end

  defp decode!(%{"pem" => pem}, path) when is_binary(pem) do
    case :public_key.pem_decode(pem) do
      [entry] ->
        {:RSAPrivateKey, _, n, e, _, _, _, _, _, _, _} = key = :public_key.pem_entry_decode(entry)
        %{kid: kid(n, e), key: key, n: n, e: e}

      _ ->
        raise "#{path} holds a key that is not an RSA private key"
    end
  rescue
    _error in [MatchError, ArgumentError] ->
      reraise RuntimeError, [message: "#{path} holds a key that is not an RSA private key"], __STACKTRACE__
  end

  defp decode!(_entry, path), do: raise("#{path} holds a key that is not an RSA private key")

  # Exclusive: two requests creating it at once both read the one written first.
  defp create(path) do
    File.mkdir_p!(Path.dirname(path))

    with :ok <- File.write(path, encode([entry(now())]), [:exclusive]) do
      _ = File.chmod(path, 0o600)
      Logger.info("auth: created #{path}")
    end
  end

  @doc "Puts a new signing key first; keeps the others an hour after they were retired. Returns its id."
  def roll! do
    now = now()
    path = file()
    entries = if File.exists?(path), do: load_entries(path), else: []

    kept =
      for entry <- entries,
          retired = entry["retired"] || now,
          retired + @max_ttl > now,
          do: Map.put(entry, "retired", retired)

    entries = [entry(now) | kept]
    File.mkdir_p!(Path.dirname(path))
    File.write!(path <> ".tmp", encode(entries))
    _ = File.chmod(path <> ".tmp", 0o600)
    File.rename!(path <> ".tmp", path)
    load!().signing.kid
  end

  defp load_entries(path) do
    _ = load!()
    path |> File.read!() |> Config.strip_bom() |> JSON.decode!() |> Map.fetch!("keys")
  end

  defp entry(now) do
    key = :public_key.generate_key({:rsa, 2048, 65_537})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])
    %{"pem" => pem, "created" => now}
  end

  defp encode(entries), do: JSON.encode!(%{"keys" => entries})
  defp now, do: System.system_time(:second)

  @doc "The public keys as JWKs."
  def jwks(nil), do: []

  def jwks(%{public: public}) do
    for %{kid: kid, n: n, e: e} <- public do
      %{"kty" => "RSA", "n" => b64u(n), "e" => b64u(e), "kid" => kid, "alg" => "RS256", "use" => "sig"}
    end
  end

  @doc "A key's id: its JWK thumbprint (RFC 7638)."
  def kid(n, e), do: :crypto.hash(:sha256, ~s({"e":"#{b64u(e)}","kty":"RSA","n":"#{b64u(n)}"})) |> b64()

  defp b64u(integer), do: integer |> :binary.encode_unsigned() |> b64()
  defp b64(bytes), do: Base.url_encode64(bytes, padding: false)
end
