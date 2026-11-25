defmodule Testor.Web.Edge do
  @moduledoc """
  The first plug of every request, before authentication:

    * the client's address: behind a reverse proxy listed in `TESTOR_TRUSTED_PROXIES`, the
      address `X-Forwarded-For` names (read from the right, skipping trusted proxies), so rate
      limiting, the audit log and the anonymous-access check see the client, not the proxy;
    * the `Host` allow-list (`Testor.Net.host_allowed?/3`): a request for a name that is not
      this machine's is refused with `421`, which stops DNS rebinding, where a page on another
      site resolves its own name to this server to read it as same-origin.
  """
  import Plug.Conn
  require Logger
  alias Testor.{Config, Net}
  alias Testor.Web.Reply

  def init(opts), do: opts

  def call(conn, _opts) do
    conn = %{
      conn
      | remote_ip:
          Net.client_ip(conn.remote_ip, get_req_header(conn, "x-forwarded-for"), Config.trusted_proxies())
    }

    if Net.host_allowed?(conn.host, Net.machine_names(), Config.allowed_hosts()) do
      conn
    else
      Logger.warning(
        "edge: refused Host #{inspect(conn.host)} from #{conn.remote_ip |> :inet.ntoa() |> to_string()}"
      )

      conn
      |> Reply.error(
        421,
        "misdirected",
        "this server does not answer for #{conn.host}; add it to TESTOR_ALLOWED_HOSTS"
      )
      |> halt()
    end
  end
end
