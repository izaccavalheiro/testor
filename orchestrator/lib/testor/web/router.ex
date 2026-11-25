defmodule Testor.Web.Router do
  @moduledoc """
  HTTP API and the dashboard page.

    GET    /                       the dashboard (priv/static/index.html)
    GET    /events                 SSE: the run list, sessions and stats, live
    GET    /events/runs/:id        SSE: one run's log, specs and screenshots, live
    GET    /metrics                Prometheus metrics (Testor.Metrics)
    GET    /api/health             liveness and versions
    GET    /api/state              everything /events starts with
    GET    /api/runs/:id           one run, its specs and screenshots
    GET    /api/runs/:id/log       its output as text (?tail=bytes)
    GET    /api/screenshots        every screenshot, newest first
    GET    /api/artifacts          every run's artifacts, newest run first
    GET    /api/device             device stats: static facts, latest sample, history
    POST   /api/runs/:id/cancel    kills a running run's process tree
    DELETE /api/runs/:id           deletes a finished run, its log and screenshots
    POST   /api/cleanup            runs the janitor now
    GET    /api/maintenance        the last maintenance scan and whether cleaning is enabled
    POST   /api/maintenance/scan   measures the maintenance targets (in the background)
    POST   /api/maintenance/clean  cleans the chosen targets of the last scan
    GET    /shots/<run>/<path>     a screenshot
    GET    /artifacts/<run>/<path> an artifact (byte ranges for videos), in a sandbox
    GET    /s/<sig>/shots/...      the same, through a signed link (while authentication is on)
    GET    /s/<sig>/artifacts/...
    *      /api/v1/...             the versioned API (Testor.Web.ApiV1)
    POST   /mcp                    the MCP server (Testor.Web.MCP)

  Every request passes `Testor.Web.Edge` first (the client's address behind trusted proxies, the
  `Host` allow-list), then `Testor.Web.Auth`: authentication and scopes (once `auth.json`
  has users), the CSRF guard (POST and DELETE need a Bearer token, the header `X-Testor: 1` or
  a JSON body, and no foreign `Origin`), and an audit line for each state-changing request.

  Artifacts are written by the projects' tools (HTML reports run scripts), so they are served
  with `Content-Security-Policy: sandbox`: a page gets an opaque origin, its requests to the API
  are cross-origin and cannot carry `X-Testor` without that preflight. It may still read other
  artifacts (`Access-Control-Allow-Origin: *`, which reports that fetch their data need):
  while authentication is off, everything is readable anyway; once it is on, a report reached
  through its signed link has no credentials and can read its own run's files only.
  """
  use Plug.Router
  import Testor.Web.Reply
  alias Testor.{Auth, Config, Files, Janitor, Maintenance, Views}
  alias Testor.Web.{Actions, SSE}

  plug(Plug.RequestId)
  plug(:security_headers)
  plug(Testor.Web.Edge)
  plug(Testor.Web.Auth)
  plug(:csrf)
  plug(:audit)
  plug(:match)
  plug(:dispatch)

  forward("/api/v1", to: Testor.Web.ApiV1)
  forward("/mcp", to: Testor.Web.MCP)

  get "/" do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("x-frame-options", "DENY")
    |> put_resp_header("content-security-policy", "frame-ancestors 'none'")
    |> put_resp_content_type("text/html")
    |> send_file(200, Application.app_dir(:testor, "priv/static/index.html"))
  end

  get "/events" do
    SSE.global(conn)
  end

  get "/events/runs/:id" do
    with_id(conn, id, &SSE.run(&1, id))
  end

  get "/metrics" do
    conn
    |> put_resp_content_type("text/plain; version=0.0.4", nil)
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(200, Testor.Metrics.render())
  end

  get "/api/health" do
    json(conn, 200, Views.health(conn.assigns[:principal]))
  end

  get "/api/state" do
    json(conn, 200, Views.state())
  end

  get "/api/device" do
    json(conn, 200, Testor.Device.snapshot())
  end

  get "/api/screenshots" do
    json(conn, 200, Views.screenshots_all())
  end

  get "/api/artifacts" do
    json(conn, 200, Views.artifacts_all())
  end

  post "/api/cleanup" do
    json(conn, 200, Janitor.run("manual"))
  end

  get "/api/maintenance" do
    json(conn, 200, Maintenance.state())
  end

  post "/api/maintenance/scan" do
    json(conn, 202, Maintenance.scan())
  end

  post "/api/maintenance/clean" do
    case body_params(conn) do
      {:ok, params, conn} -> reply(conn, Actions.maintenance_clean(params), 202)
      {:error, conn} -> conn
    end
  end

  get "/api/runs/:id/log" do
    with_id(conn, id, fn conn ->
      conn = fetch_query_params(conn)

      bytes =
        case Integer.parse(conn.query_params["tail"] || "") do
          {n, ""} when n > 0 -> min(n, Testor.Query.max_tail())
          _ -> 512 * 1024
        end

      log = Files.tail(Config.log_file(id), bytes)

      conn
      |> put_resp_header("x-log-size", to_string(log.size))
      |> put_resp_header("x-log-truncated", to_string(log.truncated))
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_content_type("text/plain")
      |> send_resp(200, log.text)
    end)
  end

  get "/api/runs/:id" do
    with_id(conn, id, fn conn ->
      case Views.run_snapshot(id) do
        nil -> json(conn, 404, %{"error" => "no such run"})
        snapshot -> json(conn, 200, snapshot)
      end
    end)
  end

  post "/api/runs/:id/cancel" do
    with_id(conn, id, &reply(&1, Actions.cancel(id), 200))
  end

  delete "/api/runs/:id" do
    with_id(conn, id, &reply(&1, Actions.delete(id), 200))
  end

  get "/shots/*path" do
    serve_shot(conn, path)
  end

  get "/artifacts/*path" do
    serve_artifact(conn, path)
  end

  get "/s/:cap/shots/*path" do
    signed(conn, cap, path, &serve_shot/2)
  end

  get "/s/:cap/artifacts/*path" do
    signed(conn, cap, path, &serve_artifact/2)
  end

  match _ do
    json(conn, 404, %{"error" => "not found"})
  end

  # --- helpers -------------------------------------------------------------------------------

  def csrf(conn, opts), do: Testor.Web.Auth.csrf(conn, opts)
  def audit(conn, opts), do: Testor.Web.Auth.audit(conn, opts)

  def security_headers(conn, _opts) do
    conn
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("referrer-policy", "no-referrer")
    |> hsts()
  end

  # Served over HTTPS (TESTOR_TLS_CERT): browsers keep to HTTPS for a year.
  defp hsts(%Plug.Conn{scheme: :https} = conn),
    do: put_resp_header(conn, "strict-transport-security", "max-age=31536000")

  defp hsts(conn), do: conn

  # A signed link opens the files of the run (or the loose screenshot) its first segment names.
  defp signed(conn, cap, [first | _] = segments, serve) do
    if Auth.file_cap_valid?(cap, first),
      do: serve.(conn, segments),
      else: error(conn, 404, "not_found", "not found")
  end

  defp signed(conn, _cap, _segments, _serve), do: error(conn, 404, "not_found", "not found")

  defp reply(conn, {:ok, data}, status), do: json(conn, status, data)
  defp reply(conn, {:error, status, code, message}, _), do: error(conn, status, code, message)

  defp with_id(conn, id, fun) do
    if valid_id?(id), do: fun.(conn), else: error(conn, 400, "bad_request", "bad id")
  end

  defp serve_shot(conn, segments) do
    full = inside(Config.shots_dir(), segments)
    type = full && Files.image_type(full)

    if type != nil and File.regular?(full) do
      conn
      |> put_resp_content_type(type, nil)
      |> put_resp_header("cache-control", "max-age=3600")
      |> put_resp_header("x-content-type-options", "nosniff")
      |> send_file(200, full)
    else
      json(conn, 404, %{"error" => "not found"})
    end
  end

  defp serve_artifact(conn, segments) do
    full = inside(Config.artifacts_dir(), segments)

    case full && File.stat(full) do
      {:ok, %{type: :regular, size: size}} ->
        conn =
          conn
          |> put_resp_header("content-security-policy", "sandbox allow-scripts allow-popups allow-downloads")
          |> put_resp_header("x-content-type-options", "nosniff")
          |> put_resp_header("referrer-policy", "no-referrer")
          |> put_resp_header("access-control-allow-origin", "*")
          |> put_resp_header("accept-ranges", "bytes")
          |> put_resp_header("cache-control", "max-age=3600")

        conn =
          case Files.served_type(full) do
            nil ->
              conn
              |> put_resp_content_type("application/octet-stream", nil)
              |> put_resp_header("content-disposition", ~s(attachment; filename="#{download_name(full)}"))

            type ->
              put_resp_content_type(conn, type, nil)
          end

        case Files.parse_range(conn |> get_req_header("range") |> List.first(), size) do
          :all ->
            send_file(conn, 200, full)

          {offset, length} ->
            conn
            |> put_resp_header("content-range", "bytes #{offset}-#{offset + length - 1}/#{size}")
            |> send_file(206, full, offset, length)

          :unsatisfiable ->
            conn |> put_resp_header("content-range", "bytes */#{size}") |> send_resp(416, "")
        end

      _ ->
        json(conn, 404, %{"error" => "not found"})
    end
  end

  # The file the URL segments name under `root`, or nil when they would leave it, by name or
  # through a symbolic link a run left there.
  defp inside(root, segments) do
    root = Path.expand(root)
    full = Path.expand(Path.join([root | segments]))

    safe =
      segments != [] and
        Enum.all?(segments, &(&1 not in ["", ".", ".."] and not String.contains?(&1, ["/", "\\", ":"])))

    if safe and String.starts_with?(full, root <> "/") and Files.no_links?(root, segments), do: full
  end

  defp download_name(path), do: path |> Path.basename() |> String.replace(~r/[^\w.-]/u, "_")
end
