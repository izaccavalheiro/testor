defmodule Testor.RunTracker do
  @moduledoc """
  Follows one running run: tails its log every #{250} ms, feeds new lines to the spec parser,
  and publishes them on `{"run", id}` (`log`, `specs`) and its progress on "global" (`live`,
  at most once a second). Every 3 s it checks the run's PowerShell is still alive; if it is
  gone without run.ps1 having ended the record, the run is settled as aborted.

  Log events carry byte offsets (`from`, `to`) of the lines they hold, so a browser that took
  a snapshot up to some offset drops the events it already has.
  """
  use GenServer, restart: :transient
  alias Testor.{Config, Events, Files, OS, SpecParser, Storage, Store}

  @tick 250
  @alive_every 12
  @live_every_ms 1_000
  @max_read 1_048_576
  @max_line 65_536
  @snapshot_bytes 262_144

  def start(id) do
    DynamicSupervisor.start_child(Testor.TrackerSupervisor, {__MODULE__, id})
  end

  def start_link(id), do: GenServer.start_link(__MODULE__, id, name: via(id))

  defp via(id), do: {:via, Registry, {Testor.TrackerRegistry, id}}

  @doc "The log up to the last published line, its offset and the specs; nil if not tracked."
  def snapshot(id) do
    GenServer.call(via(id), :snapshot)
  catch
    :exit, _ -> nil
  end

  @impl true
  def init(id) do
    send(self(), :catch_up)
    send(self(), :tick)

    {:ok,
     %{
       id: id,
       read: 0,
       emitted: 0,
       pending: "",
       parser: SpecParser.new(),
       tail: [],
       ticks: 0,
       specs_sig: nil,
       live: nil,
       mutation: nil,
       # Monotonic time can be negative on the BEAM: nil means "never sent".
       live_at: nil
     }}
  end

  @impl true
  def handle_call(:snapshot, _from, st) do
    log = Files.tail(Config.log_file(st.id), @snapshot_bytes, st.emitted)

    {:reply,
     %{
       log: log.text,
       offset: st.emitted,
       truncated: log.truncated,
       specs: SpecParser.specs(st.parser)
     }, st}
  end

  @impl true
  # A run another testor follows: its log so far, from the bucket (Testor.Storage.Shared).
  def handle_info(:catch_up, st) do
    if Storage.shared?() and not origin?(Store.get(st.id)), do: Storage.Shared.catch_up(st.id)
    {:noreply, st}
  end

  def handle_info(:tick, st) do
    st = read(st, false)
    run = Store.get(st.id)

    cond do
      run == nil or run["status"] != "running" ->
        stop(st)

      # A remote run's process is on its agent's machine: its job's lease watches it instead.
      st.ticks > 0 and rem(st.ticks, @alive_every) == 0 and origin?(run) and not OS.alive?(run["pid"]) ->
        # run.ps1 writes its final record before its PowerShell exits: re-read it first. Settling
        # leaves a run that has ended alone.
        Store.refresh(st.id)
        Store.settle(st.id, "aborted")
        stop(st)

      true ->
        st = publish(st, false)
        follow(run, st, false)
        Process.send_after(self(), :tick, @tick)
        {:noreply, %{st | ticks: st.ticks + 1}}
    end
  end

  # A local run's process is on this machine; an agent's is not (nor one another testor runs).
  defp origin?(run),
    do: is_map(run) and not is_binary(run["remote"]) and run["origin"] in [nil, Testor.Cluster.instance()]

  # A local run's log, sent on to the other testors as it grows (Testor.Storage.Shared).
  defp follow(run, st, flush) do
    if Storage.shared?() and origin?(run), do: Storage.Shared.follow(st.id, st.read, flush)
  end

  defp stop(st) do
    st = st |> read(true) |> publish(true)
    follow(Store.get(st.id), st, true)
    Store.drop_live(st.id)
    {:stop, :normal, st}
  end

  defp read(st, flush) do
    path = Config.log_file(st.id)
    size = Files.size(path)

    data =
      with true <- size > st.read,
           {:ok, io} <- File.open(path, [:read, :binary]),
           {:ok, data} <- read_close(io, st.read, min(size - st.read, @max_read)) do
        data
      else
        _ -> ""
      end

    buffer = st.pending <> data
    parts = :binary.split(buffer, "\n", [:global])
    {lines, [rest]} = Enum.split(parts, -1)

    {lines, rest} =
      if (flush or byte_size(rest) > @max_line) and rest != "",
        do: {lines ++ [rest], ""},
        else: {lines, rest}

    st = %{st | read: st.read + byte_size(data), pending: rest}

    if lines == [] do
      st
    else
      from = st.emitted
      to = from + byte_size(buffer) - byte_size(rest)
      clean = Enum.map(lines, &Files.clean/1)
      text = Enum.map_join(clean, "", &(&1 <> "\n"))
      Events.broadcast({"run", st.id}, "log", %{"text" => text, "from" => from, "to" => to})

      tail =
        (st.tail ++ Enum.reject(clean, &(String.trim(&1) == ""))) |> Enum.take(-6)

      # A mutation run's progress line, the latest one (Testor.Reports.Mutation).
      mutation =
        clean |> Enum.map(&Testor.Reports.Mutation.progress/1) |> Enum.reject(&is_nil/1) |> List.last()

      %{
        st
        | emitted: to,
          parser: SpecParser.feed(st.parser, clean),
          tail: tail,
          mutation: mutation || st.mutation
      }
    end
  end

  defp read_close(io, from, length) do
    result = Files.read_at(io, from, length)
    File.close(io)
    result
  end

  defp publish(st, force) do
    specs = SpecParser.specs(st.parser)
    sig = :erlang.phash2(specs)

    st =
      if sig != st.specs_sig do
        Events.broadcast({"run", st.id}, "specs", specs)
        %{st | specs_sig: sig}
      else
        st
      end

    live = %{
      "summary" => SpecParser.summary(specs),
      "currentSpec" => specs |> List.last() |> then(&(&1 && &1["file"])),
      "logTail" => st.tail,
      "logBytes" => st.emitted
    }

    live = if st.mutation, do: Map.put(live, "mutationProgress", st.mutation), else: live

    Store.put_live(st.id, live)
    now = System.monotonic_time(:millisecond)

    if live != st.live and (force or st.live_at == nil or now - st.live_at >= @live_every_ms) do
      Events.broadcast("global", "live", Map.put(live, "id", st.id))
      %{st | live: live, live_at: now}
    else
      st
    end
  end
end
