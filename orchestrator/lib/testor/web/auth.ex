defmodule Testor.Web.Auth do
  @moduledoc """
  The security plugs in front of every route. `call/2` authenticates and authorizes a request
  (`Testor.Auth` describes the scheme), assigning `:principal`; `csrf/2` guards state-changing
  requests; `audit/2` logs them.

  While authentication is off, only the addresses `TESTOR_ANONYMOUS` allows are answered
  (private ones by default), so a runner on a public address is not open to the internet.

  Public paths, answered without credentials: `GET /api/health`, `GET /api/v1/health`,
  `GET /api/v1/openapi.json`, `GET /.well-known/jwks.json`, the sign-in pages (`/auth/login`,
  `/auth/callback`, `/auth/signed-out`, `POST /auth/logout`), and the signed file links under
  `/s/`, which their route checks.

  With an OpenID Connect provider set up (`Testor.Auth.OIDC`), a request without credentials
  may carry a session cookie; the dashboard's page sends a visitor without either to
  `/auth/login`, and only `/?basic` asks a browser for Basic credentials (the break-glass
  sign-in), so an expired session never brings up the browser's password dialog.

  Scopes required:

    * `maintain`: `POST /api/maintenance/clean`, `POST /api/v1/maintenance/clean`,
      `GET /api/v1/audit`
    * `execute`: `POST /api/v1/jobs`, `POST /api/v1/jobs/:id/cancel`
    * `agent`: everything under `/api/v1/agent/`
    * `read`: `POST /api/v1/auth/token` (which also requires Basic credentials) and `POST /mcp`
      (each tool requires its own scope)
    * `operate`: any other `POST`, `PUT`, `PATCH` or `DELETE`
    * `read`: everything else
  """
  import Plug.Conn
  require Logger
  alias Testor.Auth
  alias Testor.Auth.OIDC
  alias Testor.Web.Reply

  @unsafe ["POST", "PUT", "PATCH", "DELETE"]

  def init(opts), do: opts

  def call(conn, _opts) do
    settings = Auth.settings()

    cond do
      settings.enabled ->
        authenticate(conn, settings)

      anonymous_allowed?(conn.remote_ip, Testor.Config.anonymous()) or public?(conn) ->
        assign(conn, :principal, Auth.anonymous())

      true ->
        exposed(conn)
    end
  end

  @doc """
  Whether a client at `ip` is answered while authentication is off (`TESTOR_ANONYMOUS`):
  `"private"` loopback, private, link-local and Tailscale addresses; `"loopback"`; `"any"`.
  """
  def anonymous_allowed?(_ip, "any"), do: true
  def anonymous_allowed?(ip, "loopback"), do: Testor.Net.loopback?(ip)
  def anonymous_allowed?(ip, _private), do: Testor.Net.private?(ip)

  defp exposed(conn) do
    address = conn.remote_ip |> :inet.ntoa() |> to_string()
    mode = Testor.Config.anonymous()
    Logger.warning("auth: refused #{address}: authentication is off and TESTOR_ANONYMOUS=#{mode}")

    conn
    |> Reply.error(
      403,
      "authentication_off",
      "authentication is off, so testor answers #{mode} addresses only: add a user (task testor:user) or set TESTOR_ANONYMOUS=any"
    )
    |> halt()
  end

  defp authenticate(conn, settings) do
    public = public?(conn)
    conn = fetch_cookies(conn)
    password_login = conn.path_info == [] and conn.query_string == "basic"
    basic = settings.oidc == nil or password_login

    case credentials(conn, settings) do
      {:ok, principal} ->
        conn = assign(conn, :principal, principal)
        if public, do: conn, else: authorize(conn, principal)

      _ when public ->
        assign(conn, :principal, Auth.public())

      :none when conn.method == "GET" and conn.path_info == [] and not basic ->
        conn |> put_resp_header("location", "/auth/login") |> send_resp(302, "") |> halt()

      :none ->
        unauthorized(conn, nil, "authentication required: Basic credentials or a Bearer token", basic)

      {:error, {:rate_limited, seconds}} ->
        conn
        |> put_resp_header("retry-after", to_string(seconds))
        |> Reply.error(429, "rate_limited", "too many failed attempts; try again in #{seconds} s")
        |> halt()

      {:error, :busy} ->
        conn
        |> put_resp_header("retry-after", "1")
        |> Reply.error(503, "busy", "too many sign-ins at once; try again in a second")
        |> halt()

      {:error, :expired} ->
        unauthorized(conn, "invalid_token", "the token has expired", basic)

      {:error, :revoked} ->
        unauthorized(conn, "invalid_token", "the token has been revoked", basic)

      {:error, :invalid_token} ->
        unauthorized(conn, "invalid_token", "the token is not valid", basic)

      {:error, _} ->
        unauthorized(conn, nil, "invalid credentials", basic)
    end
  end

  defp credentials(conn, settings) do
    address = conn.remote_ip |> :inet.ntoa() |> to_string()

    case get_req_header(conn, "authorization") do
      [value] ->
        case String.split(value, " ", parts: 2) do
          [scheme, rest] ->
            case String.downcase(scheme) do
              "basic" -> basic(settings, String.trim(rest), address)
              "bearer" -> Auth.bearer(settings, String.trim(rest), address)
              _ -> {:error, :scheme}
            end

          _ ->
            {:error, :scheme}
        end

      [] ->
        session(conn, settings)

      _ ->
        {:error, :scheme}
    end
  end

  # A dashboard session (Testor.Auth.OIDC). One that has expired or ended is no credentials.
  defp session(conn, settings) do
    with token when is_binary(token) <- conn.req_cookies[OIDC.session_cookie()],
         {:ok, principal} <- OIDC.session(settings, token) do
      {:ok, principal}
    else
      _ -> :none
    end
  end

  defp basic(settings, encoded, address) do
    with {:ok, decoded} <- Base.decode64(encoded),
         [name, password] <- :binary.split(decoded, ":") do
      Auth.basic(settings, name, password, address)
    else
      _ -> {:error, :malformed}
    end
  end

  defp authorize(conn, principal) do
    scope = required_scope(conn)

    if scope in principal.scopes do
      conn
    else
      conn
      |> Reply.error(403, "forbidden", "#{Auth.who(principal)} lacks the #{scope} scope")
      |> halt()
    end
  end

  @doc "The scope a request needs."
  def required_scope(%Plug.Conn{method: method, path_info: path}) do
    case {method, path} do
      {"POST", ["api", "maintenance", "clean"]} -> "maintain"
      {"POST", ["api", "v1", "maintenance", "clean"]} -> "maintain"
      {"GET", ["api", "v1", "audit"]} -> "maintain"
      {"POST", ["api", "v1", "jobs"]} -> "execute"
      {"POST", ["api", "v1", "jobs", _, "cancel"]} -> "execute"
      {"POST", ["api", "v1", "projects", _, "snapshots"]} -> "execute"
      {"PUT", ["api", "v1", "blobs", _]} -> "execute"
      {_, ["api", "v1", "agent" | _]} -> "agent"
      {"POST", ["api", "v1", "auth", "token"]} -> "read"
      {"POST", ["mcp"]} -> "read"
      {method, _} when method in @unsafe -> "operate"
      _ -> "read"
    end
  end

  @doc "Whether a request may go without credentials."
  def public?(%Plug.Conn{method: method, path_info: path}) when method in ["GET", "HEAD"] do
    case path do
      ["api", "health"] -> true
      ["api", "v1", "health"] -> true
      ["api", "v1", "openapi.json"] -> true
      [".well-known", "jwks.json"] -> true
      [".well-known", "openid-configuration"] -> true
      ["auth", page] when page in ["login", "callback", "signed-out"] -> true
      ["s", _cap, area | _] when area in ["shots", "artifacts"] -> true
      ["api", "v1", "projects", project, "badge.svg"] -> Testor.Badge.public?(project)
      _ -> false
    end
  end

  def public?(%Plug.Conn{method: "POST", path_info: ["auth", "logout"]}), do: true
  def public?(_conn), do: false

  # Basic comes first: browsers prompt for the first scheme they support.
  defp unauthorized(conn, error, message, basic) do
    bearer = if error, do: ~s(Bearer realm="testor", error="#{error}"), else: ~s(Bearer realm="testor")
    basic = if basic, do: [{"www-authenticate", ~s(Basic realm="testor", charset="UTF-8")}], else: []

    conn
    |> prepend_resp_headers(basic ++ [{"www-authenticate", bearer}])
    |> Reply.error(401, "unauthorized", message)
    |> halt()
  end

  @doc """
  Refuses a state-changing request a browser could have been tricked into sending: one from
  another origin (an `Origin` header that is not this server's, including the `null` origin of
  a sandboxed artifact), or one with neither a Bearer token, the `X-Testor: 1` header nor a
  JSON body, which cross-site forms cannot send without a CORS preflight this server never
  grants. The token endpoint needs only the origin check: its answer cannot be read cross-site.
  """
  def csrf(%Plug.Conn{method: method} = conn, _opts) when method in @unsafe do
    cond do
      cross_origin?(conn) ->
        conn |> Reply.error(403, "cross_origin", "cross-origin request refused") |> halt()

      safe?(conn) ->
        conn

      true ->
        conn |> Reply.error(403, "csrf", "missing X-Testor header") |> halt()
    end
  end

  def csrf(conn, _opts), do: conn

  defp safe?(conn) do
    conn.path_info == ["api", "v1", "auth", "token"] or
      match?(%{via: :bearer}, conn.assigns[:principal]) or
      get_req_header(conn, "x-testor") == ["1"] or
      json?(conn)
  end

  @doc "Whether the request carries an `Origin` other than this server."
  def cross_origin?(conn) do
    case get_req_header(conn, "origin") do
      [] ->
        false

      [origin | _] ->
        uri = URI.parse(origin)

        host =
          case get_req_header(conn, "host") do
            [value | _] -> String.downcase(value)
            [] -> if conn.port in [80, 443], do: conn.host, else: "#{conn.host}:#{conn.port}"
          end

        default = if uri.scheme == "https", do: 443, else: 80

        name = if is_binary(uri.host) and String.contains?(uri.host, ":"), do: "[#{uri.host}]", else: uri.host
        authority = if uri.port in [nil, default], do: name, else: "#{name}:#{uri.port}"

        uri.host == nil or String.downcase(authority) != strip_default_port(host, default)
    end
  end

  defp strip_default_port(host, default), do: String.replace_suffix(host, ":#{default}", "")

  defp json?(conn) do
    case get_req_header(conn, "content-type") do
      [type | _] -> type |> String.downcase() |> String.starts_with?("application/json")
      _ -> false
    end
  end

  @doc "Logs who sent a state-changing request and how it ended."
  def audit(%Plug.Conn{method: method} = conn, _opts) when method in @unsafe do
    register_before_send(conn, fn conn ->
      who = conn.assigns |> Map.get(:principal, %{sub: nil, via: :unknown}) |> Auth.who()
      address = conn.remote_ip |> :inet.ntoa() |> to_string()
      Logger.info("audit: #{who} from #{address}: #{conn.method} #{conn.request_path} -> #{conn.status}")

      Testor.Audit.record("request", %{
        "who" => who,
        "from" => address,
        "method" => conn.method,
        "path" => conn.request_path,
        "status" => conn.status,
        "requestId" => conn |> get_resp_header("x-request-id") |> List.first()
      })

      conn
    end)
  end

  def audit(conn, _opts), do: conn
end
