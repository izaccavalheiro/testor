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
    admit(conn, fn conn ->
      # Subscribe before the snapshot: an event in between is applied twice, never lost, and
      # the browser applies events idempotently.
      Events.subscribe("global")
      Sessions.poke()
      Device.poke()
      conn |> open() |> send_then_loop(Testor.Access.state(Views.state(), conn.assigns[:principal]), nil)
    end)
  end

  def run(conn, id) do
    admit(conn, fn conn ->
      Events.subscribe({"run", id})

      case Views.run_snapshot(id) do
        nil ->
          conn |> put_resp_content_type("application/json") |> send_resp(404, ~s({"error":"no such run"}))

        snapshot ->
          conn |> open() |> send_then_loop(snapshot, snapshot["logBytes"])
      end
    end)
  end

  @doc """
  Streams hold a process and a connection each for as long as the client wants: at most
  `max_streams` (#{256}) at once, and `max_streams_per_client` (#{16}) per user, or per address
  without authentication. Beyond that a stream is refused with `503` and `Retry-After`.
  """
  def admit(conn, fun) do
    client =
      case conn.assigns[:principal] do
        %{sub: sub} when is_binary(sub) -> {:user, sub}
        _ -> {:address, conn.remote_ip}
      end

    total = Registry.count(Testor.StreamRegistry)
    mine = Testor.StreamRegistry |> Registry.lookup(client) |> length()

    if total < limit(:max_streams, 256) and mine < limit(:max_streams_per_client, 16) do
      {:ok, _} = Registry.register(Testor.StreamRegistry, client, nil)

      # A connection serves later requests once its stream ends (keep-alive): it counts no more.
      try do
        fun.(conn)
      after
        Registry.unregister(Testor.StreamRegistry, client)
      end
    else
      conn
      |> put_resp_header("retry-after", "10")
      |> Testor.Web.Reply.error(
        503,
        "too_many_streams",
        "too many event streams are open; close some and try again"
      )
    end
  end

  defp limit(key, default), do: Application.get_env(:testor, key, default)

  defp open(conn) do
    conn
    |> put_resp_header("content-type", "text/event-stream; charset=utf-8")
    |> put_resp_header("cache-control", "no-cache")
    |> put_resp_header("x-accel-buffering", "no")
    |> send_chunked(200)
  end

  defp send_then_loop(conn, snapshot, offset) do
    conn
    |> chunk(["retry: 3000\n\n" | event(conn, "snapshot", snapshot)])
    |> continue(conn, offset)
  end

  defp loop(conn, offset) do
    receive do
      # Lines the snapshot already held.
      {:event, "log", %{"to" => to}} when is_integer(offset) and to <= offset ->
        loop(conn, offset)

      {:event, name, data} ->
        # Events of projects this stream's principal may not see are left out (Testor.Access).
        if Testor.Access.event?(conn.assigns[:principal], name, data),
          do: conn |> chunk(event(conn, name, data)) |> continue(conn, offset),
          else: loop(conn, offset)
    after
      Application.get_env(:testor, :sse_heartbeat_ms, @heartbeat) ->
        conn |> chunk(": ping\n\n") |> continue(conn, offset)
    end
  end

  # A chunk that cannot be sent is a browser that went away: the stream ends.
  defp continue({:ok, conn}, _previous, offset), do: loop(conn, offset)
  defp continue({:error, _}, conn, _offset), do: conn

  # File links in the data are bound to this stream's principal as each event is sent, so they
  # are fresh (Testor.Auth.Links).
  defp event(conn, name, data) do
    data = data |> JSON.encode!() |> Testor.Auth.bind_links(conn.assigns[:principal])
    ["event: ", name, "\ndata: ", data, "\n\n"]
  end
end
