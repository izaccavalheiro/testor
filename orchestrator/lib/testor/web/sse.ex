defmodule Testor.Web.SSE do
  @moduledoc """
  Server-sent event streams. Each starts with a `snapshot` event and then forwards the events
  of its topic as they happen; a comment every 15 s keeps proxies from closing it and shows a
  closed browser, which ends the stream. A browser reconnects on its own (`retry: 3000`) and
  gets a fresh snapshot, so no event id bookkeeping is needed.

    * `GET /events`: `snapshot`, `run`, `live`, `run_removed`, `sessions`, `stats`, `device`,
      `device_static`, `maintenance`
    * `GET /events/runs/:id`: `snapshot`, `log`, `specs`, `run`, `screenshots`, `artifacts`,
      `removed`
  """
  import Plug.Conn
  alias Testor.{Device, Events, Sessions, Views}

  @heartbeat 15_000

  def global(conn) do
    # Subscribe before the snapshot: an event in between is applied twice, never lost, and
    # the browser applies events idempotently.
    Events.subscribe("global")
    Sessions.poke()
    Device.poke()
    conn |> open() |> send_then_loop(Views.state(), nil)
  end

  def run(conn, id) do
    Events.subscribe({"run", id})

    case Views.run_snapshot(id) do
      nil ->
        conn |> put_resp_content_type("application/json") |> send_resp(404, ~s({"error":"no such run"}))

      snapshot ->
        conn |> open() |> send_then_loop(snapshot, snapshot["logBytes"])
    end
  end

  defp open(conn) do
    conn
    |> put_resp_header("content-type", "text/event-stream; charset=utf-8")
    |> put_resp_header("cache-control", "no-cache")
    |> put_resp_header("x-accel-buffering", "no")
    |> send_chunked(200)
  end

  defp send_then_loop(conn, snapshot, offset) do
    conn
    |> chunk(["retry: 3000\n\n" | event("snapshot", snapshot)])
    |> continue(conn, offset)
  end

  defp loop(conn, offset) do
    receive do
      # Lines the snapshot already held.
      {:event, "log", %{"to" => to}} when is_integer(offset) and to <= offset ->
        loop(conn, offset)

      {:event, name, data} ->
        conn |> chunk(event(name, data)) |> continue(conn, offset)
    after
      Application.get_env(:testor, :sse_heartbeat_ms, @heartbeat) ->
        conn |> chunk(": ping\n\n") |> continue(conn, offset)
    end
  end

  # A chunk that cannot be sent is a browser that went away: the stream ends.
  defp continue({:ok, conn}, _previous, offset), do: loop(conn, offset)
  defp continue({:error, _}, conn, _offset), do: conn

  defp event(name, data), do: ["event: ", name, "\ndata: ", JSON.encode!(data), "\n\n"]
end
