defmodule Testor.Janitor do
  @moduledoc """
  Keeps the data folder small (the runner's disk is tight). At startup, every
  `cleanupIntervalMinutes` and on demand:

    1. history: keeps the newest `runs.maxRuns` runs, none older than `runs.maxAgeDays`;
    2. screenshots: deletes run folders (and loose files) older than
       `screenshots.maxAgeDays`, then the oldest folders until the folder fits
       `screenshots.maxTotalMB`. A running run's folder is never touched.
  """
  use GenServer
  require Logger
  alias Testor.{Config, Files, Stats, Store}

  @day 86_400

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def run(reason \\ "manual"), do: GenServer.call(__MODULE__, {:run, reason}, 300_000)

  @impl true
  def init(nil) do
    send(self(), {:scheduled, "startup"})
    {:ok, nil}
  end

  @impl true
  def handle_info({:scheduled, reason}, state) do
    safe_cleanup(reason)
    minutes = max(1, Config.retention()["cleanupIntervalMinutes"])
    Process.send_after(self(), {:scheduled, "scheduled"}, minutes * 60_000)
    {:noreply, state}
  end

  @impl true
  def handle_call({:run, reason}, _from, state), do: {:reply, safe_cleanup(reason), state}

  defp safe_cleanup(reason) do
    cleanup(reason)
  rescue
    error ->
      Logger.error("janitor: #{Exception.format(:error, error, __STACKTRACE__)}")
      %{"at" => now_iso(), "reason" => reason, "error" => Exception.message(error)}
  end

  defp cleanup(reason) do
    config = Config.retention()
    now = System.os_time(:second)
    runs = Store.all()
    running = for run <- runs, run["status"] == "running", into: MapSet.new(), do: run["id"]

    # 1. History.
    max_age = config["runs"]["maxAgeDays"] * @day

    {_kept, doomed} =
      runs
      |> Enum.reject(&MapSet.member?(running, &1["id"]))
      |> Enum.reduce({MapSet.size(running), []}, fn run, {kept, doomed} ->
        old =
          case Store.parse_time(run["startedAt"]) do
            {:ok, time} -> now - DateTime.to_unix(time) > max_age
            _ -> false
          end

        if not old and kept < config["runs"]["maxRuns"],
          do: {kept + 1, doomed},
          else: {kept, [run["id"] | doomed]}
      end)

    removed_runs = Enum.count(doomed, &(Store.delete(&1) == :ok))

    # 2. Screenshots.
    shots = Config.shots_dir()
    File.mkdir_p!(shots)
    max_age = config["screenshots"]["maxAgeDays"] * @day
    limit = config["screenshots"]["maxTotalMB"] * 1024 * 1024

    {folders, loose} =
      case File.ls(shots) do
        {:ok, names} -> Enum.split_with(names, &File.dir?(Path.join(shots, &1)))
        _ -> {[], []}
      end

    {loose_removed, loose_bytes} =
      Enum.reduce(loose, {0, 0}, fn name, {n, bytes} ->
        path = Path.join(shots, name)

        case File.stat(path, time: :posix) do
          {:ok, %{mtime: mtime, size: size}} when now - mtime > max_age ->
            File.rm(path)
            {n + 1, bytes + size}

          _ ->
            {n, bytes}
        end
      end)

    folders =
      folders
      |> Enum.map(fn name ->
        files = Files.walk(Path.join(shots, name))

        %{
          name: name,
          bytes: files |> Enum.map(& &1.size) |> Enum.sum(),
          newest: files |> Enum.map(& &1.mtime) |> Enum.max(fn -> 0 end),
          empty: files == []
        }
      end)
      |> Enum.sort_by(& &1.newest)

    total = folders |> Enum.map(& &1.bytes) |> Enum.sum()

    {_, folders_removed, folder_bytes} =
      Enum.reduce(folders, {total, 0, 0}, fn folder, {total, n, bytes} ->
        old = folder.empty or now - folder.newest > max_age

        if MapSet.member?(running, folder.name) or (not old and total <= limit) do
          {total, n, bytes}
        else
          File.rm_rf(Path.join(shots, folder.name))
          {total - folder.bytes, n + 1, bytes + folder.bytes}
        end
      end)

    result = %{
      "at" => now_iso(),
      "reason" => reason,
      "removed" => %{
        "runs" => removed_runs,
        "screenshotFolders" => folders_removed,
        "looseFiles" => loose_removed,
        "bytes" => loose_bytes + folder_bytes
      }
    }

    if removed_runs + folders_removed + loose_removed > 0 do
      Logger.info("janitor (#{reason}): #{inspect(result["removed"])}")
    end

    Stats.cleaned(result)
    result
  end

  defp now_iso, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
