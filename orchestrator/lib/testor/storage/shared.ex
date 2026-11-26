defmodule Testor.Storage.Shared do
  @moduledoc """
  Testors that share no volume (`Testor.Storage` in S3 with `TESTOR_DATABASE_URL`): what each
  one sees of the others' runs goes through PostgreSQL.

    * **The run index**, the table `testor_runs`: a run's id, project, status, start and end,
      commit and branch as columns, its record as `jsonb`, a `version` raised by every change,
      the size of its log so far and the testor it runs on (`origin`). It replaces the scan of
      `runs/*.json`: every testor loads it at start and follows its changes. A finished record
      is never turned back into a running one.
    * **Live logs:** a running run's log goes to the bucket in segments
      (`logs/<id>/<offset>.log`, an agent's chunk each, or 256 KB or 5 s of a local run), the
      index's log size moved only from the offset the segment starts at (one writer wins). The
      segment is announced to every testor, which appends it to its copy of the log (fetching
      any it missed from the bucket), so its tracker follows the run as it would a local one.
      The finished log is one object (`logs/<id>.log`) and its segments are deleted.
    * **Events:** `NOTIFY testor_relay` carries a run's change (`run`, its id and version), its
      removal, a log segment (inline when small, else read from the bucket) and the dashboard's
      `job` and `approval` events. Payloads stay under NOTIFY's 8 KB; a listener that missed
      some catches up from the index every #{30} s.
  """
  use GenServer
  require Logger
  alias Testor.{Blob, Cluster, Config, Events, Files, Storage, Store}

  @pool Testor.Jobs.Postgres
  @channel "testor_relay"
  @inline 5_000
  @resync_ms 30_000
  @segment_bytes 262_144
  @segment_ms 5_000

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  # --- the index -----------------------------------------------------------------------------

  @doc "Makes the table when it is not there."
  def migrate! do
    Postgrex.query!(
      @pool,
      """
      CREATE TABLE IF NOT EXISTS testor_runs (
        id text PRIMARY KEY, project text, status text NOT NULL, started_at text, ended_at text,
        commit text, branch text, record jsonb NOT NULL, version bigint NOT NULL DEFAULT 1,
        log_size bigint NOT NULL DEFAULT 0, origin text, updated_at timestamptz NOT NULL DEFAULT now())
      """,
      []
    )

    Postgrex.query!(@pool, "CREATE INDEX IF NOT EXISTS testor_runs_updated ON testor_runs (updated_at)", [])
    :ok
  end

  @doc "Every run in the index."
  def all do
    %{rows: rows} = Postgrex.query!(@pool, "SELECT record::text FROM testor_runs", [])
    Enum.map(rows, fn [record] -> JSON.decode!(record) end)
  end

  def get(id) do
    case Postgrex.query!(@pool, "SELECT record::text FROM testor_runs WHERE id = $1", [id]) do
      %{rows: [[record]]} -> JSON.decode!(record)
      %{rows: []} -> nil
    end
  end

  @doc "Saves `run` in the index and tells the others: `{:ok, version}`, or `:final` when a finished record is there."
  def put(run) do
    git = run["git"] || %{}

    %{rows: rows} =
      Postgrex.query!(
        @pool,
        """
        INSERT INTO testor_runs (id, project, status, started_at, ended_at, commit, branch, record, origin)
        VALUES ($1, $2, $3, $4, $5, $6, $7, ($8::text)::jsonb, $9)
        ON CONFLICT (id) DO UPDATE SET project = EXCLUDED.project, status = EXCLUDED.status,
          started_at = EXCLUDED.started_at, ended_at = EXCLUDED.ended_at, commit = EXCLUDED.commit,
          branch = EXCLUDED.branch, record = EXCLUDED.record,
          origin = COALESCE(testor_runs.origin, EXCLUDED.origin),
          version = testor_runs.version + 1, updated_at = now()
        WHERE testor_runs.status = 'running' OR EXCLUDED.status <> 'running'
        RETURNING version
        """,
        [
          run["id"],
          run["project"],
          run["status"],
          run["startedAt"],
          run["endedAt"],
          git["commit"],
          git["branch"],
          JSON.encode!(run),
          run["origin"]
        ]
      )

    case rows do
      [[version]] ->
        notify(%{"k" => "run", "id" => run["id"], "v" => version})
        {:ok, version}

      [] ->
        :final
    end
  end

  @doc "`put/1`, and the versions a store knows, with this run's new one."
  def put_version(versions, run) do
    case put(run) do
      {:ok, version} -> Map.put(versions, run["id"], version)
      :final -> versions
    end
  end

  @doc "Removes run `id` from the index and tells the others."
  def delete(id) do
    Postgrex.query!(@pool, "DELETE FROM testor_runs WHERE id = $1", [id])
    notify(%{"k" => "removed", "id" => id})
  end

  @doc "Runs changed since `since` (a `DateTime`), for a listener that may have missed some."
  def changed_since(since) do
    %{rows: rows} =
      Postgrex.query!(@pool, "SELECT record::text, version FROM testor_runs WHERE updated_at > $1", [since])

    Enum.map(rows, fn [record, version] -> {JSON.decode!(record), version} end)
  end

  @doc "Removes every run from the index (tests)."
  def clear do
    Postgrex.query!(@pool, "TRUNCATE testor_runs", [])
    :ok
  end

  # --- live logs -----------------------------------------------------------------------------

  def segment_key(id, offset),
    do: "logs/#{id}/" <> String.pad_leading(Integer.to_string(offset), 16, "0") <> ".log"

  @doc """
  Adds `data` to run `id`'s log at `offset` (an agent's chunk): the segment to the bucket, the
  index's size moved on, the others told. `{:ok, size}` or `{:error, reason}` (`{:offset, size}`
  when `offset` is not where the log ends).
  """
  def append(id, offset, data, max) do
    size = log_size(id)

    cond do
      size == nil ->
        {:error, :no_run}

      offset != size ->
        {:error, {:offset, size}}

      size + byte_size(data) > max ->
        {:error, :too_large}

      true ->
        with :ok <- Storage.adapter_for(Storage.config()).put(Storage.config(), segment_key(id, offset), data) do
          %{num_rows: moved} =
            Postgrex.query!(
              @pool,
              "UPDATE testor_runs SET log_size = $3 WHERE id = $1 AND log_size = $2",
              [id, offset, offset + byte_size(data)]
            )

          if moved == 1 do
            GenServer.call(__MODULE__, {:chunk, id, offset, data})
            announce(id, offset, data)
            {:ok, offset + byte_size(data)}
          else
            {:error, {:offset, log_size(id)}}
          end
        end
    end
  end

  defp log_size(id) do
    case Postgrex.query!(@pool, "SELECT log_size FROM testor_runs WHERE id = $1", [id]) do
      %{rows: [[size]]} -> size
      %{rows: []} -> nil
    end
  end

  defp announce(id, offset, data) do
    inline = if byte_size(data) <= @inline, do: Base.encode64(data)
    notify(%{"k" => "chunk", "id" => id, "at" => offset, "n" => byte_size(data), "d" => inline})
  end

  @doc """
  A local run's log as its tracker has read it (`size` bytes): sent to the bucket as a segment
  once #{@segment_bytes} bytes or #{div(@segment_ms, 1000)} s have gathered, or all of it when
  `flush` (the run ended).
  """
  def follow(id, size, flush), do: GenServer.cast(__MODULE__, {:follow, id, size, flush})

  @doc "Fetches the segments of run `id`'s log that this testor's copy lacks, in order."
  def catch_up(id), do: GenServer.call(__MODULE__, {:catch_up, id}, 120_000)

  @doc "The finished log is one object now: its segments go."
  def compact(id) do
    case Blob.delete_prefix(Blob.S3, Storage.config(), "logs/#{id}/") do
      {:ok, _, _} -> :ok
      error -> error
    end
  end

  # --- events --------------------------------------------------------------------------------

  @doc "Sends a dashboard event to the other testors."
  def relay(topic, name, data) do
    payload =
      JSON.encode!(%{"k" => "event", "t" => topic, "e" => name, "d" => data, "o" => Cluster.instance()})

    if byte_size(payload) < 7_900, do: Postgrex.query!(@pool, "SELECT pg_notify($1, $2)", [@channel, payload])
    :ok
  end

  defp notify(message) do
    payload = JSON.encode!(Map.put(message, "o", Cluster.instance()))
    Postgrex.query!(@pool, "SELECT pg_notify($1, $2)", [@channel, payload])
    :ok
  end

  # --- server --------------------------------------------------------------------------------

  @impl true
  def init(nil) do
    if Storage.shared?(), do: listen(), else: :ignore
  end

  defp listen do
    migrate!()
    options = Testor.Jobs.Postgres.options(Testor.Jobs.Postgres.url())
    {:ok, listener} = Postgrex.Notifications.start_link(options ++ [auto_reconnect: true])
    {_, _ref} = Postgrex.Notifications.listen(listener, @channel)
    Process.send_after(self(), :resync, @resync_ms)
    {:ok, %{listener: listener, synced: DateTime.utc_now(), follow: %{}}}
  end

  @impl true
  def handle_call({:chunk, id, offset, data}, _from, state) do
    write(id, offset, data)
    {:reply, :ok, state}
  end

  def handle_call({:catch_up, id}, _from, state) do
    fill(id)
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:follow, id, size, flush}, state) do
    now = System.monotonic_time(:millisecond)
    {sent, at} = Map.get(state.follow, id, {0, now})

    # Once the run is stored, its log is one object: no segment is sent any more.
    due = flush or size - sent >= @segment_bytes or now - at >= @segment_ms
    stored = match?(%{"stored" => true}, Store.get(id))

    {sent, at} =
      if size > sent and due and not stored,
        do: {send_segment(id, sent, size), now},
        else: {sent, at}

    follow = if flush, do: Map.delete(state.follow, id), else: Map.put(state.follow, id, {sent, at})
    {:noreply, %{state | follow: follow}}
  end

  # The bytes from `from` to `to` of the local log, as one segment.
  defp send_segment(id, from, to) do
    with {:ok, io} <- File.open(Config.log_file(id), [:read, :binary]),
         {:ok, data} <- read_close(io, from, to - from),
         :ok <- Storage.adapter_for(Storage.config()).put(Storage.config(), segment_key(id, from), data) do
      Postgrex.query!(@pool, "UPDATE testor_runs SET log_size = $2 WHERE id = $1", [id, to])
      announce(id, from, data)
      to
    else
      other ->
        Logger.warning("storage: #{id}'s log could not be sent from #{from}: #{inspect(other)}")
        from
    end
  end

  defp read_close(io, from, length) do
    result = Files.read_at(io, from, length)
    File.close(io)
    result
  end

  @impl true
  def handle_info({:notification, _pid, _ref, @channel, payload}, state) do
    me = Cluster.instance()

    case JSON.decode(payload) do
      {:ok, %{"o" => ^me}} -> :ok
      {:ok, message} -> received(message)
      _ -> :ok
    end

    {:noreply, state}
  end

  def handle_info(:resync, state) do
    now = DateTime.utc_now()

    try do
      for {run, version} <- changed_since(DateTime.add(state.synced, -5)), do: Store.indexed(run, version)
    rescue
      error -> Logger.warning("storage: the run index cannot be read: #{Exception.message(error)}")
    end

    Process.send_after(self(), :resync, @resync_ms)
    {:noreply, %{state | synced: now}}
  end

  defp received(%{"k" => "run", "id" => id, "v" => version}) do
    if run = get(id), do: Store.indexed(run, version)
  end

  defp received(%{"k" => "removed", "id" => id}), do: Store.unindexed(id)

  defp received(%{"k" => "chunk", "id" => id, "at" => offset, "d" => data}) when is_binary(data),
    do: write(id, offset, Base.decode64!(data))

  defp received(%{"k" => "chunk", "id" => id}), do: fill(id)

  defp received(%{"k" => "event", "t" => topic, "e" => name, "d" => data}),
    do: Events.local(topic, name, data)

  defp received(_message), do: :ok

  # A segment at `offset` appended to the local copy of the log when it ends there; one beyond
  # it means some were missed, fetched first.
  defp write(id, offset, data) do
    size = Files.size(Config.log_file(id))

    cond do
      offset == size -> append_local(id, data)
      offset > size -> fill(id)
      true -> :ok
    end
  end

  defp append_local(id, data) do
    File.mkdir_p!(Config.logs_dir())
    File.write!(Config.log_file(id), data, [:append])
  end

  defp fill(id) do
    case Storage.adapter_for(Storage.config()).list(Storage.config(), "logs/#{id}/") do
      {:ok, objects} ->
        Enum.reduce_while(objects, :ok, fn %{key: key}, :ok ->
          offset = key |> Path.basename(".log") |> String.to_integer()
          size = Files.size(Config.log_file(id))

          cond do
            offset < size ->
              {:cont, :ok}

            offset == size ->
              case Storage.adapter_for(Storage.config()).get(Storage.config(), key, :binary) do
                {:ok, data} -> {:cont, append_local(id, data)}
                _ -> {:halt, :ok}
              end

            true ->
              {:halt, :ok}
          end
        end)

      {:error, why} ->
        Logger.warning("storage: #{id}'s log segments cannot be listed: #{inspect(why)}")
    end
  end
end
