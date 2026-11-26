defmodule Testor.Audit do
  @moduledoc """
  The audit trail: `<home>/audit.jsonl`, one JSON object per line for every state-changing
  request and every failed sign-in, chained and signed so that editing, removing or reordering
  an entry shows:

      {"at": "...", "event": "request", "who": "ada", "via": "basic", "from": "100.64.0.7",
       "method": "POST", "path": "/api/v1/runs/<id>/cancel", "status": 200, "requestId": "...",
       "prev": "<SHA-256 of the previous line>", "sig": "<Ed25519 signature, base64>"}

  `sig` signs the line without it, with the attestation key (`Testor.Attestation`), so anyone
  with the public key (`GET /api/v1/attestation/key`) can check the trail; `verify/2` does.
  The first entry's `prev` is 64 zeros. When the file passes #{16} MB it is renamed
  `audit-<time>.jsonl` and the chain goes on in a new file. Testors sharing a home
  (`Testor.Cluster`) each keep `audit.<instance>.jsonl`, and `GET /api/v1/audit` shows the trail
  of the testor that answers.

  With runs kept in a bucket (`Testor.Storage`), the trail goes there too, every #{10} s and
  before a file is renamed: the lines written since as one object,
  `audit/<instance>/<yyyy-mm-dd>/<milliseconds>.jsonl`, so a trail outlives the testor's disk
  (and, with Object Lock, the bucket keeps it as its retention says). A testor that starts on
  an empty home continues the chain from the last line in the bucket.
  """
  use GenServer
  require Logger
  alias Testor.{Attestation, Config}

  @genesis String.duplicate("0", 64)
  @max_bytes 16 * 1024 * 1024
  @ship_ms 10_000

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  # Testors sharing a home each write a trail of their own: a chain has one writer.
  def file,
    do:
      Path.join(
        Config.data_dir(),
        if(Testor.Cluster.enabled?(), do: "audit.#{Testor.Cluster.instance()}.jsonl", else: "audit.jsonl")
      )

  @doc "Appends an entry (`event` and its fields); returns at once."
  def record(event, fields), do: GenServer.cast(__MODULE__, {:record, event, fields})

  @doc "Waits until every entry recorded so far is written (tests, and reads that follow writes)."
  def flush, do: GenServer.call(__MODULE__, :flush)

  @doc "The last `limit` entries, newest last; a line that is not JSON as `%{\"malformed\" => line}`."
  def tail(limit) do
    flush()

    case File.read(file()) do
      {:ok, text} ->
        text
        |> String.split("\n", trim: true)
        |> Enum.take(-limit)
        |> Enum.map(fn line ->
          case JSON.decode(line) do
            {:ok, %{} = entry} -> entry
            _ -> %{"malformed" => line}
          end
        end)

      _ ->
        []
    end
  end

  @doc """
  Checks the trail in `path` against `public` (the attestation key): `{:ok, entries}`, or
  `{:error, line, reason}` for the first line that breaks it (`:chain`, `:signature`,
  `:malformed`). `prev` is the hash the first line must follow (a rotated file's last line).
  """
  def verify(path \\ file(), public, prev \\ @genesis) do
    lines =
      case File.read(path) do
        {:ok, text} -> String.split(text, "\n", trim: true)
        _ -> []
      end

    lines
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, prev}, fn {line, number}, {:ok, prev} ->
      case check(line, prev, public) do
        :ok -> {:cont, {:ok, hash(line)}}
        {:error, reason} -> {:halt, {:error, number, reason}}
      end
    end)
    |> case do
      {:ok, _} -> {:ok, length(lines)}
      error -> error
    end
  end

  defp check(line, prev, public) do
    with {:ok, %{"prev" => ^prev, "sig" => sig} = entry} when is_binary(sig) <- decode(line, prev),
         {:ok, sig} <- Base.decode64(sig),
         unsigned = JSON.encode!(Map.delete(entry, "sig")),
         true <- :crypto.verify(:eddsa, :none, unsigned, sig, [public, :ed25519]) do
      :ok
    else
      {:chain, _} -> {:error, :chain}
      false -> {:error, :signature}
      _ -> {:error, :malformed}
    end
  end

  defp decode(line, prev) do
    case JSON.decode(line) do
      {:ok, %{"prev" => ^prev}} = ok -> ok
      {:ok, %{"prev" => other}} -> {:chain, other}
      _ -> :malformed
    end
  end

  defp hash(line), do: :crypto.hash(:sha256, line) |> Base.encode16(case: :lower)

  # --- server --------------------------------------------------------------------------------

  @impl true
  def init(nil) do
    if Testor.Storage.s3?(), do: Process.send_after(self(), :ship, @ship_ms)
    {:ok, %{prev: last_hash(), sent: Testor.Files.size(file())}}
  end

  @impl true
  def handle_info(:ship, state) do
    Process.send_after(self(), :ship, @ship_ms)
    {:noreply, ship(state)}
  end

  @impl true
  def handle_cast({:record, event, fields}, state) do
    {:noreply, append(state, event, fields)}
  end

  @impl true
  def handle_call(:flush, _from, state), do: {:reply, :ok, state}

  def handle_call(:ship, _from, state), do: {:reply, :ok, ship(state)}

  defp append(state, event, fields) do
    state = rotate(state)
    {_, seed} = Attestation.keypair()

    entry =
      fields
      |> Map.merge(%{
        "at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "event" => event,
        "prev" => state.prev
      })

    unsigned = JSON.encode!(entry)
    sig = :crypto.sign(:eddsa, :none, unsigned, [seed, :ed25519]) |> Base.encode64()
    line = JSON.encode!(Map.put(entry, "sig", sig))
    File.write!(file(), line <> "\n", [:append])
    %{state | prev: hash(line)}
  rescue
    error ->
      Logger.error("audit: could not record #{event}: #{Exception.message(error)}")
      state
  end

  defp rotate(state) do
    if Testor.Files.size(file()) > Application.get_env(:testor, :audit_max_bytes, @max_bytes) do
      state = ship(state)
      stamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d-%H%M%S")
      File.rename!(file(), String.replace_suffix(file(), ".jsonl", "-#{stamp}.jsonl"))
      %{state | sent: 0}
    else
      state
    end
  end

  @doc "Sends the lines written since the last time to the bucket now (tests)."
  def ship_now, do: GenServer.call(__MODULE__, :ship)

  # The lines not in the bucket yet, as one object; they stay to send next time if it fails.
  defp ship(state) do
    size = Testor.Files.size(file())

    with true <- Testor.Storage.s3?() and size > state.sent,
         {:ok, io} <- File.open(file(), [:read, :binary]),
         {:ok, data} <- read_close(io, state.sent, size - state.sent),
         :ok <-
           Testor.Storage.adapter_for(Testor.Storage.config()).put(
             Testor.Storage.config(),
             segment_key(),
             data
           ) do
      %{state | sent: size}
    else
      {:error, why} ->
        Logger.warning("audit: the trail could not be sent to the bucket: #{inspect(why)}")
        state

      _ ->
        state
    end
  end

  defp read_close(io, from, length) do
    result = Testor.Files.read_at(io, from, length)
    File.close(io)
    result
  end

  defp segment_key do
    now = DateTime.utc_now()
    ms = now |> DateTime.to_unix(:millisecond) |> Integer.to_string() |> String.pad_leading(13, "0")
    "audit/#{Testor.Cluster.instance()}/#{Date.to_iso8601(DateTime.to_date(now))}/#{ms}.jsonl"
  end

  # The chain continues from the last line written, across restarts: the bucket's, on a home
  # that has none.
  defp last_hash do
    text =
      case File.read(file()) do
        {:ok, text} -> text
        _ -> last_shipped()
      end

    case text |> String.split("\n", trim: true) |> List.last() do
      nil -> @genesis
      line -> hash(line)
    end
  end

  defp last_shipped do
    cfg = Testor.Storage.config()

    with true <- Testor.Storage.s3?(),
         {:ok, [_ | _] = objects} <-
           Testor.Storage.adapter_for(cfg).list(cfg, "audit/#{Testor.Cluster.instance()}/"),
         {:ok, text} <- Testor.Storage.adapter_for(cfg).get(cfg, List.last(objects).key, :binary) do
      text
    else
      _ -> ""
    end
  end
end
