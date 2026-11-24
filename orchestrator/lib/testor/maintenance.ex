defmodule Testor.Maintenance do
  @moduledoc """
  Reclaims the disk space that testing leaves behind on the runner, and nothing else. The
  targets are a fixed list; a request only names targets of the last scan, never a path:

    * `snapshot:<project>`: a project's snapshot folder in the workspaces, with its
      dependencies and build caches (`node_modules`, `target`, `.venv`). The next `task` uploads
      it again and installs the dependencies again. Suggested when no run of the project
      started for `maintenance.snapshotIdleDays`.
    * `temp`: entries of the user's temporary folder not modified for
      `maintenance.tempMinAgeDays` (on Unix only the user's own).
    * `cache:npm`, `cache:pip`, `cache:go`, `cache:cargo`: what the tools download or build
      again on demand (the npm cache, pip's cache, the Go build cache, Cargo's downloaded
      crates).
    * `browsers:playwright`: Playwright browser builds older than the newest of each browser.
      A project pinned to an older Playwright then needs `npx playwright install` again.

  A scan measures every target in a task, on demand (`scan/0`). Cleaning (`clean/2`) needs
  `maintenance.enabled: true` in config.json, the id of the current scan (so the choice was
  made on what the scan showed) and nothing running: no recorded run, no PowerShell session in
  the workspaces, no scan. It deletes in a task, publishes the result and scans again. State
  changes are published as `maintenance` on the "global" topic.
  """
  use GenServer
  require Logger
  alias Testor.{Config, Events, Files, OS, Sessions, Store}

  @day 86_400

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "The last scan, what is in progress, the last cleaning and the settings."
  def state, do: GenServer.call(__MODULE__, :state)

  @doc "Starts a scan unless one or a cleaning is in progress; returns the state."
  def scan, do: GenServer.call(__MODULE__, :scan)

  @doc "Starts cleaning targets of the scan `scan_id`: `{:ok, state}` or `{:error, reason}`."
  def clean(scan_id, ids), do: GenServer.call(__MODULE__, {:clean, scan_id, ids})

  # --- server --------------------------------------------------------------------------------

  @impl true
  def init(nil), do: {:ok, %{scan: nil, plans: %{}, task: nil, doing: nil, last_clean: nil, error: nil}}

  @impl true
  def handle_call(:state, _from, state), do: {:reply, public(state), state}

  def handle_call(:scan, _from, state) do
    state = start_scan(state)
    {:reply, public(state), state}
  end

  def handle_call({:clean, scan_id, ids}, _from, state) do
    unknown = Enum.reject(ids, &Map.has_key?(state.plans, &1))

    cond do
      settings()["enabled"] != true ->
        {:reply, {:error, :disabled}, state}

      state.doing != nil or busy?() ->
        {:reply, {:error, :busy}, state}

      state.scan == nil or state.scan["id"] != scan_id ->
        {:reply, {:error, :stale}, state}

      unknown != [] ->
        {:reply, {:error, {:unknown, unknown}}, state}

      true ->
        plans = Map.take(state.plans, ids)
        before = for t <- state.scan["targets"], t["id"] in ids, into: %{}, do: {t["id"], t["bytes"]}
        Logger.info("maintenance: cleaning #{Enum.join(ids, ", ")}")
        task = Task.Supervisor.async_nolink(Testor.TaskSupervisor, fn -> remove(plans, before) end)
        state = publish(%{state | task: task.ref, doing: :clean, error: nil})
        {:reply, {:ok, public(state)}, state}
    end
  end

  @impl true
  def handle_info({ref, result}, %{task: ref} = state) do
    Process.demonitor(ref, [:flush])
    state = %{state | task: nil}

    case state.doing do
      :scan ->
        {targets, plans} = result
        id = :crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false)
        scan = %{"id" => id, "at" => now_iso(), "targets" => targets}
        {:noreply, publish(%{state | doing: nil, scan: scan, plans: plans})}

      :clean ->
        Logger.info("maintenance: freed #{result["freed"]} bytes")
        # What the scan showed is gone: measure again.
        {:noreply, start_scan(%{state | doing: nil, last_clean: result, scan: nil, plans: %{}})}
    end
  end

  def handle_info({:DOWN, ref, :process, _, reason}, %{task: ref} = state) do
    Logger.error("maintenance: #{state.doing} failed: #{inspect(reason)}")
    {:noreply, publish(%{state | task: nil, doing: nil, error: "#{state.doing} failed: #{inspect(reason)}"})}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp start_scan(%{doing: nil} = state) do
    settings = settings()
    task = Task.Supervisor.async_nolink(Testor.TaskSupervisor, fn -> targets(settings) end)
    publish(%{state | task: task.ref, doing: :scan, error: nil})
  end

  defp start_scan(state), do: state

  defp publish(state) do
    Events.broadcast("global", "maintenance", public(state))
    state
  end

  defp public(state) do
    %{
      "enabled" => settings()["enabled"] == true,
      "settings" => settings(),
      "scanning" => state.doing == :scan,
      "cleaning" => state.doing == :clean,
      "scan" => state.scan,
      "lastClean" => state.last_clean,
      "error" => state.error
    }
  end

  defp settings, do: Config.retention()["maintenance"]

  defp busy? do
    Enum.any?(Store.all(), &(&1["status"] == "running")) or Sessions.list() != []
  end

  # --- targets -------------------------------------------------------------------------------

  # Every target: the public fields and, under :remove, the paths cleaning deletes.
  defp targets(settings) do
    now = System.os_time(:second)

    results =
      snapshots(Store.all(), settings, now) ++
        temp(settings, now) ++ caches() ++ browsers()

    {Enum.map(results, &Map.delete(&1, :remove)), Map.new(results, &{&1["id"], &1.remove})}
  end

  defp snapshots(runs, settings, now) do
    root = Config.workspaces()
    data = Path.expand(Config.data_dir())

    last =
      runs |> Enum.group_by(& &1["project"], & &1["startedAt"]) |> Map.new(fn {p, s} -> {p, Enum.max(s)} end)

    running = for r <- runs, r["status"] == "running", into: MapSet.new(), do: r["project"]

    root
    |> ls()
    |> Enum.reject(&String.starts_with?(&1, "."))
    |> Enum.map(&{&1, Path.join(root, &1)})
    |> Enum.filter(fn {_, path} -> File.dir?(path) and Path.expand(path) != data end)
    |> Enum.map(fn {name, path} ->
      used =
        case Store.parse_time(last[name]) do
          {:ok, time} -> DateTime.to_unix(time)
          _ -> Files.mtime(path) || now
        end

      size = measure(path)

      %{
        "id" => "snapshot:" <> name,
        "kind" => "snapshot",
        "label" => name,
        "path" => display(path),
        "bytes" => size.bytes,
        "files" => size.files,
        "lastUsed" => Files.iso(used),
        "suggested" =>
          now - used >= settings["snapshotIdleDays"] * @day and not MapSet.member?(running, name),
        "note" => "project snapshot with its dependencies; the next run uploads and installs them again",
        # .lockhash first: if a locked file stops the rest, npm-ci still reinstalls.
        remove: [Path.join(path, ".lockhash"), path]
      }
    end)
  end

  defp temp(settings, now) do
    dir = System.tmp_dir()
    min_age = settings["tempMinAgeDays"] * @day
    # On Unix the temporary folder may be shared (/tmp): only the user's own entries.
    own = if not OS.windows?(), do: uid(Config.data_dir())

    entries =
      if dir do
        dir
        |> ls()
        |> Enum.flat_map(fn name ->
          path = Path.join(dir, name)

          case File.lstat(path) do
            {:ok, %{uid: uid}} when own == nil or uid == own ->
              size = measure(path)
              if now - size.newest > min_age, do: [{path, size}], else: []

            _ ->
              []
          end
        end)
      else
        []
      end

    if entries == [] do
      []
    else
      [
        %{
          "id" => "temp",
          "kind" => "temp",
          "label" => "Temporary files",
          "path" => display(dir),
          "bytes" => entries |> Enum.map(&elem(&1, 1).bytes) |> Enum.sum(),
          "files" => entries |> Enum.map(&elem(&1, 1).files) |> Enum.sum(),
          "lastUsed" => entries |> Enum.map(&elem(&1, 1).newest) |> Enum.max() |> Files.iso(),
          "suggested" => true,
          "note" => "#{length(entries)} entries not modified for #{settings["tempMinAgeDays"]} days",
          remove: Enum.map(entries, &elem(&1, 0))
        }
      ]
    end
  end

  defp caches do
    [
      {"npm", "npm cache", npm_cache(), "packages npm downloads again when it needs them"},
      {"pip", "pip cache", env_or("PIP_CACHE_DIR", user_cache("pip", "pip/Cache")),
       "packages pip downloads again"},
      {"go", "Go build cache", env_or("GOCACHE", user_cache("go-build", "go-build")),
       "rebuilt on the next go build or go test"},
      {"cargo", "Cargo downloaded crates", cargo_cache(), "crates Cargo downloads again"}
    ]
    |> Enum.flat_map(fn {key, label, path, note} ->
      children = if path, do: Enum.map(ls(path), &Path.join(path, &1)), else: []

      if children == [] do
        []
      else
        size = measure(path)

        [
          %{
            "id" => "cache:" <> key,
            "kind" => "cache",
            "label" => label,
            "path" => display(path),
            "bytes" => size.bytes,
            "files" => size.files,
            "lastUsed" => Files.iso(size.newest),
            "suggested" => false,
            "note" => note,
            remove: children
          }
        ]
      end
    end)
  end

  defp browsers do
    path =
      case System.get_env("PLAYWRIGHT_BROWSERS_PATH") do
        value when value in [nil, "", "0"] -> user_cache("ms-playwright", "ms-playwright")
        value -> value
      end

    old =
      if path, do: path |> ls() |> Enum.filter(&File.dir?(Path.join(path, &1))) |> old_revisions(), else: []

    if old == [] do
      []
    else
      sizes = Enum.map(old, &measure(Path.join(path, &1)))

      [
        %{
          "id" => "browsers:playwright",
          "kind" => "browsers",
          "label" => "Old Playwright browsers",
          "path" => display(path),
          "bytes" => sizes |> Enum.map(& &1.bytes) |> Enum.sum(),
          "files" => sizes |> Enum.map(& &1.files) |> Enum.sum(),
          "lastUsed" => sizes |> Enum.map(& &1.newest) |> Enum.max() |> Files.iso(),
          "suggested" => false,
          "note" =>
            "#{Enum.join(old, ", ")}; a project on an older Playwright needs npx playwright install again",
          remove: Enum.map(old, &Path.join(path, &1))
        }
      ]
    end
  end

  @doc "Playwright folders (`chromium-1140`, ...) that a newer revision of the same browser replaces."
  def old_revisions(names) do
    names
    |> Enum.flat_map(fn name ->
      case Regex.run(~r/^(.+)-(\d+)$/, name) do
        [_, browser, revision] -> [{browser, String.to_integer(revision), name}]
        _ -> []
      end
    end)
    |> Enum.group_by(&elem(&1, 0))
    |> Enum.flat_map(fn {_, list} ->
      list |> Enum.sort_by(&elem(&1, 1), :desc) |> Enum.drop(1) |> Enum.map(&elem(&1, 2))
    end)
    |> Enum.sort()
  end

  defp npm_cache do
    base =
      case {System.get_env("npm_config_cache"), OS.windows?(), System.get_env("LOCALAPPDATA")} do
        {dir, _, _} when dir not in [nil, ""] -> dir
        {_, true, nil} -> nil
        {_, true, local} -> Path.join(local, "npm-cache")
        {_, false, _} -> Path.join(System.user_home!(), ".npm")
      end

    base && Path.join(base, "_cacache")
  end

  defp cargo_cache do
    (System.get_env("CARGO_HOME") || Path.join(System.user_home!(), ".cargo"))
    |> Path.join("registry/cache")
  end

  defp env_or(name, default) do
    case System.get_env(name) do
      value when value in [nil, ""] -> default
      value -> value
    end
  end

  # The user's cache folder for a tool: ~/.cache (XDG) on Linux, ~/Library/Caches on macOS,
  # %LOCALAPPDATA% on Windows (where some tools nest it differently).
  defp user_cache(unix, windows) do
    case OS.family() do
      :windows ->
        case System.get_env("LOCALAPPDATA") do
          nil -> nil
          dir -> Path.join(dir, windows)
        end

      :macos ->
        Path.join([System.user_home!(), "Library/Caches", unix])

      _ ->
        Path.join(System.get_env("XDG_CACHE_HOME") || Path.join(System.user_home!(), ".cache"), unix)
    end
  end

  # Paths as the runner's users write them (Elixir joins with "/", Windows' home has "\\").
  defp display(path), do: if(OS.windows?(), do: String.replace(path, "/", "\\"), else: path)

  defp uid(path) do
    case File.stat(path) do
      {:ok, %{uid: uid}} -> uid
      _ -> -1
    end
  end

  defp ls(dir) do
    case File.ls(dir) do
      {:ok, names} -> names
      _ -> []
    end
  end

  # --- measuring and removing ----------------------------------------------------------------

  @doc """
  Bytes, files and the newest modification time (posix) under `path`, without following
  symbolic links (node_modules and pnpm stores are full of them, some in cycles).
  """
  def measure(path) do
    case File.lstat(path, time: :posix) do
      {:ok, %{type: :directory, mtime: mtime}} ->
        path
        |> ls()
        |> Enum.map(&measure(Path.join(path, &1)))
        |> Enum.reduce(%{bytes: 0, files: 0, newest: mtime}, fn x, acc ->
          %{bytes: acc.bytes + x.bytes, files: acc.files + x.files, newest: max(acc.newest, x.newest)}
        end)

      {:ok, %{size: size, mtime: mtime}} ->
        %{bytes: size, files: 1, newest: mtime}

      _ ->
        %{bytes: 0, files: 0, newest: 0}
    end
  end

  defp remove(plans, before) do
    targets =
      Enum.map(plans, fn {id, paths} ->
        errors =
          Enum.flat_map(paths, fn path ->
            case File.rm_rf(path) do
              {:ok, _} -> []
              {:error, reason, file} -> ["#{file}: #{:file.format_error(reason)}"]
            end
          end)

        left = paths |> Enum.map(&measure(&1).bytes) |> Enum.sum()

        if errors != [],
          do: Logger.warning("maintenance: #{id}: #{length(errors)} not removed, first: #{hd(errors)}")

        %{
          "id" => id,
          "freed" => max(Map.get(before, id, 0) - left, 0),
          "left" => left,
          "errors" => Enum.take(errors, 5)
        }
      end)

    %{"at" => now_iso(), "targets" => targets, "freed" => targets |> Enum.map(& &1["freed"]) |> Enum.sum()}
  end

  defp now_iso, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
