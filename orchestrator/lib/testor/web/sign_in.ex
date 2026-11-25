defmodule Testor.Web.SignIn do
  @moduledoc """
  Sign-in to the dashboard with an OpenID Connect provider (`Testor.Auth.OIDC`).

    GET  /auth/login       to the provider (`?return=/path` comes back there)
    GET  /auth/callback    the provider's answer: a session cookie, back to the dashboard
    POST /auth/logout      ends the session (the cookie)
    GET  /auth/signed-out  says so

  `/?basic` signs in with a password instead (`Testor.Web.Auth`). A refused sign-in is logged,
  audited and counts as a failed attempt of the client's address.
  """
  use Plug.Router
  require Logger
  alias Testor.Auth
  alias Testor.Auth.{Guard, OIDC}

  plug(:match)
  plug(:dispatch)

  get "/login" do
    settings = Auth.settings()
    conn = fetch_query_params(conn)

    with %{} <- provider(settings),
         {:ok, url, cookie} <- OIDC.login(settings, conn.query_params["return"]) do
      conn
      |> put_resp_cookie(OIDC.login_cookie(), cookie, cookie_options(settings.oidc, "/auth", 600))
      |> redirect(url)
    else
      nil ->
        no_provider(conn)

      {:error, why} ->
        Logger.error("auth: oidc: #{why}")

        page(
          conn,
          502,
          "Sign-in is unavailable",
          "The identity provider cannot be reached. Try again in a minute."
        )
    end
  end

  get "/callback" do
    settings = Auth.settings()
    conn = conn |> fetch_query_params() |> fetch_cookies()
    address = conn.remote_ip |> :inet.ntoa() |> to_string()

    with %{} = oidc <- provider(settings),
         :ok <- Guard.check(address),
         {:ok, signed_in} <- OIDC.callback(settings, conn.query_params, conn.req_cookies[OIDC.login_cookie()]) do
      Logger.info("auth: #{signed_in.user} signed in as #{signed_in.role} from #{address}")
      Testor.Audit.record("sign_in", %{"who" => signed_in.user, "role" => signed_in.role, "from" => address})

      conn
      |> delete_resp_cookie(OIDC.login_cookie(), path: "/auth")
      |> put_resp_cookie(
        OIDC.session_cookie(),
        signed_in.session,
        cookie_options(oidc, "/", signed_in.max_age)
      )
      |> redirect(signed_in.return)
    else
      nil ->
        no_provider(conn)

      {:blocked, seconds} ->
        conn
        |> put_resp_header("retry-after", to_string(seconds))
        |> page(429, "Too many attempts", "Try again in #{seconds} seconds.")

      {:error, why} ->
        Guard.failed(address)
        Logger.warning("auth: sign-in refused from #{address}: #{why}")
        Testor.Audit.record("auth_failed", %{"from" => address, "why" => why})

        conn
        |> delete_resp_cookie(OIDC.login_cookie(), path: "/auth")
        |> page(403, "Sign-in refused", why <> ".", {"/auth/login", "Try again"})
    end
  end

  post "/logout" do
    conn
    |> delete_resp_cookie(OIDC.session_cookie(), path: "/")
    |> Testor.Web.Reply.json(200, %{"signedOut" => true})
  end

  get "/signed-out" do
    link = if provider(Auth.settings()), do: {"/auth/login", "Sign in again"}, else: {"/", "Back to testor"}
    page(conn, 200, "Signed out", "You are signed out of testor.", link)
  end

  match _ do
    page(conn, 404, "Not found", "There is no such page.")
  end

  defp provider(%{enabled: true, oidc: %{} = oidc}), do: oidc
  defp provider(_settings), do: nil

  defp no_provider(conn) do
    page(
      conn,
      404,
      "Sign-in is not set up",
      "testor has no identity provider.",
      {"/?basic", "Sign in with a password"}
    )
  end

  defp cookie_options(oidc, path, max_age),
    do: [http_only: true, secure: oidc.secure, same_site: "Lax", path: path, max_age: max_age]

  defp redirect(conn, url) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("location", url)
    |> send_resp(302, "")
  end

  defp page(conn, status, title, message, link \\ nil) do
    link =
      case link do
        {href, text} -> ~s(<p><a href="#{href}">#{text}</a></p>)
        nil -> ""
      end

    html = """
    <!doctype html>
    <html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
    <title>#{title} · testor</title></head>
    <body style="font: 15px system-ui, sans-serif; max-width: 34rem; margin: 15vh auto; padding: 0 16px">
    <h1 style="font-size: 20px">#{title}</h1><p>#{Plug.HTML.html_escape(message)}</p>#{link}</body></html>
    """

    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header(
      "content-security-policy",
      "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'"
    )
    |> put_resp_content_type("text/html")
    |> send_resp(status, html)
  end
end
