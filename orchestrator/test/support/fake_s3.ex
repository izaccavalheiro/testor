defmodule Testor.Test.FakeS3 do
  @moduledoc """
  An S3 API for the tests, path-style (`/<bucket>/<key>`), kept in memory: objects, multipart
  uploads, `ListObjectsV2` in pages of `page/1` keys, `DeleteObjects` (keys `lock/1` names are
  refused, as Object Lock does) and presigned GETs. Every request must be signed (an
  `Authorization` header, or `X-Amz-Signature` in the query); a checksum that does not match
  the body is refused with `BadDigest`. `fail/1` answers 500 to everything.
  It is started once, beside the server (test_helper.exs); `reset/0` empties it.
  """
  use Plug.Router
  plug(:match)
  plug(:dispatch)

  @agent __MODULE__.State

  @doc "Its child spec: the state and the server, under a supervisor of their own."
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
    do: %{
      objects: %{},
      uploads: %{},
      locked: MapSet.new(),
      fail: false,
      fail_parts: false,
      answer: nil,
      page: 1000,
      log: []
    }

  def endpoint do
    {_, pid, _, _} =
      __MODULE__.Supervisor |> Supervisor.which_children() |> Enum.find(&(elem(&1, 0) != :state))

    {:ok, {_, port}} = ThousandIsland.listener_info(pid)
    "http://127.0.0.1:#{port}"
  end

  def reset, do: Agent.update(@agent, fn _ -> initial() end)
  def fail(on), do: Agent.update(@agent, &%{&1 | fail: on})
  @doc "Parts of multipart uploads answer 500 (`true`), or the completion 200 with an error (`:complete`)."
  def fail_parts(how), do: Agent.update(@agent, &%{&1 | fail_parts: how})
  @doc "Answers of its own: `fun.(method, key, query)` returns `{status, body}`, or nil to go on."
  def answer(fun), do: Agent.update(@agent, &%{&1 | answer: fun})
  def page(n), do: Agent.update(@agent, &%{&1 | page: n})
  def lock(keys), do: Agent.update(@agent, &%{&1 | locked: MapSet.new(keys)})
  def objects, do: Agent.get(@agent, & &1.objects)
  def keys, do: objects() |> Map.keys() |> Enum.sort()
  def object(key), do: objects()[key]

  def put_object(key, data),
    do: Agent.update(@agent, &put_in(&1, [:objects, key], %{data: data, headers: []}))

  @doc "The requests seen: `{method, path, query, headers}`, oldest first."
  def requests, do: Agent.get(@agent, &Enum.reverse(&1.log))

  # --- the API -------------------------------------------------------------------------------

  match _ do
    conn = fetch_query_params(conn)

    Agent.update(
      @agent,
      &%{&1 | log: [{conn.method, conn.request_path, conn.query_string, conn.req_headers} | &1.log]}
    )

    cond do
      Agent.get(@agent, & &1.fail) ->
        send_resp(conn, 500, "<Error><Code>InternalError</Code></Error>")

      get_req_header(conn, "authorization") == [] and conn.query_params["X-Amz-Signature"] == nil ->
        send_resp(conn, 403, "<Error><Code>AccessDenied</Code></Error>")

      true ->
        {:ok, body, conn} = read_all(conn, "")
        [_bucket | rest] = Enum.map(conn.path_info, &URI.decode/1)
        key = Enum.join(rest, "/")
        answer = Agent.get(@agent, & &1.answer)

        case answer && answer.(conn.method, key, conn.query_params) do
          {status, text} -> send_resp(conn, status, text)
          nil -> handle(conn, conn.method, key, conn.query_params, body)
        end
    end
  end

  defp handle(conn, "GET", "", %{"list-type" => "2"} = q, _body) do
    prefix = q["prefix"] || ""
    page = Agent.get(@agent, & &1.page)
    after_key = q["continuation-token"]

    keys =
      keys()
      |> Enum.filter(&String.starts_with?(&1, prefix))
      |> Enum.filter(&(after_key == nil or &1 > after_key))

    {shown, more} = Enum.split(keys, page)

    contents =
      Enum.map_join(shown, "", fn key ->
        "<Contents><Key>#{escape(key)}</Key><Size>#{byte_size(object(key).data)}</Size></Contents>"
      end)

    next =
      if more != [],
        do: "<NextContinuationToken>#{escape(List.last(shown))}</NextContinuationToken>",
        else: ""

    send_resp(
      conn,
      200,
      "<ListBucketResult><IsTruncated>#{more != []}</IsTruncated>#{contents}#{next}</ListBucketResult>"
    )
  end

  defp handle(conn, "POST", "", %{"delete" => _}, body) do
    if checked?(conn, body) do
      keys = for [_, key] <- Regex.scan(~r/<Key>([^<]*)<\/Key>/, body), do: unescape(key)
      locked = Agent.get(@agent, & &1.locked)
      {refused, gone} = Enum.split_with(keys, &MapSet.member?(locked, &1))
      Agent.update(@agent, fn s -> %{s | objects: Map.drop(s.objects, gone)} end)
      errors = Enum.map_join(refused, "", &"<Error><Key>#{escape(&1)}</Key><Code>AccessDenied</Code></Error>")
      send_resp(conn, 200, "<DeleteResult>#{errors}</DeleteResult>")
    else
      bad_digest(conn)
    end
  end

  defp handle(conn, "POST", key, %{"uploads" => _}, _body) do
    id = Base.encode16(:crypto.strong_rand_bytes(6))
    Agent.update(@agent, &put_in(&1, [:uploads, id], %{key: key, parts: %{}, headers: conn.req_headers}))

    send_resp(
      conn,
      200,
      "<InitiateMultipartUploadResult><UploadId>#{id}</UploadId></InitiateMultipartUploadResult>"
    )
  end

  defp handle(conn, "PUT", _key, %{"partNumber" => n, "uploadId" => id}, body) do
    cond do
      Agent.get(@agent, & &1.fail_parts) == true ->
        send_resp(conn, 500, "<Error><Code>SlowDown</Code></Error>")

      checked?(conn, body) ->
        put_part(conn, id, n, body)

      true ->
        bad_digest(conn)
    end
  end

  defp handle(conn, "POST", key, %{"uploadId" => id}, body) do
    if Agent.get(@agent, & &1.fail_parts) == :complete,
      do: send_resp(conn, 200, "<Error><Code>InternalError</Code></Error>"),
      else: complete(conn, key, id, body)
  end

  defp handle(conn, "DELETE", _key, %{"uploadId" => id}, _body) do
    Agent.update(@agent, &%{&1 | uploads: Map.delete(&1.uploads, id)})
    send_resp(conn, 204, "")
  end

  defp handle(conn, "PUT", key, _q, body) do
    if checked?(conn, body) do
      Agent.update(@agent, &put_in(&1, [:objects, key], %{data: body, headers: conn.req_headers}))
      send_resp(conn, 200, "")
    else
      bad_digest(conn)
    end
  end

  defp handle(conn, method, key, _q, _body) when method in ["GET", "HEAD"] do
    case object(key) do
      nil ->
        send_resp(conn, 404, "<Error><Code>NoSuchKey</Code></Error>")

      %{data: data, headers: headers} ->
        sum = List.keyfind(headers, "x-amz-checksum-sha256", 0)
        conn = if sum, do: put_resp_header(conn, "x-amz-checksum-sha256", elem(sum, 1)), else: conn
        type = conn.query_params["response-content-type"]
        conn = if type, do: put_resp_content_type(conn, type, nil), else: conn
        send_resp(conn, 200, data)
    end
  end

  defp handle(conn, _method, _key, _q, _body),
    do: send_resp(conn, 400, "<Error><Code>NotImplemented</Code></Error>")

  defp put_part(conn, id, n, body) do
    etag = ~s("#{Base.encode16(:crypto.hash(:md5, body), case: :lower)}")
    Agent.update(@agent, &put_in(&1, [:uploads, id, :parts, String.to_integer(n)], {etag, body}))
    conn |> put_resp_header("etag", etag) |> send_resp(200, "")
  end

  defp complete(conn, key, id, body) do
    upload = Agent.get(@agent, & &1.uploads[id])

    listed =
      for [_, n, etag] <- Regex.scan(~r/<PartNumber>(\d+)<\/PartNumber><ETag>([^<]+)<\/ETag>/, body),
          do: {String.to_integer(n), unescape(etag)}

    if Enum.all?(listed, fn {n, etag} -> match?({^etag, _}, upload.parts[n]) end) do
      data = listed |> Enum.map(fn {n, _} -> elem(upload.parts[n], 1) end) |> IO.iodata_to_binary()

      Agent.update(@agent, fn s ->
        %{
          s
          | objects: Map.put(s.objects, key, %{data: data, headers: upload.headers}),
            uploads: Map.delete(s.uploads, id)
        }
      end)

      send_resp(conn, 200, "<CompleteMultipartUploadResult/>")
    else
      send_resp(conn, 400, "<Error><Code>InvalidPart</Code></Error>")
    end
  end

  defp checked?(conn, body) do
    case get_req_header(conn, "x-amz-checksum-sha256") do
      [sum] -> sum == Base.encode64(:crypto.hash(:sha256, body))
      [] -> true
    end
  end

  defp bad_digest(conn), do: send_resp(conn, 400, "<Error><Code>BadDigest</Code></Error>")

  defp read_all(conn, acc) do
    case read_body(conn, length: 64 * 1024 * 1024) do
      {:ok, data, conn} -> {:ok, acc <> data, conn}
      {:more, data, conn} -> read_all(conn, acc <> data)
    end
  end

  defp escape(text), do: text |> String.replace("&", "&amp;") |> String.replace("<", "&lt;")

  defp unescape(text),
    do: text |> String.replace("&lt;", "<") |> String.replace("&quot;", "\"") |> String.replace("&amp;", "&")
end
