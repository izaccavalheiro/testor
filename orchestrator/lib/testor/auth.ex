defmodule Testor.Auth do
  @moduledoc """
  Authentication and authorization.

  Off until `<home>/auth.json` lists a user, so an existing install keeps working until its
  owner adds one. Once on, every request but the health check needs credentials:

    * HTTP Basic (RFC 7617): a user's name and password. Browsers prompt for it and send it
      with every request of the dashboard, its event streams included.
    * Bearer (RFC 6750): a JSON Web Token from `POST /api/v1/auth/token` (HS256, signed with
      `jwt.key` or `TESTOR_JWT_SECRET`), for scripts, CI and MCP clients. Only Basic
      credentials can obtain one, so a token can never be used to extend itself.

  A user has a role, and a role grants scopes:

  | Role       | Scopes                       | Can                                                 |
  | ---------- | ---------------------------- | --------------------------------------------------- |
  | `viewer`   | `read`                       | read runs, logs, screenshots, artifacts, stats      |
  | `operator` | `read operate`               | also cancel and delete runs, clean up, scan         |
  | `admin`    | `read operate maintain`      | also delete maintenance targets                     |

  A token carries a subset of its user's scopes and is checked against the user on every
  request: removing the user, lowering the role or setting `tokensValidAfter` (see
  `Testor.Auth.CLI.revoke/1`) takes effect at once. Rotating the key revokes every token.

  Screenshots and artifacts are linked with a signed prefix (`/s/<expiry>.<mac>/...`) bound to
  their run, valid for one to two days: images, videos and sandboxed HTML reports (which have
  an opaque origin, so no credentials) load without a password, and a report can reach its own
  run's files only.

  `auth.json`:

      {"users": {"ada": {"password": "$pbkdf2-sha256$600000$...", "role": "admin"}},
       "tokens": {"defaultTtlMinutes": 60, "maxTtlDays": 30}}

  A file that cannot be read or parsed locks everything but the health check (fail closed).
  """
  require Logger
  alias Testor.Config
  alias Testor.Auth.{Guard, JWT, Password}

  @roles %{
    "viewer" => ["read"],
    "operator" => ["read", "operate"],
    "admin" => ["read", "operate", "maintain"]
  }
  @scopes ["read", "operate", "maintain"]
  @min_ttl 60
  @default_ttl 3600
  @max_ttl 30 * 86_400
  @reload_ms 1000

  def roles, do: @roles |> Map.keys() |> Enum.sort()
  def role_scopes(role), do: Map.get(@roles, role)

  @doc "A user name testor accepts."
  def valid_name?(name), do: is_binary(name) and Regex.match?(~r/^[A-Za-z0-9_.@-]{1,64}$/, name)

  def auth_file, do: Path.join(Config.data_dir(), "auth.json")
  def key_file, do: Path.join(Config.data_dir(), "jwt.key")

  # --- settings ------------------------------------------------------------------------------

  @doc """
  The settings in force: `%{enabled, users, key, default_ttl, max_ttl}`. `auth.json` and the
  key are read again at most once a second, so changes apply without a restart. Tests set
  them with `Application.put_env(:testor, :auth, raw)` (and `:auth_key`).
  """
  def settings do
    case Application.get_env(:testor, :auth) do
      nil -> cached()
      raw -> build(raw, Application.get_env(:testor, :auth_key, String.duplicate("k", 32)))
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

    {read.(auth_file()), read.(key_file()), :erlang.phash2(System.get_env("TESTOR_JWT_SECRET"))}
  end

  @doc "Reads `auth.json` and the key now (no cache)."
  def load_settings do
    raw = read_raw()
    enabled = enabled_in?(raw)
    build(raw, if(enabled, do: key!()))
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
      _ -> map_size(users_in(raw)) > 0
    end
  end

  defp users_in(raw) do
    case raw["users"] do
      %{} = users -> users
      _ -> %{}
    end
  end

  defp locked, do: %{enabled: true, users: %{}, key: nil, default_ttl: @default_ttl, max_ttl: @max_ttl}

  defp build(raw, key) do
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
        {name, %{hash: hash, role: role, scopes: scopes, valid_after: valid_after}}
      end

    tokens = if is_map(raw["tokens"]), do: raw["tokens"], else: %{}
    max_ttl = seconds(tokens["maxTtlDays"], 86_400, @max_ttl)

    %{
      enabled: enabled_in?(raw),
      users: users,
      key: key,
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

  defp principal(name, user, via), do: %{sub: name, scopes: user.scopes, via: via}

  # --- authentication ------------------------------------------------------------------------

  @doc "Checks a user name and password from `address`."
  def basic(settings, name, password, address) do
    with :ok <- unblocked(address) do
      case settings.users[name] do
        nil ->
          Password.dummy_verify()
          failure(address, "unknown user #{inspect(name)}", :invalid_credentials)

        user ->
          key = Guard.cache_key([name, password, user.hash])

          cond do
            Guard.cached?(key) ->
              {:ok, principal(name, user, :basic)}

            Password.verify(password, user.hash) ->
              Guard.remember(key)
              {:ok, principal(name, user, :basic)}

            true ->
              failure(address, "wrong password for #{inspect(name)}", :invalid_credentials)
          end
      end
    end
  end

  @doc "Checks a Bearer token from `address`."
  def bearer(%{key: nil}, _token, _address), do: {:error, :invalid_token}

  def bearer(settings, token, address) do
    with :ok <- unblocked(address) do
      case JWT.verify(token, settings.key) do
        {:ok, %{"iat" => issued} = claims} ->
          case settings.users[claims["sub"]] do
            %{valid_after: valid_after} = user when issued >= valid_after ->
              scope = if is_binary(claims["scope"]), do: claims["scope"], else: ""
              granted = scope |> split_scopes() |> Enum.filter(&(&1 in user.scopes))
              {:ok, %{sub: claims["sub"], scopes: granted, via: :bearer, exp: claims["exp"]}}

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

  defp unblocked(address) do
    case Guard.check(address) do
      :ok -> :ok
      {:blocked, seconds} -> {:error, {:rate_limited, seconds}}
    end
  end

  defp failure(address, why, error) do
    Guard.failed(address)
    Logger.warning("auth: #{why} from #{address}")
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
      "access_token" => JWT.sign(claims, settings.key),
      "token_type" => "Bearer",
      "expires_in" => ttl,
      "scope" => claims["scope"]
    }
  end

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
