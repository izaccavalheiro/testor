defmodule Testor.Auth do
  @moduledoc """
  Authentication and authorization.

  Off until `<home>/auth.json` lists a user or an `oidc` provider, so an existing install
  keeps working until its owner adds one. Once on, every request but the health check needs credentials:

    * HTTP Basic (RFC 7617): a user's name and password. Browsers prompt for it and send it
      with every request of the dashboard, its event streams included.
    * Bearer (RFC 6750): a JSON Web Token from `POST /api/v1/auth/token`, for scripts, CI and
      MCP clients. Only Basic credentials can obtain one, so a token can never be used to
      extend itself. Signed with Ed25519 (`EdDSA`, `Testor.Auth.TokenKeys`), whose public
      keys are at `/.well-known/jwks.json` for other services to verify a token with; tokens
      signed with `jwt.key` or `TESTOR_JWT_SECRET` (`HS256`, before 0.8) are still accepted.
    * A session cookie, once signed in with an OpenID Connect provider (`Testor.Auth.OIDC`):
      the dashboard sends users without credentials there when one is set up.

  A user has a role, and a role grants scopes:

  | Role       | Scopes                       | Can                                                 |
  | ---------- | ---------------------------- | --------------------------------------------------- |
  | `viewer`   | `read`                       | read runs, logs, screenshots, artifacts, stats      |
  | `operator` | `read operate`               | also cancel and delete runs, clean up, scan         |
  | `admin`    | `read operate maintain`      | also delete maintenance targets                     |

  A token carries a subset of its user's scopes and is checked against the user on every
  request: removing the user, lowering the role or setting `tokensValidAfter` (see
  `Testor.Auth.CLI.revoke/1`) takes effect at once. Rotating the keys revokes every token.

  Screenshots and artifacts are linked with a signed prefix (`/s/<expiry>.<mac>/...`) bound to
  their run, valid for one to two days: images, videos and sandboxed HTML reports (which have
  an opaque origin, so no credentials) load without a password, and a report can reach its own
  run's files only.

  `auth.json`:

      {"users": {"ada": {"password": "$pbkdf2-sha256$600000$...", "role": "admin"}},
       "tokens": {"defaultTtlMinutes": 60, "maxTtlDays": 30, "algorithm": "EdDSA", "acceptHs256": true}}

  `tokens.algorithm` is what new tokens are signed with: `EdDSA` (the default) or `HS256`;
  `tokens.acceptHs256: false` refuses HS256 tokens while `EdDSA` signs.

  A file that cannot be read or parsed locks everything but the health check (fail closed).
  """
  require Logger
  alias Testor.Config
  alias Testor.Auth.{Guard, JobTokens, JWT, OIDC, Password, TokenKeys}

  @roles %{
    "viewer" => ["read"],
    "operator" => ["read", "operate"],
    "admin" => ["read", "operate", "maintain", "execute"],
    # Runners' agents (runner/agent.ps1): they take jobs and report on them, nothing else.
    "agent" => ["agent"]
  }
  @scopes ["read", "operate", "maintain", "execute", "agent"]
  @min_ttl 60
  @default_ttl 3600
  @max_ttl 30 * 86_400
  @reload_ms 1000
  @algorithms ["EdDSA", "HS256"]

  def roles, do: @roles |> Map.keys() |> Enum.sort()
  def role_scopes(role), do: Map.get(@roles, role)

  @doc "A user name testor accepts."
  def valid_name?(name), do: is_binary(name) and Regex.match?(~r/^[A-Za-z0-9_.@-]{1,64}$/, name)

  def auth_file, do: Path.join(Config.secrets_dir(), "auth.json")
  def key_file, do: Path.join(Config.secrets_dir(), "jwt.key")

  # --- settings ------------------------------------------------------------------------------

  @doc """
  The settings in force: `%{enabled, users, key, token_keys, algorithm, accept_hs256,
  default_ttl, max_ttl}`. `auth.json` and the keys are read again at most once a second, so
  changes apply without a restart. Tests set them with `Application.put_env(:testor, :auth,
  raw)` (and `:auth_key`, `:auth_token_keys`).
  """
  def settings do
    case Application.get_env(:testor, :auth) do
      nil ->
        cached()

      raw ->
        build(
          raw,
          Application.get_env(:testor, :auth_key, String.duplicate("k", 32)),
          Application.get_env(:testor, :auth_token_keys) || TokenKeys.from_seeds([<<1::256>>]),
          Application.get_env(:testor, :auth_job_token_keys)
        )
    end
  end

  def enabled?, do: settings().enabled

  defp cached do
    now = System.monotonic_time(:millisecond)

    case :persistent_term.get({__MODULE__, :settings}, nil) do
      {checked, _sig, settings} when now - checked < @reload_ms ->
        settings

      previous ->
        sig = signature()

        settings =
          case previous do
            {_, ^sig, settings} -> settings
            _ -> load_settings()
          end

        :persistent_term.put({__MODULE__, :settings}, {now, sig, settings})
        settings
    end
  end

  defp signature do
    read = fn path ->
      case File.read(path) do
        {:ok, text} -> :erlang.phash2(text)
        _ -> nil
      end
    end

    {read.(auth_file()), read.(key_file()), read.(TokenKeys.file()), read.(JobTokens.file()),
     :erlang.phash2({
       System.get_env("TESTOR_JWT_SECRET"),
       System.get_env(TokenKeys.env()),
       System.get_env("TESTOR_OIDC_CLIENT_SECRET")
     })}
  end

  @doc "Reads `auth.json` and the keys now (no cache)."
  def load_settings do
    raw = read_raw()

    cond do
      not enabled_in?(raw) -> build(raw, nil, nil, nil)
      # The job tokens' RSA key is made only once they are on.
      JobTokens.config(raw["jobTokens"]) -> build(raw, key!(), TokenKeys.load!(), JobTokens.load!())
      true -> build(raw, key!(), TokenKeys.load!(), nil)
    end
  rescue
    error ->
      Logger.error("auth: #{Exception.message(error)}; refusing every request until it is fixed")
      locked()
  end

  @doc "The contents of auth.json, `%{}` when there is none. Raises when it cannot be read."
  def read_raw do
    case File.read(auth_file()) do
      {:ok, text} ->
        case JSON.decode(Config.strip_bom(text)) do
          {:ok, %{} = map} -> map
          _ -> raise "#{auth_file()} is not a JSON object"
        end

      {:error, :enoent} ->
        %{}

      {:error, reason} ->
        raise "cannot read #{auth_file()}: #{:file.format_error(reason)}"
    end
  end

  defp enabled_in?(raw) do
    case raw["enabled"] do
      value when is_boolean(value) -> value
      _ -> map_size(users_in(raw)) > 0 or Map.has_key?(raw, "oidc")
    end
  end

  defp users_in(raw) do
    case raw["users"] do
      %{} = users -> users
      _ -> %{}
    end
  end

  defp locked do
    %{
      enabled: true,
      users: %{},
      key: nil,
      token_keys: nil,
      job_tokens: nil,
      job_token_keys: nil,
      oidc: nil,
      algorithm: "EdDSA",
      accept_hs256: false,
      default_ttl: @default_ttl,
      max_ttl: @max_ttl
    }
  end

  defp build(raw, key, token_keys, job_token_keys) do
    users =
      for {name, %{"password" => hash} = user} <- users_in(raw),
          valid_name?(name),
          Password.valid?(hash),
          into: %{} do
        role = user["role"] || "viewer"

        scopes =
          case role_scopes(role) do
            nil ->
              Logger.warning("auth: #{name} has an unknown role #{inspect(role)}: no access")
              []

            scopes ->
              scopes
          end

        valid_after = if is_integer(user["tokensValidAfter"]), do: user["tokensValidAfter"], else: 0

        case user["projects"] do
          # A role per project: {"web*": "operator", "docs": "viewer"}.
          %{} = roles ->
            project_roles = project_roles(name, roles)

            {name,
             %{
               hash: hash,
               role: role,
               scopes: project_roles |> Enum.flat_map(& &1.scopes) |> Enum.uniq(),
               valid_after: valid_after,
               projects: Enum.map(project_roles, & &1.pattern),
               project_roles: project_roles
             }}

          _ ->
            {name,
             %{
               hash: hash,
               role: role,
               scopes: scopes,
               valid_after: valid_after,
               projects: projects_of(name, user)
             }}
        end
      end

    tokens = if is_map(raw["tokens"]), do: raw["tokens"], else: %{}
    max_ttl = seconds(tokens["maxTtlDays"], 86_400, @max_ttl)

    algorithm =
      case tokens["algorithm"] do
        nil ->
          "EdDSA"

        algorithm when algorithm in @algorithms ->
          algorithm

        other ->
          Logger.warning(
            "auth: tokens.algorithm #{inspect(other)} is not one of #{Enum.join(@algorithms, ", ")}: EdDSA"
          )

          "EdDSA"
      end

    %{
      enabled: enabled_in?(raw),
      users: users,
      key: key,
      token_keys: token_keys,
      oidc: OIDC.config(raw["oidc"]),
      job_tokens: JobTokens.config(raw["jobTokens"]),
      job_token_keys: job_token_keys,
      algorithm: algorithm,
      # Tokens issued before 0.8 are HS256: accepted until the next major version unless refused.
      accept_hs256: algorithm == "HS256" or tokens["acceptHs256"] != false,
      max_ttl: max_ttl,
      default_ttl: min(seconds(tokens["defaultTtlMinutes"], 60, @default_ttl), max_ttl)
    }
  end

  defp seconds(n, unit, _default) when is_number(n) and n * unit >= @min_ttl, do: round(n * unit)
  defp seconds(_, _, default), do: default

  @doc "The signing key: `TESTOR_JWT_SECRET` (32 bytes or more), else `jwt.key`, created on first use."
  def key! do
    case System.get_env("TESTOR_JWT_SECRET") do
      secret when is_binary(secret) and byte_size(secret) >= 32 -> secret
      _ -> key_from_file()
    end
  end

  defp key_from_file do
    path = key_file()
    if not File.exists?(path), do: create_key(path)

    case File.read(path) do
      {:ok, text} ->
        case Base.decode64(String.trim(text)) do
          {:ok, key} when byte_size(key) >= 32 -> key
          _ -> raise "#{path} is not a base64 key of 32 bytes or more"
        end

      {:error, reason} ->
        raise "cannot read #{path}: #{:file.format_error(reason)}"
    end
  end

  # Exclusive: when two requests create it at once, both read the one that was written first.
  defp create_key(path) do
    File.mkdir_p!(Path.dirname(path))

    with :ok <- File.write(path, Base.encode64(:crypto.strong_rand_bytes(32)), [:exclusive]) do
      _ = File.chmod(path, 0o600)
      Logger.info("auth: created #{path}")
    end
  end

  # --- principals ----------------------------------------------------------------------------

  @doc "Who makes a request while authentication is off: anyone, with every scope."
  def anonymous, do: %{sub: nil, scopes: @scopes, via: :none}

  @doc "A request without credentials to a public path while authentication is on."
  def public, do: %{sub: nil, scopes: [], via: :public}

  def who(%{sub: nil, via: via}), do: to_string(via)
  def who(%{sub: sub}), do: sub

  defp principal(name, user, via),
    do: %{
          sub: name,
          scopes: user.scopes,
          via: via,
          projects: Map.get(user, :projects),
          project_roles: Map.get(user, :project_roles)
        }

  # The projects a user may see (Testor.Access): nil for all; a list that cannot be read
  # fails closed, to no project at all.
  # Entries with a pattern or a role testor does not know are dropped (and logged): fail closed.
  defp project_roles(name, roles) do
    {valid, invalid} =
      Enum.split_with(roles, fn {pattern, role} ->
        Testor.Access.valid_pattern?(pattern) and role_scopes(role) != nil
      end)

    if invalid != [],
      do: Logger.warning("auth: #{name} has project roles that are not valid, left out: #{inspect(Map.new(invalid))}")

    valid
    |> Enum.sort()
    |> Enum.map(fn {pattern, role} -> %{pattern: pattern, role: role, scopes: role_scopes(role)} end)
  end

  defp projects_of(_name, %{"projects" => nil}), do: nil
  defp projects_of(_name, user) when not is_map_key(user, "projects"), do: nil

  defp projects_of(name, %{"projects" => list}) do
    valid = if is_list(list), do: Enum.filter(list, &Testor.Access.valid_pattern?/1), else: []

    if not is_list(list) or length(valid) != length(list),
      do:
        Logger.warning(
          "auth: #{name} has projects that are not names or patterns: #{inspect(list)}; only #{inspect(valid)} kept"
        )

    valid
  end

  # --- authentication ------------------------------------------------------------------------

  @doc "Checks a user name and password from `address`."
  def basic(settings, name, password, address) do
    with :ok <- unblocked(address) do
      case settings.users[name] do
        nil ->
          Guard.hashing(fn ->
            Password.dummy_verify()
            failure(address, "unknown user #{inspect(name)}", :invalid_credentials)
          end)

        user ->
          key = Guard.cache_key([name, password, user.hash])

          if Guard.cached?(key) do
            {:ok, principal(name, user, :basic)}
          else
            with :ok <- unblocked({:user, name}) do
              Guard.hashing(fn -> check_password(name, password, user, key, address) end)
            end
          end
      end
    end
  end

  defp check_password(name, password, user, key, address) do
    if Password.verify(password, user.hash) do
      Guard.remember(key)
      {:ok, principal(name, user, :basic)}
    else
      Guard.failed({:user, name})
      failure(address, "wrong password for #{inspect(name)}", :invalid_credentials)
    end
  end

  @doc "Checks a Bearer token from `address`."
  def bearer(%{key: nil}, _token, _address), do: {:error, :invalid_token}

  def bearer(settings, token, address) do
    with :ok <- unblocked(address) do
      case JWT.verify(token, verification_keys(settings)) do
        {:ok, %{"iat" => issued} = claims} ->
          case settings.users[claims["sub"]] do
            %{valid_after: valid_after} = user when issued >= valid_after ->
              scope = if is_binary(claims["scope"]), do: claims["scope"], else: ""
              granted = scope |> split_scopes() |> Enum.filter(&(&1 in user.scopes))

              {:ok,
               %{
                 sub: claims["sub"],
                 scopes: granted,
                 via: :bearer,
                 exp: claims["exp"],
                 projects: Map.get(user, :projects),
                 project_roles: Map.get(user, :project_roles)
               }}

            _ ->
              {:error, :revoked}
          end

        # An expired token is a client that forgot to renew, not an attack.
        {:error, reason} when reason in [:expired, :not_yet_valid] ->
          {:error, :expired}

        {:error, reason} ->
          failure(address, "invalid token (#{reason})", :invalid_token)
      end
    end
  end

  defp verification_keys(settings) do
    %{
      hs256: if(settings.accept_hs256, do: settings.key),
      eddsa: if(settings.token_keys, do: settings.token_keys.verify, else: %{})
    }
  end

  defp unblocked(key) do
    case Guard.check(key) do
      :ok -> :ok
      {:blocked, seconds} -> {:error, {:rate_limited, seconds}}
    end
  end

  defp failure(address, why, error) do
    Guard.failed(address)
    Logger.warning("auth: #{why} from #{address}")
    Testor.Audit.record("auth_failed", %{"from" => address, "why" => why})
    {:error, error}
  end

  # --- tokens --------------------------------------------------------------------------------

  @doc """
  A token for a principal authenticated with Basic credentials. `request` may hold `scope`
  (space-separated, a subset of the user's; all of them by default) and `expires_in` (seconds,
  #{@min_ttl} up to `tokens.maxTtlDays`).
  """
  def issue_token(principal, request, settings \\ settings())

  def issue_token(%{via: :basic, sub: sub, scopes: scopes}, request, settings) do
    requested =
      case request["scope"] do
        nil -> scopes
        scope when is_binary(scope) -> split_scopes(scope)
        _ -> :invalid
      end

    ttl = ttl(request["expires_in"], settings)

    cond do
      requested == :invalid or requested == [] or not Enum.all?(requested, &(&1 in scopes)) ->
        {:error, :invalid_scope}

      ttl == :invalid ->
        {:error, :invalid_request}

      true ->
        {:ok, mint(sub, requested, ttl, settings)}
    end
  end

  def issue_token(_principal, _request, _settings), do: {:error, :invalid_client}

  defp ttl(nil, settings), do: settings.default_ttl
  defp ttl(n, settings) when is_integer(n) and n >= @min_ttl, do: min(n, settings.max_ttl)

  defp ttl(s, settings) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> ttl(n, settings)
      _ -> :invalid
    end
  end

  defp ttl(_, _settings), do: :invalid

  @doc "Signs a token for `sub` with `scopes`, valid `ttl` seconds (no checks: the CLI and `issue_token/3`)."
  def mint(sub, scopes, ttl, settings) do
    now = System.system_time(:second)

    claims = %{
      "iss" => JWT.issuer(),
      "aud" => JWT.issuer(),
      "sub" => sub,
      "iat" => now,
      "nbf" => now,
      "exp" => now + ttl,
      "jti" => Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false),
      "scope" => Enum.join(scopes, " ")
    }

    %{
      "access_token" => JWT.sign(claims, signing_key(settings)),
      "token_type" => "Bearer",
      "expires_in" => ttl,
      "scope" => claims["scope"]
    }
  end

  defp signing_key(%{algorithm: "HS256", key: key}), do: key
  defp signing_key(%{token_keys: %{signing: signing}}), do: signing

  defp split_scopes(scope), do: scope |> String.split(" ", trim: true) |> Enum.uniq()

  # --- signed file links ---------------------------------------------------------------------

  @doc "The prefix of a run's screenshot and artifact links: `\"\"` while authentication is off."
  def file_prefix(id, settings \\ settings(), now \\ System.system_time(:second))

  def file_prefix(id, %{enabled: true, key: key}, now) when is_binary(key) do
    # The expiry is the end of tomorrow (UTC): every link made today is the same, so browsers
    # cache the files, and a link lives one to two days.
    expires = (div(now, 86_400) + 2) * 86_400
    "/s/#{expires}." <> file_mac(key, id, expires)
  end

  def file_prefix(_id, _settings, _now), do: ""

  @doc "Whether `cap` (from `file_prefix/3`) is a valid, unexpired link to run `id`'s files."
  def file_cap_valid?(cap, id, settings \\ settings(), now \\ System.system_time(:second))

  def file_cap_valid?(_cap, _id, %{enabled: false}, _now), do: true

  def file_cap_valid?(cap, id, %{key: key}, now) when is_binary(key) and is_binary(cap) do
    with [expires, mac] <- String.split(cap, ".", parts: 2),
         {expires, ""} <- Integer.parse(expires),
         true <- expires > now and expires <= now + 3 * 86_400 do
      Plug.Crypto.secure_compare(file_mac(key, id, expires), mac)
    else
      _ -> false
    end
  end

  def file_cap_valid?(_cap, _id, _settings, _now), do: false

  defp file_mac(key, id, expires) do
    :crypto.mac(:hmac, :sha256, key, "file\0#{id}\0#{expires}")
    |> binary_part(0, 18)
    |> Base.url_encode64(padding: false)
  end
end
