defmodule Testor.Test.FakeNATS do
  @moduledoc """
  A NATS server for tests, on a loopback port, plain TCP: INFO with a nonce, CONNECT (no auth, a
  token, or an NKey whose signature of the nonce it checks), PING, SUB, PUB and HPUB, and the
  part of JetStream the queue uses: STREAM.INFO/CREATE/UPDATE, CONSUMER.CREATE/INFO, MSG.NEXT
  and the ack subjects (+ACK, -NAK, +WPI), with deduplication by Nats-Msg-Id. `mode/1`:
  `:no_js` answers JetStream calls as without responders, `:garbage` answers them with a line
  that is not the protocol, `:chatty` sends `+OK` and INFO lines and PINGs around its answers,
  `:huge` declares a message over the client's cap, `:bad_body` sends one without its CRLF,
  `:long_line` sends a line too long, `:plain_next` delivers messages without headers; `:no_info`, `:close_after_connect`,
  `:err_reply`, `:cut`, `:next_409`, `:info_error`, `:create_error` and `:pub_error` misbehave
  as named.
  With `tls: true` it speaks TLS after INFO, with a root `ca_file/0` names.
  """
  @state __MODULE__.State

  @doc "Starts it; `auth` is nil, {:token, t} or {:nkey, public}. Returns its port."
  def start(auth \\ nil, opts \\ []) do
    ExUnit.Callbacks.start_supervised!(%{
      id: @state,
      start:
        {Agent, :start_link,
         [
           fn ->
             %{
               auth: auth,
               streams: %{},
               consumers: %{},
               messages: [],
               seq: 0,
               seen: MapSet.new(),
               mode: nil,
               tls: tls(opts)
             }
           end,
           [name: @state]
         ]}
    })

    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :line, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listen)

    ExUnit.Callbacks.start_supervised!(%{
      id: __MODULE__.Acceptor,
      start: {Task, :start_link, [fn -> accept(listen) end]}
    })

    port
  end

  defp tls(opts) do
    if opts[:tls] do
      tls_opts = [{:digest, :sha256}, {:key, {:namedCurve, :secp256r1}}]

      %{server_config: server} =
        :public_key.pkix_test_data(%{
          server_chain: %{
            root: tls_opts,
            peer:
              tls_opts ++ [{:extensions, [{:Extension, {2, 5, 29, 17}, false, [{:dNSName, ~c"localhost"}]}]}]
          },
          client_chain: %{root: tls_opts, peer: tls_opts}
        })

      ca = Path.join(System.tmp_dir!(), "fake-nats-#{System.unique_integer([:positive])}.pem")

      File.write!(
        ca,
        :public_key.pem_encode(for der <- server[:cacerts], do: {:Certificate, der, :not_encrypted})
      )

      {key_type, key_der} = server[:key]
      %{ca: ca, opts: [cert: server[:cert], key: {key_type, key_der}, cacerts: server[:cacerts]]}
    end
  end

  def ca_file, do: Agent.get(@state, & &1.tls.ca)

  def mode(mode), do: Agent.update(@state, &%{&1 | mode: mode})
  def messages, do: Agent.get(@state, & &1.messages)

  defp accept(listen) do
    {:ok, sock} = :gen_tcp.accept(listen)
    pid = spawn(fn -> serve(sock) end)
    :gen_tcp.controlling_process(sock, pid)
    send(pid, :go)
    accept(listen)
  end

  defp serve(sock) do
    receive do
      :go -> :ok
    end

    tls = Agent.get(@state, & &1.tls)
    if Agent.get(@state, & &1.mode) == :no_info, do: :gen_tcp.send(sock, "HELLO\r\n")

    :gen_tcp.send(
      sock,
      ~s(INFO {"server_id":"fake","nonce":"n0nce","headers":true,"jetstream":true,"tls_required":#{tls != nil}}\r\n)
    )

    t =
      if tls do
        :inet.setopts(sock, packet: :raw)

        case :ssl.handshake(sock, tls.opts ++ [active: false, packet: :line, mode: :binary], 5_000) do
          {:ok, ssl} -> {:ssl, ssl}
          {:error, _} -> nil
        end
      else
        {:gen_tcp, sock}
      end

    if t, do: loop(t, %{subs: %{}})
  end

  defp tsend({mod, sock}, data), do: mod.send(sock, data)
  defp trecv({mod, sock}, n), do: mod.recv(sock, n)
  defp tset({:ssl, sock}, opts), do: :ssl.setopts(sock, opts)
  defp tset({:gen_tcp, sock}, opts), do: :inet.setopts(sock, opts)
  defp tclose({mod, sock}), do: mod.close(sock)

  defp loop(sock, conn) do
    case trecv(sock, 0) do
      {:ok, line} ->
        line |> String.trim_trailing("\r\n") |> command(sock, conn) |> then(&if(&1, do: loop(sock, &1)))

      _ ->
        tclose(sock)
    end
  end

  defp command("CONNECT " <> json, sock, conn) do
    opts = JSON.decode!(json)

    ok =
      case Agent.get(@state, & &1.auth) do
        nil -> true
        {:token, t} -> opts["auth_token"] == t
        {:nkey, public} -> opts["nkey"] == public and verify(public, opts["sig"])
      end

    cond do
      Agent.get(@state, & &1.mode) == :close_after_connect -> tclose(sock) && nil
      # As NATS does, but left open: closing at once can lose the line on Windows.
      not ok -> tsend(sock, "-ERR 'Authorization Violation'\r\n") && conn
      Agent.get(@state, & &1.mode) == :chatty -> tsend(sock, "+OK\r\nINFO {}\r\n") && conn
      true -> conn
    end
  end

  defp command("PING", sock, conn), do: tsend(sock, "PONG\r\n") && conn
  defp command("PONG", _sock, conn), do: conn

  defp command("SUB " <> rest, _sock, conn),
    do: rest |> String.split(" ") |> then(fn [subj, sid] -> %{conn | subs: Map.put(conn.subs, subj, sid)} end)

  defp command("PUB " <> rest, sock, conn) do
    {subj, reply, size} = args(rest, 1)
    payload = read(sock, size)
    handle(sock, conn, subj, reply, %{}, payload)
  end

  defp command("HPUB " <> rest, sock, conn) do
    {subj, reply, [head, total]} = args(rest, 2)
    all = read(sock, total)
    <<headers::binary-size(^head), payload::binary>> = all
    handle(sock, conn, subj, reply, parse_headers(headers), payload)
  end

  defp command(_line, _sock, conn), do: conn

  defp args(rest, counts) do
    parts = String.split(rest, " ")
    {lead, sizes} = Enum.split(parts, length(parts) - counts)
    sizes = Enum.map(sizes, &String.to_integer/1)
    sizes = if counts == 1, do: hd(sizes), else: sizes

    case lead do
      [subj, reply] -> {subj, reply, sizes}
      [subj] -> {subj, nil, sizes}
    end
  end

  defp read(sock, size) do
    tset(sock, packet: :raw)
    {:ok, <<data::binary-size(^size), "\r\n">>} = trecv(sock, size + 2)
    tset(sock, packet: :line)
    data
  end

  defp parse_headers(text) do
    for line <- tl(String.split(text, "\r\n")),
        [k, v] <- [String.split(line, ": ", parts: 2)],
        into: %{},
        do: {k, v}
  end

  defp handle(sock, conn, "$JS." <> _ = subj, reply, headers, payload) do
    case Agent.get(@state, & &1.mode) do
      :no_js -> reply(sock, conn, reply, nil, "NATS/1.0 503\r\n\r\n", "")
      :garbage -> tsend(sock, "WHAT\r\n")
      :huge -> tsend(sock, "MSG #{reply} 1 2000000\r\n")
      :bad_body -> tsend(sock, "MSG #{reply} 1 2\r\nabcd\r\n")
      :long_line -> tsend(sock, String.duplicate("x", 70_000) <> "\r\n")
      :err_reply -> tsend(sock, "-ERR 'Permissions Violation'\r\n")
      :cut -> tsend(sock, "MSG #{reply} 1 100\r\nabc") && tclose(sock)
      mode -> js(sock, conn, subj, reply, headers, payload, mode)
    end

    conn
  end

  defp handle(sock, conn, subj, reply, headers, payload) do
    answer =
      Agent.get_and_update(@state, fn s ->
        id = headers["Nats-Msg-Id"]

        cond do
          not Enum.any?(s.streams, fn {_, subjects} -> subj in subjects end) ->
            {nil, s}

          s.mode == :pub_error ->
            {%{"error" => %{"code" => 503, "description" => "no space"}}, s}

          MapSet.member?(s.seen, id) ->
            {%{"stream" => "S", "seq" => 0, "duplicate" => true}, s}

          true ->
            {%{"stream" => "S", "seq" => s.seq + 1},
             %{
               s
               | seq: s.seq + 1,
                 seen: MapSet.put(s.seen, id),
                 messages:
                   s.messages ++ [%{seq: s.seq + 1, subject: subj, id: id, payload: payload, out: false}]
             }}
        end
      end)

    if answer && reply, do: reply(sock, conn, reply, nil, nil, JSON.encode!(answer))
    conn
  end

  defp js(sock, conn, subj, reply, _headers, payload, mode) do
    ["$JS", kind | rest] = String.split(subj, ".")

    case {kind, rest} do
      {"API", ["STREAM", "INFO", name]} ->
        answer =
          Agent.get(
            @state,
            &(&1.streams[name] && %{"config" => %{"name" => name, "subjects" => &1.streams[name]}})
          )

        reply(
          sock,
          conn,
          reply,
          nil,
          nil,
          JSON.encode!(answer || %{"error" => %{"code" => 404, "description" => "stream not found"}})
        )

      {"API", ["STREAM", "CREATE", _]} when mode == :create_error ->
        reply(sock, conn, reply, nil, nil, ~s({"error":{"code":400,"description":"bad"}}))

      {"API", ["CONSUMER", "INFO", _, _]} when mode == :info_error ->
        reply(sock, conn, reply, nil, nil, ~s({"error":{"code":404}}))

      {"API", ["CONSUMER", "MSG", "NEXT", _, _]} when mode == :next_409 ->
        reply(sock, conn, reply, nil, "NATS/1.0 409 Consumer Deleted\r\n\r\n", "")

      {"API", ["STREAM", op, name]} when op in ["CREATE", "UPDATE"] ->
        cfg = JSON.decode!(payload)
        Agent.update(@state, &put_in(&1.streams[name], cfg["subjects"]))
        reply(sock, conn, reply, nil, nil, JSON.encode!(%{"config" => cfg}))

      {"API", ["CONSUMER", "CREATE", stream, name]} ->
        cfg = JSON.decode!(payload)["config"]
        Agent.update(@state, &put_in(&1.consumers[{stream, name}], cfg["filter_subject"]))
        reply(sock, conn, reply, nil, nil, JSON.encode!(%{"name" => name}))

      {"API", ["CONSUMER", "INFO", stream, name]} ->
        n =
          Agent.get(@state, fn s ->
            Enum.count(s.messages, &(&1.subject == s.consumers[{stream, name}] and not &1.out))
          end)

        reply(sock, conn, reply, nil, nil, JSON.encode!(%{"num_pending" => n}))

      {"API", ["CONSUMER", "MSG", "NEXT", stream, name]} ->
        if Agent.get(@state, & &1.mode) == :chatty, do: tsend(sock, "PING\r\n+OK\r\nINFO {}\r\n")

        next =
          Agent.get_and_update(@state, fn s ->
            case Enum.find(s.messages, &(&1.subject == s.consumers[{stream, name}] and not &1.out)) do
              nil ->
                {nil, s}

              m ->
                {m,
                 %{s | messages: Enum.map(s.messages, &if(&1.seq == m.seq, do: %{&1 | out: true}, else: &1))}}
            end
          end)

        ack = next && "$JS.ACK.#{stream}.#{name}.1.#{next.seq}.#{next.seq}.0.0"

        cond do
          next == nil -> reply(sock, conn, reply, nil, "NATS/1.0 404 No Messages\r\n\r\n", "")
          Agent.get(@state, & &1.mode) == :plain_next -> reply(sock, conn, reply, ack, nil, next.payload)
          true -> reply(sock, conn, reply, ack, "NATS/1.0\r\nNats-Msg-Id: #{next.id}\r\n\r\n", next.payload)
        end

      {"ACK", [_stream, _name, _, seq | _]} ->
        seq = String.to_integer(seq)

        Agent.update(@state, fn s ->
          case payload do
            "+ACK" ->
              %{s | messages: Enum.reject(s.messages, &(&1.seq == seq))}

            "-NAK" ->
              %{s | messages: Enum.map(s.messages, &if(&1.seq == seq, do: %{&1 | out: false}, else: &1))}

            _ ->
              s
          end
        end)
    end
  end

  # A message to the client's inbox `to`, with headers when given.
  defp reply(_sock, _conn, nil, _reply_to, _head, _payload), do: :ok

  defp reply(sock, conn, to, reply_to, head, payload) do
    sid = conn.subs[to]
    via = if reply_to, do: " " <> reply_to, else: ""

    case head do
      nil ->
        tsend(sock, "MSG #{to} #{sid}#{via} #{byte_size(payload)}\r\n#{payload}\r\n")

      head ->
        tsend(
          sock,
          "HMSG #{to} #{sid}#{via} #{byte_size(head)} #{byte_size(head) + byte_size(payload)}\r\n#{head}#{payload}\r\n"
        )
    end
  end

  defp verify(public, sig) do
    {:ok, <<_prefix, key::binary-32, _crc::16>>} = Base.decode32(public, padding: false)
    :crypto.verify(:eddsa, :none, "n0nce", Base.url_decode64!(sig, padding: false), [key, :ed25519])
  end
end
