defmodule Testor.Web.AcmeHttp do
  @moduledoc """
  The plain-HTTP listener of ACME's HTTP-01 challenges (`tls.acme.httpPort`, `Testor.Acme`):
  `GET /.well-known/acme-challenge/<token>` answers the key authorization of an order in
  progress (404 otherwise), and any other request to one of the certificate's names is
  redirected to HTTPS. Requests for other names get 404, so it is not an open redirect.
  """
  @behaviour Plug
  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{path_info: [".well-known", "acme-challenge", token]} = conn, _opts) do
    case Testor.Acme.challenge(token) do
      nil -> send_resp(conn, 404, "not found")
      key_authorization -> conn |> put_resp_content_type("text/plain") |> send_resp(200, key_authorization)
    end
  end

  def call(conn, _opts) do
    cfg = Testor.Acme.config()
    host = String.downcase(conn.host)

    if cfg && host in cfg.domains do
      port = Application.fetch_env!(:testor, :port)
      authority = if port == 443, do: host, else: "#{host}:#{port}"
      query = if conn.query_string == "", do: "", else: "?" <> conn.query_string

      conn
      |> put_resp_header("location", "https://#{authority}#{conn.request_path}#{query}")
      |> send_resp(301, "")
    else
      send_resp(conn, 404, "not found")
    end
  end
end
