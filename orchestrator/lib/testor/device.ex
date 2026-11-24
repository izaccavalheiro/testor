defmodule Testor.Device do
  @moduledoc """
  Device stats of the runner: OS, machine, CPU, memory, GPU, disks, network, battery and
  processes. A long-lived PowerShell (priv/sysinfo.ps1) runs as a port and answers one JSON
  line per command, so sampling does not start a PowerShell each time.

  While someone watches the dashboard it takes a full sample (with GPU, volumes, battery, the
  top processes and each running run's process tree) every #{3} s; otherwise a light one (CPU,
  memory, disk and network) every #{15} s, which keeps the history going at little cost to
  the tests. The last #{360} points of the history feed the dashboard's sparklines.

  Publishes `device` on "global": `%{"sample" => ..., "point" => ...}`.
  """
  use GenServer
  require Logger
  alias Testor.{Events, OS, Store}
  alias Testor.Device.Unix

  @watched_ms 3_000
  @idle_ms 15_000
  @static_ms 3_600_000
  @timeout_ms 60_000
  @history 360

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "%{static, sample, history}; empty maps until the first answers arrive."
  def snapshot do
    GenServer.call(__MODULE__, :snapshot)
  catch
    :exit, _ -> %{"static" => nil, "sample" => nil, "history" => []}
  end

  @doc "Samples soon (a viewer connected)."
  def poke, do: send(__MODULE__, :tick)

  @impl true
  def init(nil) do
    Process.flag(:trap_exit, true)

    state = %{
      port: nil,
      buffer: "",
      queue: [],
      pending: nil,
      static: nil,
      sample: nil,
      history: [],
      timer: nil,
      # Linux and macOS: Testor.Device.Unix runs in a task; `busy` is its monitor ref.
      unix: not OS.windows?(),
      baseline: %{},
      busy: nil
    }

    send(self(), :open)
    {:ok, state}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, %{"static" => state.static, "sample" => state.sample, "history" => Enum.reverse(state.history)},
     state}
  end

  @impl true
  def handle_info(:open, %{unix: true} = state) do
    Process.send_after(self(), :static, @static_ms)
    send(self(), :tick)
    {:noreply, run_unix(state, :static)}
  end

  def handle_info(:open, state) do
    script = Application.app_dir(:testor, "priv/sysinfo.ps1")

    exe =
      System.find_executable("powershell.exe") ||
        "C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"

    port =
      Port.open({:spawn_executable, exe}, [
        :binary,
        :exit_status,
        :hide,
        {:line, 8_000_000},
        args: ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script]
      ])

    Process.send_after(self(), :static, @static_ms)
    state = %{state | port: port, buffer: "", pending: nil}
    state = request(state, "static")
    send(self(), :tick)
    {:noreply, state}
  end

  def handle_info(:static, state) do
    Process.send_after(self(), :static, @static_ms)
    {:noreply, if(state.unix, do: run_unix(state, :static), else: request(state, "static"))}
  end

  def handle_info(:tick, state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    watched = Events.subscribers("global") > 0
    # Rates need two samples: the second comes right after the first.
    interval = if(length(state.history) < 2, do: 1_000, else: if(watched, do: @watched_ms, else: @idle_ms))
    timer = Process.send_after(self(), :tick, interval)

    pids = for run <- Store.all(), run["status"] == "running", is_integer(run["pid"]), do: run["pid"]
    state = %{state | timer: timer}

    cond do
      state.unix -> {:noreply, run_unix(state, {:sample, watched, pids})}
      watched -> {:noreply, request(state, "sample full #{Enum.join(pids, ",")}")}
      true -> {:noreply, request(state, "sample light")}
    end
  end

  def handle_info({ref, {:unix, result, baseline}}, %{busy: ref} = state) do
    Process.demonitor(ref, [:flush])
    state = %{state | busy: nil, baseline: baseline || state.baseline}
    {:noreply, accept(state, result)}
  end

  def handle_info({:DOWN, ref, :process, _, reason}, %{busy: ref} = state) do
    Logger.warning("device: sampler task failed: #{inspect(reason)}")
    {:noreply, %{state | busy: nil}}
  end

  def handle_info({port, {:data, {:noeol, chunk}}}, %{port: port} = state),
    do: {:noreply, %{state | buffer: state.buffer <> chunk}}

  def handle_info({port, {:data, {:eol, chunk}}}, %{port: port} = state) do
    line = state.buffer <> chunk
    state = %{state | buffer: "", pending: nil}

    state =
      case JSON.decode(line) do
        {:ok, result} ->
          accept(state, result)

        {:error, _} ->
          Logger.warning("device: not JSON: #{String.slice(line, 0, 200)}")
          state
      end

    {:noreply, next(state)}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("device: sampler exited (#{status}); restarting in 5 s")
    Process.send_after(self(), :open, 5_000)
    {:noreply, %{state | port: nil, pending: nil, queue: []}}
  end

  def handle_info(:timeout_check, %{pending: {_, sent}} = state) do
    if System.monotonic_time(:millisecond) - sent > @timeout_ms and state.port do
      Logger.warning("device: sampler did not answer in #{@timeout_ms} ms; restarting")
      Port.close(state.port)
      Process.send_after(self(), :open, 1_000)
      {:noreply, %{state | port: nil, pending: nil, queue: []}}
    else
      {:noreply, state}
    end
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{port: port}) when is_port(port) do
    Port.command(port, "exit\n")
  catch
    _, _ -> :ok
  end

  def terminate(_, _), do: :ok

  defp accept(state, %{"type" => "static"} = static) do
    Events.broadcast("global", "device_static", static)
    %{state | static: static}
  end

  defp accept(state, %{"type" => "sample"} = sample) do
    sample = merge_light(sample, state.sample)
    point = point(sample, state.static)
    Events.broadcast("global", "device", %{"sample" => sample, "point" => point})
    %{state | sample: sample, history: Enum.take([point | state.history], @history)}
  end

  defp accept(state, other) do
    Logger.warning("device: #{inspect(other)}")
    state
  end

  # Linux and macOS: one sampling task at a time; a request while one runs is dropped.
  defp run_unix(%{busy: ref} = state, _job) when is_reference(ref), do: state

  defp run_unix(state, job) do
    baseline = state.baseline

    task =
      Task.Supervisor.async_nolink(Testor.TaskSupervisor, fn ->
        case job do
          :static -> {:unix, Unix.static(), nil}
          {:sample, full, pids} -> Unix.sample(full, pids, baseline) |> then(fn {s, b} -> {:unix, s, b} end)
        end
      end)

    %{state | busy: task.ref}
  end

  # One command at a time; a sample asked for while one runs replaces any queued sample.
  defp request(%{port: nil} = state, _command), do: state

  defp request(state, command) do
    queue =
      if String.starts_with?(command, "sample"),
        do: Enum.reject(state.queue, &String.starts_with?(&1, "sample")) ++ [command],
        else: state.queue ++ [command]

    next(%{state | queue: queue})
  end

  defp next(%{pending: nil, queue: [command | rest], port: port} = state) when is_port(port) do
    Port.command(port, command <> "\n")
    Process.send_after(self(), :timeout_check, @timeout_ms + 1_000)
    %{state | queue: rest, pending: {command, System.monotonic_time(:millisecond)}}
  end

  defp next(state), do: state

  # A light sample keeps the last full sample's GPU, volumes, battery and processes, marked
  # with when they were read.
  defp merge_light(%{"full" => true} = sample, _prev), do: Map.put(sample, "fullAt", sample["at"])

  defp merge_light(sample, %{} = prev) do
    Map.merge(Map.take(prev, ~w(gpu volumes battery top runs handles fullAt)), sample)
  end

  defp merge_light(sample, nil), do: sample

  defp point(sample, static) do
    total = get_in(static || %{}, ["memory", "total"])
    available = get_in(sample, ["memory", "available"])
    network = sample["network"] || []

    %{
      "t" => sample["at"],
      "cpu" => sample["cpu"],
      "mem" =>
        if(is_number(total) and is_number(available) and total > 0,
          do: Float.round(100 * (1 - available / total), 1)
        ),
      "gpu" => if(sample["full"], do: get_in(sample, ["gpu", "util"])),
      "diskRead" => get_in(sample, ["disk", "read"]),
      "diskWrite" => get_in(sample, ["disk", "write"]),
      "diskActive" => get_in(sample, ["disk", "active"]),
      "netRx" => network |> Enum.map(&(&1["rx"] || 0)) |> Enum.sum(),
      "netTx" => network |> Enum.map(&(&1["tx"] || 0)) |> Enum.sum()
    }
  end
end
