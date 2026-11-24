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
  require Logger
  alias Testor.{Config, Events, Files, OS, SpecParser, Store}

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
  def handle_info(:tick, st) do
    st = read(st, false)
    run = Store.get(st.id)

    cond do
      run == nil or run["status"] != "running" ->
        stop(st)

      st.ticks > 0 and rem(st.ticks, @alive_every) == 0 and not OS.alive?(run["pid"]) ->
        # run.ps1 writes its final record before its PowerShell exits: re-read before settling.
        case Store.refresh(st.id) do
          %{"status" => "running"} ->
            Logger.warning("tracker: #{st.id}: pid #{run["pid"]} is gone; aborted")
            Store.settle(st.id, "aborted")

          _ ->
            :ok
        end

        stop(st)

      true ->
        st = publish(st, false)
        Process.send_after(self(), :tick, @tick)
        {:noreply, %{st | ticks: st.ticks + 1}}
    end
  end

  defp stop(st) do
    st = st |> read(true) |> publish(true)
    Store.drop_live(st.id)
    {:stop, :normal, st}
  end

  defp read(st, flush) do
    path = Config.log_file(st.id)
    size = Files.size(path)

    data =
      with true <- size > st.read,
           {:ok, io} <- File.open(path, [:read, :binary]) do
        result = Files.read_at(io, st.read, min(size - st.read, @max_read))
        File.close(io)

        case result do
          {:ok, data} -> data
          _ -> ""
        end
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

      %{st | emitted: to, parser: SpecParser.feed(st.parser, clean), tail: tail}
    end
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
