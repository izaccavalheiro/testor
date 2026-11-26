defmodule Testor.Test.FakeAzure do
  @moduledoc """
  Azure Blob Storage's REST API for the tests, path-style like Azurite
  (`/<account>/<container>/<blob>`), kept in memory: containers, blobs, blocks and block lists,
  `List Blobs` in pages of `page/1`, deletes (`lock/1` keys answer 409, as an immutability policy
  does), Shared Key signatures checked against `key/0`, `Content-MD5` checked against the body,
  bearer tokens accepted when they are `token/0`, and Microsoft Entra's token endpoint
  (`POST /<tenant>/oauth2/v2.0/token`). `fail/1` answers 500 to blob requests.
  """
  use Plug.Router
  plug(:match)
  plug(:dispatch)

  @agent __MODULE__.State
  @key Base.encode64("fake-azure-account-key-of-32-bytes!")

  def key, do: @key
  def token, do: "entra-access-token"

  def child, do: %{id: __MODULE__, start: {__MODULE__, :start_link, []}, type: :supervisor}

  def start_link do
    Supervisor.start_link(
      [
        %{id: :state, start: {Agent, :start_link, [&initial/0, [name: @agent]]}},
        {Bandit, plug: __MODULE__, ip: :loopback, port: 0, startup_log: false}
      ],
      strategy: :one_for_one,
      name: __MODULE__.Supervisor
    )
  end

  defp initial,
    do: %{blobs: %{}, blocks: %{}, locked: MapSet.new(), fail: false, page: 1000, tokens: 0, modified: nil}

  def endpoint do
    {_, pid, _, _} =
      __MODULE__.Supervisor |> Supervisor.which_children() |> Enum.find(&(elem(&1, 0) != :state))

    {:ok, {_, port}} = ThousandIsland.listener_info(pid)
    "http://127.0.0.1:#{port}"
  end

  def reset, do: Agent.update(@agent, fn _ -> initial() end)
  def fail(on), do: Agent.update(@agent, &%{&1 | fail: on})
  def page(n), do: Agent.update(@agent, &%{&1 | page: n})
  def lock(keys), do: Agent.update(@agent, &%{&1 | locked: MapSet.new(keys)})
  @doc "Listings show `value` as every blob's Last-Modified."
  def modified(value), do: Agent.update(@agent, &%{&1 | modified: value})
  def blobs, do: Agent.get(@agent, & &1.blobs)
  def tokens, do: Agent.get(@agent, & &1.tokens)

  post "/:tenant/oauth2/v2.0/token" do
    {:ok, body, conn} = read_body(conn)
    form = URI.decode_query(body)
    Agent.update(@agent, &%{&1 | tokens: &1.tokens + 1})

    if form["client_assertion"] == "federated-jwt" and form["scope"] == "https://storage.azure.com/.default" do
      send_resp(conn, 200, JSON.encode!(%{"access_token" => token(), "expires_in" => 3600}))
    else
      send_resp(conn, 401, ~s({"error": "invalid_client"}))
    end
  end

  match _ do
    {:ok, body, conn} = read_all(conn, "")
    conn = fetch_query_params(conn)
    state = Agent.get(@agent, & &1)

    cond do
      state.fail ->
        send_resp(conn, 500, "<Error><Code>InternalError</Code></Error>")

      not authorized?(conn, body) ->
        send_resp(conn, 403, "<Error><Code>AuthenticationFailed</Code></Error>")

      true ->
        [_account, _container | rest] = Enum.map(conn.path_info, &URI.decode/1)
        handle(conn, conn.method, Enum.join(rest, "/"), conn.query_params, body)
    end
  end

  defp read_all(conn, acc) do
    case read_body(conn) do
      {:ok, data, conn} -> {:ok, acc <> data, conn}
      {:more, data, conn} -> read_all(conn, acc <> data)
    end
  end

  # Shared Key as the service checks it, or the token Entra gave.
  defp authorized?(conn, body) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> token == token()
      ["SharedKey " <> rest] -> rest == "devstoreaccount1:" <> sign(conn, body)
      _ -> false
    end
  end

  defp sign(conn, body) do
    h = fn name -> conn |> get_req_header(name) |> List.first("") end
    length = if body == "", do: "", else: Integer.to_string(byte_size(body))

    headers =
      for({k, v} <- conn.req_headers, String.starts_with?(k, "x-ms-"), do: {k, String.trim(v)})
      |> Enum.sort()
      |> Enum.map_join("", fn {k, v} -> "#{k}:#{v}\n" end)

    params =
      conn.query_string
      |> URI.decode_query()
      |> Enum.sort()
      |> Enum.map_join("", fn {k, v} -> "\n#{k}:#{v}" end)

    to_sign =
      Enum.join(
        [conn.method, "", "", length, h.("content-md5"), h.("content-type"), "", "", "", "", "", ""],
        "\n"
      ) <>
        "\n" <> headers <> "/devstoreaccount1" <> conn.request_path <> params

    Base.encode64(:crypto.mac(:hmac, :sha256, Base.decode64!(@key), to_sign))
  end

  defp md5_ok?(conn, body) do
    case get_req_header(conn, "content-md5") do
      [md5] -> md5 == Base.encode64(:crypto.hash(:md5, body))
      [] -> true
    end
  end

  defp handle(conn, "PUT", "", %{"restype" => "container"}, _body), do: send_resp(conn, 201, "")

  defp handle(conn, "PUT", key, %{"comp" => "block", "blockid" => id}, body) do
    if md5_ok?(conn, body) do
      Agent.update(@agent, &put_in(&1, [:blocks, {key, id}], body))
      send_resp(conn, 201, "")
    else
      send_resp(conn, 400, "<Error><Code>Md5Mismatch</Code></Error>")
    end
  end

  defp handle(conn, "PUT", key, %{"comp" => "blocklist"}, body) do
    ids = for [_, id] <- Regex.scan(~r/<Latest>([^<]+)<\/Latest>/, body), do: id
    data = Agent.get(@agent, fn s -> Enum.map_join(ids, "", &Map.fetch!(s.blocks, {key, &1})) end)
    store(key, data, conn)
    send_resp(conn, 201, "")
  end

  defp handle(conn, "PUT", key, _query, body) do
    if md5_ok?(conn, body) do
      store(key, body, conn)
      send_resp(conn, 201, "")
    else
      send_resp(conn, 400, "<Error><Code>Md5Mismatch</Code></Error>")
    end
  end

  defp handle(conn, "GET", "", %{"comp" => "list"} = q, _body) do
    state = Agent.get(@agent, & &1)
    prefix = q["prefix"] || ""
    keys = state.blobs |> Map.keys() |> Enum.filter(&String.starts_with?(&1, prefix)) |> Enum.sort()
    keys = if q["marker"], do: Enum.filter(keys, &(&1 > q["marker"])), else: keys
    {shown, more} = Enum.split(keys, state.page)
    at = state.modified || "Thu, 26 Nov 2026 10:00:00 GMT"

    blobs =
      Enum.map_join(shown, "", fn key ->
        "<Blob><Name>#{key}</Name><Properties><Last-Modified>#{at}</Last-Modified><Content-Length>#{byte_size(state.blobs[key].data)}</Content-Length></Properties></Blob>"
      end)

    next = if more != [], do: "<NextMarker>#{List.last(shown)}</NextMarker>", else: "<NextMarker />"
    send_resp(conn, 200, "<EnumerationResults><Blobs>#{blobs}</Blobs>#{next}</EnumerationResults>")
  end

  defp handle(conn, method, key, _query, _body) when method in ["GET", "HEAD"] do
    case Agent.get(@agent, & &1.blobs[key]) do
      nil ->
        send_resp(conn, 404, "")

      blob ->
        conn
        |> put_resp_header("x-ms-meta-sha256", blob.sha256)
        |> put_resp_header("content-length", Integer.to_string(byte_size(blob.data)))
        |> send_resp(200, if(method == "HEAD", do: "", else: blob.data))
    end
  end

  defp handle(conn, "DELETE", key, _query, _body) do
    state = Agent.get(@agent, & &1)

    cond do
      MapSet.member?(state.locked, key) ->
        send_resp(conn, 409, "<Error><Code>BlobImmutableDueToPolicy</Code></Error>")

      Map.has_key?(state.blobs, key) ->
        Agent.update(@agent, &%{&1 | blobs: Map.delete(&1.blobs, key)})
        send_resp(conn, 202, "")

      true ->
        send_resp(conn, 404, "")
    end
  end

  defp store(key, data, conn) do
    sha = conn |> get_req_header("x-ms-meta-sha256") |> List.first()
    Agent.update(@agent, &put_in(&1, [:blobs, key], %{data: data, sha256: sha}))
  end
end
