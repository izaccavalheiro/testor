defmodule Testor.Stats do
  @moduledoc """
  Disk space, the screenshots folder's size and the last cleanup, published as `stats` on the
  "global" topic when they change. The disk is asked every 30 s while someone watches (every
  10 min otherwise); the folder is measured after a run leaves screenshots and every minute.
  """
  use GenServer
  alias Testor.{Config, Events, Files, OS}

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def get, do: GenServer.call(__MODULE__, :get)
  def refresh_screenshots, do: GenServer.cast(__MODULE__, :screenshots)
  def cleaned(result), do: GenServer.cast(__MODULE__, {:cleaned, result})

  @impl true
  def init(nil) do
    send(self(), :disk)
    send(self(), :screenshots_tick)
    {:ok, %{"disk" => nil, "screenshots" => screenshots(), "lastCleanup" => nil, task: nil}}
  end

  @impl true
  def handle_call(:get, _from, state), do: {:reply, public(state), state}

  @impl true
  def handle_cast(:screenshots, state), do: {:noreply, update(state, "screenshots", screenshots())}

  def handle_cast({:cleaned, result}, state) do
    state = update(state, "lastCleanup", result)
    {:noreply, update(state, "screenshots", screenshots())}
  end

  @impl true
  def handle_info(:disk, state) do
    watched = Events.subscribers("global") > 0
    Process.send_after(self(), :disk, if(watched, do: 30_000, else: 600_000))

    state =
      if state.task do
        state
      else
        task =
          Task.Supervisor.async_nolink(Testor.TaskSupervisor, fn ->
            OS.disk(Config.data_dir())
          end)

        %{state | task: task.ref}
      end

    {:noreply, state}
  end

  def handle_info(:screenshots_tick, state) do
    Process.send_after(self(), :screenshots_tick, 60_000)
    {:noreply, update(state, "screenshots", screenshots())}
  end

  def handle_info({ref, disk}, %{task: ref} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, %{update(state, "disk", disk) | task: nil}}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{task: ref} = state),
    do: {:noreply, %{state | task: nil}}

  def handle_info(_, state), do: {:noreply, state}

  defp update(state, key, value) do
    if state[key] == value do
      state
    else
      state = Map.put(state, key, value)
      Events.broadcast("global", "stats", public(state))
      state
    end
  end

  defp public(state), do: Map.take(state, ["disk", "screenshots", "lastCleanup"])

  defp screenshots do
    files = Config.shots_dir() |> Files.walk() |> Enum.filter(&Files.image_type(&1.rel))

    %{
      "count" => length(files),
      "bytes" => files |> Enum.map(& &1.size) |> Enum.sum(),
      "oldest" => files |> Enum.map(& &1.mtime) |> Enum.min(fn -> nil end) |> Files.iso()
    }
  end
end
