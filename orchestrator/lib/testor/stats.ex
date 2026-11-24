defmodule Testor.Stats do
  @moduledoc """
  Disk space, the sizes of the screenshots and artifacts folders and the last cleanup,
  published as `stats` on the "global" topic when they change. The disk is asked every 30 s
  while someone watches (every 10 min otherwise); the screenshots folder is measured after a
  run leaves screenshots and every minute; the artifacts folder (reports can hold thousands of
  files) after a run leaves artifacts, after a cleanup and every 5 minutes, in a task.
  """
  use GenServer
  alias Testor.{Config, Events, Files, OS}

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def get, do: GenServer.call(__MODULE__, :get)
  def refresh_screenshots, do: GenServer.cast(__MODULE__, :screenshots)
  def refresh_artifacts, do: GenServer.cast(__MODULE__, :artifacts)
  def cleaned(result), do: GenServer.cast(__MODULE__, {:cleaned, result})

  @impl true
  def init(nil) do
    send(self(), :disk)
    send(self(), :screenshots_tick)
    send(self(), :artifacts_tick)

    {:ok,
     %{
       "disk" => nil,
       "screenshots" => screenshots(),
       "artifacts" => nil,
       "lastCleanup" => nil,
       tasks: %{}
     }}
  end

  @impl true
  def handle_call(:get, _from, state), do: {:reply, public(state), state}

  @impl true
  def handle_cast(:screenshots, state), do: {:noreply, update(state, "screenshots", screenshots())}
  def handle_cast(:artifacts, state), do: {:noreply, measure(state, "artifacts", &artifacts/0)}

  def handle_cast({:cleaned, result}, state) do
    state = update(state, "lastCleanup", result)
    state = update(state, "screenshots", screenshots())
    {:noreply, measure(state, "artifacts", &artifacts/0)}
  end

  @impl true
  def handle_info(:disk, state) do
    watched = Events.subscribers("global") > 0
    Process.send_after(self(), :disk, if(watched, do: 30_000, else: 600_000))
    {:noreply, measure(state, "disk", fn -> OS.disk(Config.data_dir()) end)}
  end

  def handle_info(:screenshots_tick, state) do
    Process.send_after(self(), :screenshots_tick, 60_000)
    {:noreply, update(state, "screenshots", screenshots())}
  end

  def handle_info(:artifacts_tick, state) do
    Process.send_after(self(), :artifacts_tick, 300_000)
    {:noreply, measure(state, "artifacts", &artifacts/0)}
  end

  def handle_info({ref, value}, state) when is_reference(ref) do
    case Enum.find(state.tasks, fn {_key, task_ref} -> task_ref == ref end) do
      {key, _} ->
        Process.demonitor(ref, [:flush])
        state = %{state | tasks: Map.delete(state.tasks, key)}
        {:noreply, update(state, key, value)}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _, _}, state) do
    {:noreply, %{state | tasks: state.tasks |> Enum.reject(fn {_, r} -> r == ref end) |> Map.new()}}
  end

  def handle_info(_, state), do: {:noreply, state}

  # One task per key at a time; a request while one runs is answered by that one.
  defp measure(state, key, fun) do
    if Map.has_key?(state.tasks, key) do
      state
    else
      task = Task.Supervisor.async_nolink(Testor.TaskSupervisor, fun)
      %{state | tasks: Map.put(state.tasks, key, task.ref)}
    end
  end

  defp update(state, key, value) do
    if state[key] == value do
      state
    else
      state = Map.put(state, key, value)
      Events.broadcast("global", "stats", public(state))
      state
    end
  end

  defp public(state), do: Map.take(state, ["disk", "screenshots", "artifacts", "lastCleanup"])

  defp screenshots do
    files = Config.shots_dir() |> Files.walk() |> Enum.filter(&Files.image_type(&1.rel))

    %{
      "count" => length(files),
      "bytes" => files |> Enum.map(& &1.size) |> Enum.sum(),
      "oldest" => files |> Enum.map(& &1.mtime) |> Enum.min(fn -> nil end) |> Files.iso()
    }
  end

  defp artifacts do
    dir = Config.artifacts_dir()

    runs =
      case File.ls(dir) do
        {:ok, names} -> Enum.count(names, &File.dir?(Path.join(dir, &1)))
        _ -> 0
      end

    Map.put(Files.usage(dir), "runs", runs)
  end
end
