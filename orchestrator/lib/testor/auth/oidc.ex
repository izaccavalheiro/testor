defmodule Testor.Auth.OIDC do
  @moduledoc """
  Sign-in to the dashboard with an OpenID Connect provider (Entra ID, Google, Okta, Keycloak,
  Authentik, Dex, GitLab, ...): the authorization code flow with PKCE (`S256`), `state` and
  `nonce`. Groups in the ID token map to a role and to projects; nobody else gets in. Basic
  credentials keep working, for scripts and as a break-glass account (`/auth/basic`).

  `auth.json`:

      "oidc": {
        "issuer": "https://login.example.com/realms/eng",
        "clientId": "testor",
        "clientSecret": "...",                       (or TESTOR_OIDC_CLIENT_SECRET; none: a public client)
        "redirectUri": "https://testor.example.com/auth/callback",
        "roles": {"admin": ["platform"], "operator": ["qa"], "viewer": ["*"]},
        "projects": {"web-team": ["web", "web-*"], "platform": ["*"]},
        "usernameClaim": "email", "groupsClaim": "groups",
        "scopes": ["groups"], "sessionHours": 8, "sessionsValidAfter": 0
      }

  * `roles`: the groups of each role (`*`: anyone the provider signs in); the highest that
    matches wins (`admin`, `operator`, `viewer`). Without one, sign-in is refused.
  * `projects`: the projects of each group (`*` as a group: everyone); a user sees the union of
    their groups'. Without `projects`, every project; with it, a user in no listed group sees
    none.
  * The issuer and the provider's endpoints must be `https` (`http` on loopback only).

  The login's `state`, `nonce` and PKCE verifier travel in an encrypted cookie that lives ten
  minutes, so any replica can finish a sign-in. A session is a token signed with the token
  keys (`Testor.Auth.TokenKeys`) for the audience `testor-session`, which API requests cannot
  use as a Bearer token, in an `HttpOnly`, `SameSite=Lax` cookie (`Secure` when `redirectUri`
  is `https`). Raising `sessionsValidAfter` (a Unix time) ends every session before it.
  """
  require Logger
  alias Testor.Auth
  alias Testor.Auth.JWT

  @session_cookie "testor_session"
  @login_cookie "testor_oidc"
  @login_max_age 600
  @session_audience "testor-session"
  @leeway 60
  @cache_ttl_ms 3_600_000
  @refetch_ms 60_000
  # Highest first.
  @roles ["admin", "operator", "viewer"]
  @p256 {1, 2, 840, 10045, 3, 1, 7}

  def session_cookie, do: @session_cookie
  def login_cookie, do: @login_cookie

  # --- configuration -------------------------------------------------------------------------

  @doc "The `oidc` section of `auth.json`, checked; nil when absent or not valid (logged)."
  def config(nil), do: nil

  def config(%{} = raw) do
    secret =
      case System.get_env("TESTOR_OIDC_CLIENT_SECRET") do
        value when value in [nil, ""] -> raw["clientSecret"]
        value -> value
      end

    redirect = raw["redirectUri"]

    with :ok <- check(secure_url?(raw["issuer"]), "issuer must be an https URL"),
         :ok <- check(is_binary(raw["clientId"]) and raw["clientId"] != "", "clientId is required"),
         :ok <- check(secret == nil or (is_binary(secret) and secret != ""), "clientSecret must be a string"),
         :ok <-
           check(
             url?(redirect) and String.ends_with?(URI.parse(redirect).path || "", "/auth/callback"),
             "redirectUri must be the URL of testor's /auth/callback"
           ),
         {:ok, roles} <- roles(raw["roles"]),
         {:ok, projects} <- projects(raw["projects"]),
         :ok <- check(strings?(raw["scopes"] || []), "scopes must be a list of strings") do
      %{
        issuer: raw["issuer"],
        client_id: raw["clientId"],
        client_secret: secret,
        redirect_uri: redirect,
        secure: URI.parse(redirect).scheme == "https",
        scopes: Enum.uniq(["openid", "email", "profile" | raw["scopes"] || []]),
        username_claim: string_or(raw["usernameClaim"], "email"),
        groups_claim: string_or(raw["groupsClaim"], "groups"),
        roles: roles,
        projects: projects,
        session_ttl: session_ttl(raw["sessionHours"]),
        valid_after: if(is_integer(raw["sessionsValidAfter"]), do: raw["sessionsValidAfter"], else: 0)
      }
    else
      {:error, why} ->
        Logger.warning("auth: oidc is not valid (#{why}): sign-in with the identity provider is off")
        nil
    end
  end

  def config(_raw) do
    Logger.warning("auth: oidc is not an object: sign-in with the identity provider is off")
    nil
  end

  defp check(true, _why), do: :ok
  defp check(_false, why), do: {:error, why}

  defp roles(%{} = roles) do
    if Enum.all?(roles, fn {role, groups} -> role in @roles and strings?(groups) end) and map_size(roles) > 0,
      do: {:ok, roles},
      else: {:error, "roles maps admin, operator or viewer to lists of groups"}
  end

  defp roles(_), do: {:error, "roles maps admin, operator or viewer to lists of groups"}

  defp projects(nil), do: {:ok, nil}

  defp projects(%{} = projects) do
    if Enum.all?(projects, fn {_group, patterns} -> is_list(patterns) and Enum.all?(patterns, &Testor.Access.valid_pattern?/1) end),
      do: {:ok, projects},
      else: {:error, "projects maps groups to lists of project names or patterns"}
  end

  defp projects(_), do: {:error, "projects maps groups to lists of project names or patterns"}

  defp strings?(list), do: is_list(list) and Enum.all?(list, &(is_binary(&1) and &1 != ""))
  defp string_or(value, default), do: if(is_binary(value) and value != "", do: value, else: default)

  defp session_ttl(hours) when is_number(hours) and hours > 0, do: round(min(hours, 168) * 3600)
  defp session_ttl(_), do: 8 * 3600

  @doc "An absolute http(s) URL with a host."
  def url?(url) do
    is_binary(url) and
      match?(%URI{scheme: scheme, host: host} when scheme in ["https", "http"] and host not in [nil, ""], URI.parse(url))
  end

  @doc "An https URL, or http on loopback (a provider on the same machine, tests)."
  def secure_url?(url) do
    url?(url) and
      case URI.parse(url) do
        %URI{scheme: "https"} -> true
        %URI{host: host} -> host in ["localhost", "127.0.0.1", "::1"]
      end
  end

  # --- signing in ----------------------------------------------------------------------------

  @doc """
  Starts a sign-in: `{:ok, url, cookie}`, the provider's authorization URL to redirect to and
  the encrypted login cookie to set, or `{:error, why}`.
  """
  def login(%{oidc: oidc, key: key}, return_to) do
    with {:ok, meta} <- metadata(oidc) do
      verifier = random(32)

      login = %{
        "state" => random(16),
        "nonce" => random(16),
        "verifier" => verifier,
        "return" => safe_return(return_to)
      }

      query =
        URI.encode_query(%{
          "response_type" => "code",
          "client_id" => oidc.client_id,
          "redirect_uri" => oidc.redirect_uri,
          "scope" => Enum.join(oidc.scopes, " "),
          "state" => login["state"],
          "nonce" => login["nonce"],
          "code_challenge" => challenge(verifier),
          "code_challenge_method" => "S256"
        })

      endpoint = meta["authorization_endpoint"]
      separator = if String.contains?(endpoint, "?"), do: "&", else: "?"
      {:ok, endpoint <> separator <> query, Plug.Crypto.encrypt(key, @login_cookie, login, max_age: @login_max_age)}
    end
  end

  @doc "The PKCE challenge of a verifier (RFC 7636, `S256`)."
  def challenge(verifier), do: :crypto.hash(:sha256, verifier) |> b64()

  # Only a path of this server: never `//host` or a URL, which would make this an open redirect.
  defp safe_return("/" <> rest = path) do
    if String.starts_with?(rest, ["/", "\\"]) or String.contains?(path, ["\r", "\n"]), do: "/", else: path
  end

  defp safe_return(_), do: "/"

  @doc """
  Finishes a sign-in with the provider's answer (`params`) and the login cookie:
  `{:ok, %{user, role, projects, session, max_age, return}}` or `{:error, why}`.
  """
  def callback(settings, params, cookie, now \\ System.system_time(:second))

  def callback(_settings, %{"error" => error} = params, _cookie, _now) do
    {:error, "the identity provider refused the sign-in: #{error} #{params["error_description"]}" |> String.trim()}
  end

  def callback(%{oidc: oidc, key: key} = settings, params, cookie, now) do
    with {:ok, login} <- decrypt(key, cookie),
         :ok <- check(state?(params["state"], login["state"]), "the sign-in's state does not match; start again"),
         :ok <- check(is_binary(params["code"]), "the identity provider sent no code"),
         {:ok, meta} <- metadata(oidc),
         {:ok, id_token} <- exchange(oidc, meta, params["code"], login["verifier"]),
         {:ok, claims} <- verify_id_token(id_token, oidc, meta, login["nonce"], now),
         {:ok, identity} <- identity(claims, oidc) do
      session = session_token(settings, identity, now)
      {:ok, Map.merge(identity, %{session: session, max_age: oidc.session_ttl, return: login["return"]})}
    end
  end

  defp decrypt(key, cookie) when is_binary(cookie) do
    case Plug.Crypto.decrypt(key, @login_cookie, cookie, max_age: @login_max_age) do
      {:ok, %{} = login} -> {:ok, login}
      _ -> {:error, "the sign-in expired or was started elsewhere; start again"}
    end
  end

  defp decrypt(_key, _cookie), do: {:error, "the sign-in expired or was started elsewhere; start again"}

  defp state?(given, expected) when is_binary(given), do: Plug.Crypto.secure_compare(given, expected)
  defp state?(_given, _expected), do: false

  # The authorization code for tokens (RFC 6749, 4.1.3), the client authenticated as the
  # provider supports: client_secret_basic by default, client_secret_post, or none (public).
  defp exchange(oidc, meta, code, verifier) do
    form = %{
      "grant_type" => "authorization_code",
      "code" => code,
      "redirect_uri" => oidc.redirect_uri,
      "code_verifier" => verifier,
      "client_id" => oidc.client_id
    }

    methods = meta["token_endpoint_auth_methods_supported"] || ["client_secret_basic"]

    {form, headers} =
      cond do
        oidc.client_secret == nil ->
          {form, []}

        "client_secret_basic" in methods ->
          pair = URI.encode_www_form(oidc.client_id) <> ":" <> URI.encode_www_form(oidc.client_secret)
          {form, [{~c"authorization", ~c"Basic " ++ String.to_charlist(Base.encode64(pair))}]}

        true ->
          {Map.put(form, "client_secret", oidc.client_secret), []}
      end

    case request(:post, meta["token_endpoint"], headers, URI.encode_query(form)) do
      {:ok, %{"id_token" => id_token}} when is_binary(id_token) ->
        {:ok, id_token}

      {:ok, _} ->
        {:error, "the token endpoint sent no ID token"}

      {:error, why} ->
        {:error, why}
    end
  end

  # --- ID tokens -----------------------------------------------------------------------------

  @doc """
  The claims of an ID token from the provider: signed (RS256, ES256 or EdDSA) with a key of its
  JWKS, issued by the issuer for this client, unexpired, with the login's nonce.
  """
  def verify_id_token(token, oidc, meta, nonce, now) do
    with [header, payload, signature] <- String.split(token, "."),
         {:ok, %{"alg" => alg} = head} when alg in ["RS256", "ES256", "EdDSA"] <- JWT.decode_json(header),
         {:ok, key} <- signing_key(meta["jwks_uri"], alg, head["kid"]),
         {:ok, signature} <- Base.url_decode64(signature, padding: false),
         true <- signed?(alg, header <> "." <> payload, signature, key),
         {:ok, %{} = claims} <- JWT.decode_json(payload),
         :ok <- id_claims(claims, oidc, nonce, now) do
      {:ok, claims}
    else
      {:error, why} when is_binary(why) -> {:error, why}
      false -> {:error, "the ID token's signature does not hold"}
      _ -> {:error, "the ID token is not valid"}
    end
  end

  defp id_claims(claims, oidc, nonce, now) do
    aud = List.wrap(claims["aud"])

    cond do
      claims["iss"] != oidc.issuer -> {:error, "the ID token is from another issuer"}
      oidc.client_id not in aud -> {:error, "the ID token is for another client"}
      length(aud) > 1 and claims["azp"] != oidc.client_id -> {:error, "the ID token is for another client"}
      not is_integer(claims["exp"]) or now >= claims["exp"] + @leeway -> {:error, "the ID token has expired"}
      not is_integer(claims["iat"]) or claims["iat"] > now + @leeway -> {:error, "the ID token is not valid"}
      not state?(claims["nonce"], nonce) -> {:error, "the ID token's nonce does not match"}
      true -> :ok
    end
  end

  # The key of the provider's JWKS that `kid` names (or its only key of the right type): fetched
  # again, at most once a minute, when it is not there (the provider rolled its keys).
  defp signing_key(jwks_uri, alg, kid) do
    with {:ok, jwks} <- cached(jwks_uri, false) do
      case find_key(jwks, alg, kid) do
        nil ->
          with {:ok, fresh} <- cached(jwks_uri, true),
               key when key != nil <- find_key(fresh, alg, kid) do
            {:ok, key}
          else
            nil -> {:error, "the ID token's key is not in the provider's key set"}
            error -> error
          end

        key ->
          {:ok, key}
      end
    end
  end

  defp find_key(%{"keys" => keys}, alg, kid) when is_list(keys) do
    candidates =
      for %{} = jwk <- keys,
          jwk["use"] in [nil, "sig"],
          jwk["alg"] in [nil, alg],
          kid == nil or jwk["kid"] == kid,
          key = decode_key(alg, jwk),
          key != nil,
          do: key

    case {kid, candidates} do
      {nil, [key]} -> key
      {nil, _} -> nil
      {_, [key | _]} -> key
      {_, []} -> nil
    end
  end

  defp find_key(_jwks, _alg, _kid), do: nil

  @doc "A JWK as a key `signed?/4` takes for `alg`, or nil."
  def decode_key("RS256", %{"kty" => "RSA", "n" => n, "e" => e}) do
    with {:ok, n} <- Base.url_decode64(n, padding: false),
         {:ok, e} <- Base.url_decode64(e, padding: false) do
      {:RSAPublicKey, :binary.decode_unsigned(n), :binary.decode_unsigned(e)}
    else
      _ -> nil
    end
  end

  def decode_key("ES256", %{"kty" => "EC", "crv" => "P-256", "x" => x, "y" => y}) do
    with {:ok, <<_::binary-32>> = x} <- Base.url_decode64(x, padding: false),
         {:ok, <<_::binary-32>> = y} <- Base.url_decode64(y, padding: false) do
      {{:ECPoint, <<4, x::binary, y::binary>>}, {:namedCurve, @p256}}
    else
      _ -> nil
    end
  end

  def decode_key("EdDSA", %{"kty" => "OKP", "crv" => "Ed25519", "x" => x}) do
    case Base.url_decode64(x, padding: false) do
      {:ok, <<_::binary-32>> = public} -> {:ed25519, public}
      _ -> nil
    end
  end

  def decode_key(_alg, _jwk), do: nil

  defp signed?("RS256", input, signature, key), do: :public_key.verify(input, :sha256, signature, key)

  # JOSE puts r and s side by side (RFC 7518, 3.4); :public_key takes them DER-encoded.
  defp signed?("ES256", input, <<r::unsigned-256, s::unsigned-256>>, key) do
    der = :public_key.der_encode(:"ECDSA-Sig-Value", {:"ECDSA-Sig-Value", r, s})
    :public_key.verify(input, :sha256, der, key)
  end

  defp signed?("ES256", _input, _signature, _key), do: false

  defp signed?("EdDSA", input, signature, {:ed25519, public}),
    do: :crypto.verify(:eddsa, :none, input, signature, [public, :ed25519])

  # --- who signed in -------------------------------------------------------------------------

  @doc "The user, role and projects the claims of an ID token map to, or why they map to none."
  def identity(claims, oidc) do
    name = claims[oidc.username_claim]
    groups = groups(claims[oidc.groups_claim])

    cond do
      oidc.username_claim == "email" and claims["email_verified"] == false ->
        {:error, "the identity provider has not verified #{name}'s email"}

      not Auth.valid_name?(name) ->
        {:error, "the identity provider sent no usable #{oidc.username_claim} (letters, digits, _ . @ -; up to 64)"}

      true ->
        case Enum.find(@roles, &member?(oidc.roles[&1], groups)) do
          nil -> {:error, "#{name} is in no group that has a role in testor"}
          role -> {:ok, %{user: name, role: role, projects: projects_of(oidc.projects, groups)}}
        end
    end
  end

  defp groups(list) when is_list(list), do: Enum.filter(list, &is_binary/1)
  defp groups(group) when is_binary(group), do: [group]
  defp groups(_), do: []

  defp member?(nil, _groups), do: false
  defp member?(listed, groups), do: "*" in listed or Enum.any?(groups, &(&1 in listed))

  defp projects_of(nil, _groups), do: nil

  defp projects_of(projects, groups) do
    patterns =
      for {group, patterns} <- projects, group == "*" or group in groups, pattern <- patterns, uniq: true, do: pattern

    if "*" in patterns, do: nil, else: patterns
  end

  # --- sessions ------------------------------------------------------------------------------

  @doc "A session for `identity`, signed with the token keys."
  def session_token(%{oidc: oidc, token_keys: %{signing: signing}}, identity, now) do
    claims = %{
      "iss" => JWT.issuer(),
      "aud" => @session_audience,
      "sub" => identity.user,
      "iat" => now,
      "nbf" => now,
      "exp" => now + oidc.session_ttl,
      "jti" => random(16),
      "role" => identity.role
    }

    claims = if identity.projects, do: Map.put(claims, "projects", identity.projects), else: claims
    JWT.sign(claims, signing)
  end

  @doc "The principal of a session cookie, or why it is none."
  def session(settings, token, now \\ System.system_time(:second))

  def session(%{oidc: %{} = oidc, token_keys: %{verify: verify}}, token, now) when is_binary(token) do
    with {:ok, claims} <- JWT.verify(token, %{hs256: nil, eddsa: verify}, now, @session_audience),
         true <- claims["iat"] >= oidc.valid_after || {:error, :revoked},
         scopes when is_list(scopes) <- Auth.role_scopes(claims["role"]) || {:error, :malformed} do
      projects = if is_list(claims["projects"]), do: claims["projects"]
      {:ok, %{sub: claims["sub"], scopes: scopes, via: :session, exp: claims["exp"], projects: projects}}
    end
  end

  def session(_settings, _token, _now), do: {:error, :none}

  # --- the provider's documents --------------------------------------------------------------

  @doc "The provider's metadata (OpenID Connect Discovery), checked against the issuer."
  def metadata(oidc) do
    url = String.trim_trailing(oidc.issuer, "/") <> "/.well-known/openid-configuration"

    with {:ok, meta} <- cached(url, false) do
      endpoints = Enum.map(["authorization_endpoint", "token_endpoint", "jwks_uri"], &meta[&1])

      cond do
        meta["issuer"] != oidc.issuer -> {:error, "the provider's metadata names another issuer"}
        not Enum.all?(endpoints, &secure_url?/1) -> {:error, "the provider's endpoints must be https URLs"}
        true -> {:ok, meta}
      end
    end
  end

  # A JSON document, kept an hour; `fresh` fetches it again unless that was done a minute ago.
  defp cached(url, fresh) do
    now = System.monotonic_time(:millisecond)
    cache = :persistent_term.get({__MODULE__, :cache}, %{})

    case cache[url] do
      {fetched, doc} when now - fetched < @refetch_ms or (not fresh and now - fetched < @cache_ttl_ms) ->
        {:ok, doc}

      _ ->
        with {:ok, doc} <- request(:get, url, [], nil) do
          :persistent_term.put({__MODULE__, :cache}, Map.put(cache, url, {now, doc}))
          {:ok, doc}
        end
    end
  end

  @doc "Forgets the providers' documents."
  def reset_cache, do: :persistent_term.erase({__MODULE__, :cache})

  defp request(method, url, headers, body) do
    headers = [{~c"accept", ~c"application/json"} | headers]

    request =
      if method == :post,
        do: {String.to_charlist(url), headers, ~c"application/x-www-form-urlencoded", body},
        else: {String.to_charlist(url), headers}

    case :httpc.request(method, request, Testor.Webhooks.http_options(), body_format: :binary) do
      {:ok, {{_, 200, _}, _, body}} ->
        case JSON.decode(body) do
          {:ok, %{} = doc} -> {:ok, doc}
          _ -> {:error, "#{url} did not answer a JSON object"}
        end

      {:ok, {{_, status, _}, _, body}} ->
        {:error, "#{url} answered #{status}#{provider_error(body)}"}

      {:error, reason} ->
        {:error, "#{url} cannot be reached (#{inspect(reason)})"}
    end
  end

  defp provider_error(body) do
    case JSON.decode(body) do
      {:ok, %{"error" => error}} when is_binary(error) -> ": " <> error
      _ -> ""
    end
  end

  defp random(bytes), do: :crypto.strong_rand_bytes(bytes) |> b64()
  defp b64(bytes), do: Base.url_encode64(bytes, padding: false)
end
