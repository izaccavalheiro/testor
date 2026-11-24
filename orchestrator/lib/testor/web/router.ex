defmodule Testor.Web.Router do
  @moduledoc """
  HTTP API and the dashboard page.

    GET    /                       the dashboard (priv/static/index.html)
    GET    /events                 SSE: the run list, sessions and stats, live
    GET    /events/runs/:id        SSE: one run's log, specs and screenshots, live
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

  POST and DELETE need the header `X-Testor: 1`: a cross-site form cannot send it without
  a CORS preflight, which this server never grants.

  Artifacts are written by the projects' tools (HTML reports run scripts), so they are served
  with `Content-Security-Policy: sandbox`: a page gets an opaque origin, its requests to the API
  are cross-origin and cannot carry `X-Testor` without that preflight. It may still read other
  artifacts (`Access-Control-Allow-Origin: *`, which reports that fetch their data need), and
  everything they could read is readable without authentication anyway.
  """
  use Plug.Router
  alias Testor.{Config, Files, Janitor, Maintenance, Store, Views}
  alias Testor.Web.SSE

  plug(:guard)
  plug(:match)
  plug(:dispatch)

  get "/" do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_content_type("text/html")
    |> send_file(200, Application.app_dir(:testor, "priv/static/index.html"))
  end

  get "/events" do
    SSE.global(conn)
  end

  get "/events/runs/:id" do
    with_id(conn, id, &SSE.run(&1, id))
  end

  get "/api/health" do
    json(conn, 200, %{
      "ok" => true,
      "app" => "testor",
      "home" => Config.data_dir(),
      "version" => to_string(Application.spec(:testor, :vsn)),
      "elixir" => System.version(),
      "otp" => System.otp_release(),
      "uptimeMs" => :erlang.statistics(:wall_clock) |> elem(0),
      "os_pid" => System.pid()
    })
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
    {:ok, body, conn} = read_body(conn, length: 65_536)

    with {:ok, %{"scanId" => scan_id, "targets" => [_ | _] = targets}} <- JSON.decode(body),
         true <- Enum.all?(targets, &is_binary/1) do
      case Maintenance.clean(scan_id, targets) do
        {:ok, state} ->
          json(conn, 202, state)

        {:error, :disabled} ->
          json(conn, 403, %{"error" => "cleaning is off: set maintenance.enabled in config.json"})

        {:error, :busy} ->
          json(conn, 409, %{"error" => "a run, a session or a scan is in progress; try again when it ends"})

        {:error, :stale} ->
          json(conn, 409, %{"error" => "the scan changed; look at the new one and choose again"})

        {:error, {:unknown, ids}} ->
          json(conn, 400, %{"error" => "not in the scan: #{Enum.join(ids, ", ")}"})
      end
    else
      _ -> json(conn, 400, %{"error" => ~s(expected {"scanId": "...", "targets": ["..."]})})
    end
  end

  get "/api/runs/:id/log" do
    with_id(conn, id, fn conn ->
      conn = fetch_query_params(conn)

      bytes =
        case Integer.parse(conn.query_params["tail"] || "") do
          {n, ""} when n > 0 -> min(n, 64 * 1024 * 1024)
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
    with_id(conn, id, fn conn ->
      case Store.cancel(id) do
        {:ok, run} -> json(conn, 200, run)
        {:error, :not_found} -> json(conn, 404, %{"error" => "no such run"})
        {:error, :not_running} -> json(conn, 409, %{"error" => "the run is not running"})
      end
    end)
  end

  delete "/api/runs/:id" do
    with_id(conn, id, fn conn ->
      case Store.delete(id) do
        :ok -> json(conn, 200, %{"deleted" => id})
        {:error, :running} -> json(conn, 409, %{"error" => "the run is still running; cancel it first"})
      end
    end)
  end

  get "/shots/*path" do
    serve_shot(conn, path)
  end

  get "/artifacts/*path" do
    serve_artifact(conn, path)
  end

  match _ do
    json(conn, 404, %{"error" => "not found"})
  end

  # --- helpers -------------------------------------------------------------------------------

  def guard(%Plug.Conn{method: method} = conn, _opts) when method in ["POST", "DELETE"] do
    if get_req_header(conn, "x-testor") == ["1"] do
      conn
    else
      conn |> json(403, %{"error" => "missing X-Testor header"}) |> halt()
    end
  end

  def guard(conn, _opts), do: conn

  defp with_id(conn, id, fun) do
    if Regex.match?(~r/^[\w.-]+$/, id), do: fun.(conn), else: json(conn, 400, %{"error" => "bad id"})
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

  # The file the URL segments name under `root`, or nil when they would leave it.
  defp inside(root, segments) do
    root = Path.expand(root)
    full = Path.expand(Path.join([root | segments]))

    safe =
      segments != [] and
        Enum.all?(segments, &(&1 not in ["", ".", ".."] and not String.contains?(&1, ["/", "\\", ":"])))

    if safe and String.starts_with?(full, root <> "/"), do: full
  end

  defp download_name(path), do: path |> Path.basename() |> String.replace(~r/[^\w.-]/u, "_")

  defp json(conn, status, data) do
    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(status, JSON.encode!(data))
  end
end
