defmodule Testor.Queue.NATS do
  @moduledoc """
  NATS JetStream as the job queue, with a client of NATS's text protocol written here (no
  dependency): `CONNECT`, `PUB`/`HPUB`, `SUB`, `MSG`/`HMSG`, `PING`/`PONG`, and JetStream
  through its request-reply API (`$JS.API.*`).

      {"type": "nats", "url": "tls://nats.example.com:4222", "stream": "TESTOR",
       "auth": {"credsFile": "/run/secrets/testor.creds"},
       "queues": [{"labels": [], "subject": "testor.jobs.default"}]}

  - TLS is required (`tls://`, verified against the system's CAs or `caBundle`); `nats://`
    only with `"tls": false`, for a broker on the same machine.
  - `auth`: `token`, `user`/`password`, `nkeySeedFile` (an NKey seed: the server's nonce is
    signed with Ed25519), or `credsFile` (a user JWT and its seed). Values may be `env:NAME`.
  - The stream (`WorkQueue` retention) and one durable pull consumer per queue's subject are
    made when missing; the consumer's `ack_wait` is the lease (`execution.leaseSeconds`).
  - A lease pulls one message (`MSG.NEXT`, no wait); a heartbeat answers `+WPI`, a finish
    `+ACK`, a job put back `-NAK`. The message's reply subject is the receipt.

  Each operation opens a connection, does its exchange and closes it: leases are seconds
  apart, and nothing has to survive a broker restart. Replies are capped at 1 MB.
  """
  @behaviour Testor.Queue
  import Bitwise

  @max_payload 1_048_576
  @timeout 10_000

  @doc false
  def config(raw) do
    uri = URI.parse(raw["url"] || "")
    stream = raw["stream"] || "TESTOR"

    cond do
      uri.scheme not in ["tls", "nats"] or not is_binary(uri.host) ->
        {:error, "execution.queue.url is tls://host:port"}

      uri.scheme == "nats" and raw["tls"] != false ->
        {:error, "execution.queue.url is tls:// (nats:// needs \"tls\": false)"}

      not Regex.match?(~r/^[A-Za-z0-9_-]{1,64}$/, stream) ->
        {:error, "execution.queue.stream is a name"}

      not Enum.all?(raw["queues"], &subject?(&1["subject"])) ->
        {:error, "each NATS queue's subject is a subject without wildcards (testor.jobs.default)"}

      true ->
        {:ok,
         %{
           type: "nats",
           host: uri.host,
           port: uri.port || 4222,
           tls: uri.scheme == "tls",
           ca_bundle: raw["caBundle"],
           stream: stream,
           auth: raw["auth"] || %{}
         }}
    end
  end

  defp subject?(s),
    do: is_binary(s) and Regex.match?(~r/^[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)*$/, s) and byte_size(s) <= 200

  @doc false
  def queue(raw) do
    subject = raw["subject"]

    %{
      labels: raw["labels"] || [],
      subject: subject,
      name: subject,
      consumer: "testor-" <> String.replace(subject, ".", "_")
    }
  end

  # --- the queue -----------------------------------------------------------------------------

  @impl true
  def enqueue(cfg, queue, job) do
    payload = JSON.encode!(%{"id" => job["id"], "project" => job["project"]})

    session(cfg, fn conn ->
      with :ok <- ensure(conn, cfg, queue),
           {:ok, %{"seq" => _}} <- request(conn, queue.subject, payload, [{"Nats-Msg-Id", job["id"]}]) do
        :ok
      else
        {:ok, answer} -> {:error, answer["error"]}
        error -> error
      end
    end)
  end

  @impl true
  def receive(cfg, queue, lease_seconds) do
    session(cfg, fn conn ->
      with :ok <- ensure(conn, cfg, queue, lease_seconds) do
        next = "$JS.API.CONSUMER.MSG.NEXT.#{cfg.stream}.#{queue.consumer}"

        case raw_request(conn, next, ~s({"batch":1,"no_wait":true}), []) do
          {:ok, %{reply: "$JS.ACK." <> _ = receipt, payload: payload}} ->
            case JSON.decode(payload) do
              {:ok, %{"id" => id}} when is_binary(id) -> {:ok, %{id: id, receipt: receipt}}
              _ -> {:ok, %{id: nil, receipt: receipt}}
            end

          # 404 No Messages, 408 Request Timeout: nothing waiting.
          {:ok, %{status: status}} when status in [404, 408] ->
            {:ok, nil}

          {:ok, other} ->
            {:error, {:unexpected, other.status}}

          error ->
            error
        end
      end
    end)
  end

  @impl true
  def extend(cfg, _queue, receipt, _seconds), do: answer(cfg, receipt, "+WPI")

  @impl true
  def ack(cfg, _queue, receipt), do: answer(cfg, receipt, "+ACK")

  @impl true
  def release(cfg, _queue, receipt), do: answer(cfg, receipt, "-NAK")

  defp answer(cfg, "$JS.ACK." <> _ = receipt, verb) do
    session(cfg, fn conn -> publish(conn, receipt, nil, verb, []) end)
  end

  defp answer(_cfg, _receipt, _verb), do: {:error, :bad_receipt}

  @impl true
  def depth(cfg, queue) do
    session(cfg, fn conn ->
      case request(conn, "$JS.API.CONSUMER.INFO.#{cfg.stream}.#{queue.consumer}", "", []) do
        {:ok, %{"num_pending" => n}} when is_integer(n) -> {:ok, n}
        {:ok, answer} -> {:error, answer["error"]}
        error -> error
      end
    end)
  end

  # The stream and the queue's consumer, made when missing (once per testor, then cached).
  defp ensure(conn, cfg, queue, lease_seconds \\ nil) do
    key = {__MODULE__, :ready, cfg.host, cfg.port, cfg.stream, queue.consumer}

    if :persistent_term.get(key, false) do
      :ok
    else
      lease = lease_seconds || Testor.Jobs.settings()["leaseSeconds"]

      with :ok <- ensure_stream(conn, cfg, queue),
           :ok <- ensure_consumer(conn, cfg, queue, lease) do
        :persistent_term.put(key, true)
        :ok
      end
    end
  end

  defp ensure_stream(conn, cfg, queue) do
    case request(conn, "$JS.API.STREAM.INFO.#{cfg.stream}", "", []) do
      {:ok, %{"config" => %{"subjects" => subjects}}} ->
        if queue.subject in subjects do
          :ok
        else
          update = %{
            "name" => cfg.stream,
            "subjects" => subjects ++ [queue.subject],
            "retention" => "workqueue",
            "storage" => "file"
          }

          created(request(conn, "$JS.API.STREAM.UPDATE.#{cfg.stream}", JSON.encode!(update), []))
        end

      {:ok, %{"error" => %{"code" => 404}}} ->
        stream = %{
          "name" => cfg.stream,
          "subjects" => [queue.subject],
          "retention" => "workqueue",
          "storage" => "file"
        }

        created(request(conn, "$JS.API.STREAM.CREATE.#{cfg.stream}", JSON.encode!(stream), []))

      other ->
        created(other)
    end
  end

  defp ensure_consumer(conn, cfg, queue, lease) do
    consumer = %{
      "stream_name" => cfg.stream,
      "config" => %{
        "durable_name" => queue.consumer,
        "filter_subject" => queue.subject,
        "ack_policy" => "explicit",
        "ack_wait" => lease * 1_000_000_000,
        "max_deliver" => -1
      }
    }

    created(
      request(conn, "$JS.API.CONSUMER.CREATE.#{cfg.stream}.#{queue.consumer}", JSON.encode!(consumer), [])
    )
  end

  defp created({:ok, %{"error" => error}}), do: {:error, error}
  defp created({:ok, _}), do: :ok
  defp created(error), do: error

  # --- the protocol --------------------------------------------------------------------------

  @doc false
  # A connection for `fun`, closed after it, whatever happens.
  def session(cfg, fun) do
    case connect(cfg) do
      {:ok, conn} ->
        try do
          fun.(conn)
        after
          close(conn)
        end

      error ->
        error
    end
  end

  defp connect(cfg) do
    with {:ok, tcp} <-
           :gen_tcp.connect(
             String.to_charlist(cfg.host),
             cfg.port,
             [:binary, active: false, packet: :line, nodelay: true],
             @timeout
           ),
         conn = %{mod: :gen_tcp, sock: tcp, buffer: ""},
         {:ok, "INFO " <> json, conn} <- line(conn),
         {:ok, info} <- JSON.decode(json),
         {:ok, conn} <- upgrade(conn, cfg, info),
         {:ok, auth} <- auth(cfg.auth, info["nonce"]),
         :ok <- send_line(conn, "CONNECT " <> JSON.encode!(Map.merge(connect_options(cfg), auth))),
         :ok <- send_line(conn, "PING"),
         {:ok, conn} <- pong(conn) do
      {:ok, conn}
    else
      {:ok, "-ERR " <> why, _conn} -> {:error, {:refused, String.trim(why)}}
      {:ok, other, _conn} -> {:error, {:unexpected, String.slice(other, 0, 100)}}
      {:error, _} = error -> error
    end
  end

  defp connect_options(cfg) do
    %{
      "verbose" => false,
      "pedantic" => false,
      "tls_required" => cfg.tls,
      "name" => "testor",
      "lang" => "elixir",
      "version" => to_string(Application.spec(:testor, :vsn)),
      "protocol" => 1,
      "headers" => true,
      "no_responders" => true
    }
  end

  defp upgrade(conn, %{tls: false}, _info), do: {:ok, conn}

  defp upgrade(conn, cfg, _info) do
    :inet.setopts(conn.sock, packet: :raw)

    opts = [
      verify: :verify_peer,
      cacerts: cacerts(cfg),
      server_name_indication: String.to_charlist(cfg.host),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)],
      packet: :line,
      active: false,
      mode: :binary
    ]

    case :ssl.connect(conn.sock, opts, @timeout) do
      {:ok, ssl} -> {:ok, %{conn | mod: :ssl, sock: ssl}}
      {:error, reason} -> {:error, {:tls, reason}}
    end
  end

  defp cacerts(%{ca_bundle: path}) when is_binary(path) do
    for {:Certificate, der, _} <- :public_key.pem_decode(File.read!(path)), do: der
  end

  defp cacerts(_cfg), do: :public_key.cacerts_get()

  defp pong(conn) do
    case line(conn) do
      {:ok, "PONG", conn} -> {:ok, conn}
      {:ok, "+OK", conn} -> pong(conn)
      {:ok, "INFO " <> _, conn} -> pong(conn)
      other -> other
    end
  end

  defp close(conn), do: conn.mod.close(conn.sock)

  defp send_line(conn, text), do: conn.mod.send(conn.sock, [text, "\r\n"])

  # One protocol line, without its CRLF.
  defp line(conn) do
    case conn.mod.recv(conn.sock, 0, @timeout) do
      {:ok, data} ->
        if byte_size(data) > 65_536,
          do: {:error, :line_too_long},
          else: {:ok, String.trim_trailing(data, "\r\n"), conn}

      {:error, _} = error ->
        error
    end
  end

  defp publish(conn, subject, reply, payload, headers) do
    reply = if reply, do: " " <> reply, else: ""

    case headers do
      [] ->
        conn.mod.send(conn.sock, [
          "PUB ",
          subject,
          reply,
          " ",
          Integer.to_string(byte_size(payload)),
          "\r\n",
          payload,
          "\r\n"
        ])

      _ ->
        head = "NATS/1.0\r\n" <> Enum.map_join(headers, "", fn {k, v} -> "#{k}: #{v}\r\n" end) <> "\r\n"
        total = byte_size(head) + byte_size(payload)

        line = [
          "HPUB ",
          subject,
          reply,
          " ",
          Integer.to_string(byte_size(head)),
          " ",
          Integer.to_string(total),
          "\r\n"
        ]

        conn.mod.send(conn.sock, [line, head, payload, "\r\n"])
    end
  end

  # A request and its JSON answer.
  defp request(conn, subject, payload, headers) do
    case raw_request(conn, subject, payload, headers) do
      {:ok, %{payload: body, status: status}} ->
        case JSON.decode(body) do
          {:ok, %{} = answer} -> {:ok, answer}
          _ -> {:error, {:no_answer, status}}
        end

      error ->
        error
    end
  end

  # A request on a fresh inbox: the first message back, `%{reply, status, payload}`.
  defp raw_request(conn, subject, payload, headers) do
    inbox = "_INBOX." <> Base.encode16(:crypto.strong_rand_bytes(8))
    # A subscription id of its own: a server keeps the first subscription of an id.
    sid = Integer.to_string(System.unique_integer([:positive]))

    with :ok <- send_line(conn, "SUB #{inbox} #{sid}"),
         :ok <- publish(conn, subject, inbox, payload, headers),
         {:ok, _} = answer <- message(conn),
         :ok <- send_line(conn, "UNSUB #{sid}") do
      answer
    end
  end

  defp message(conn) do
    case line(conn) do
      {:ok, "PING", conn} ->
        with :ok <- send_line(conn, "PONG"), do: message(conn)

      {:ok, "+OK", conn} ->
        message(conn)

      # The server's updates (cluster changes, lame duck mode) may come at any time.
      {:ok, "INFO " <> _, conn} ->
        message(conn)

      {:ok, "-ERR " <> why, _conn} ->
        {:error, {:refused, String.trim(why)}}

      {:ok, "MSG " <> rest, conn} ->
        {reply, size} =
          case String.split(rest, " ") do
            [_subject, _sid, reply, size] -> {reply, size}
            [_subject, _sid, size] -> {nil, size}
          end

        with {:ok, body} <- body(conn, String.to_integer(size)),
             do: {:ok, %{reply: reply, status: 200, payload: body}}

      {:ok, "HMSG " <> rest, conn} ->
        {reply, head_size, size} =
          case String.split(rest, " ") do
            [_subject, _sid, reply, head, size] -> {reply, head, size}
            [_subject, _sid, head, size] -> {nil, head, size}
          end

        with {:ok, all} <- body(conn, String.to_integer(size)) do
          n = String.to_integer(head_size)
          <<head::binary-size(^n), payload::binary>> = all
          {:ok, %{reply: reply, status: status(head), payload: payload}}
        end

      {:ok, other, _conn} ->
        {:error, {:unexpected, String.slice(other, 0, 100)}}

      error ->
        error
    end
  end

  # A message's payload of `size` bytes and its CRLF, read raw.
  defp body(_conn, size) when size > @max_payload, do: {:error, :too_large}

  defp body(conn, size) do
    setopts(conn, packet: :raw)
    result = conn.mod.recv(conn.sock, size + 2, @timeout)
    setopts(conn, packet: :line)

    case result do
      {:ok, <<data::binary-size(^size), "\r\n">>} -> {:ok, data}
      {:ok, _} -> {:error, :bad_message}
      error -> error
    end
  end

  defp setopts(%{mod: :ssl, sock: sock}, opts), do: :ssl.setopts(sock, opts)
  defp setopts(%{sock: sock}, opts), do: :inet.setopts(sock, opts)

  # "NATS/1.0 404 No Messages": 404; a plain header block: 200.
  defp status(head) do
    case Regex.run(~r/^NATS\/1\.0 (\d{3})/, head) do
      [_, code] -> String.to_integer(code)
      nil -> 200
    end
  end

  # --- authentication ------------------------------------------------------------------------

  @doc false
  def auth(%{"token" => token}, _nonce), do: with({:ok, t} <- secret(token), do: {:ok, %{"auth_token" => t}})

  def auth(%{"user" => user, "password" => password}, _nonce) do
    with {:ok, p} <- secret(password), do: {:ok, %{"user" => user, "pass" => p}}
  end

  def auth(%{"nkeySeedFile" => file}, nonce) do
    with {:ok, text} <- File.read(file), do: nkey_auth(String.trim(text), nonce, %{})
  end

  def auth(%{"credsFile" => file}, nonce) do
    with {:ok, text} <- File.read(file),
         [_, jwt] <-
           Regex.run(~r/-----BEGIN NATS USER JWT-----\s*(\S+)\s*------END NATS USER JWT------/, text),
         [_, seed] <-
           Regex.run(~r/-----BEGIN USER NKEY SEED-----\s*(\S+)\s*------END USER NKEY SEED------/, text) do
      nkey_auth(seed, nonce, %{"jwt" => jwt})
    else
      {:error, _} = error -> error
      _ -> {:error, :bad_creds_file}
    end
  end

  def auth(_auth, _nonce), do: {:ok, %{}}

  defp secret("env:" <> name) do
    case System.get_env(name) do
      value when value not in [nil, ""] -> {:ok, value}
      _ -> {:error, {:no_env, name}}
    end
  end

  defp secret(value) when is_binary(value), do: {:ok, value}

  defp nkey_auth(seed, nonce, extra) do
    with {:ok, private} <- decode_seed(seed),
         true <- is_binary(nonce) || {:error, :no_nonce} do
      {public, _} = :crypto.generate_key(:eddsa, :ed25519, private)
      signature = :crypto.sign(:eddsa, :none, nonce, [private, :ed25519])

      {:ok,
       Map.merge(extra, %{
         "nkey" => encode_public(public),
         "sig" => Base.url_encode64(signature, padding: false)
       })}
    end
  end

  @doc false
  # An NKey user seed ("SU..."): its 32 private bytes.
  def decode_seed(seed) do
    with {:ok, raw} <- Base.decode32(seed, padding: false),
         <<b1, b2, private::binary-32, crc::little-16>> <- raw,
         true <- crc16(<<b1, b2, private::binary>>) == crc,
         true <- (b1 &&& 0xF8) == 18 <<< 3 do
      {:ok, private}
    else
      _ -> {:error, :bad_nkey_seed}
    end
  end

  @doc false
  # A user's public key ("U..."), as NATS prints it.
  def encode_public(public) do
    raw = <<20 <<< 3, public::binary>>
    Base.encode32(raw <> <<crc16(raw)::little-16>>, padding: false)
  end

  @doc false
  # The NKey seed of a user for `private` (32 bytes): tests and `testor` tooling.
  def encode_seed(private) do
    b1 = 18 <<< 3 ||| (20 <<< 3) >>> 5
    b2 = (20 <<< 3 &&& 31) <<< 3
    raw = <<b1, b2, private::binary>>
    Base.encode32(raw <> <<crc16(raw)::little-16>>, padding: false)
  end

  # CRC-16/XMODEM.
  defp crc16(data) do
    for <<byte <- data>>, reduce: 0 do
      crc ->
        Enum.reduce(0..7, bxor(crc, byte <<< 8), fn _, c ->
          if (c &&& 0x8000) != 0, do: bxor(c <<< 1, 0x1021) &&& 0xFFFF, else: c <<< 1 &&& 0xFFFF
        end)
    end
  end
end
