defmodule Testor.Store do
  @moduledoc """
  The run index. run.ps1 writes runs\\<id>.json when a run starts and again when it ends; the
  store sees both within #{300} ms, starts a RunTracker for each running run, stores the spec
  summary of finished runs, settles runs that were aborted or cancelled, and publishes every
  change on the "global" topic. Reads go straight to ETS; writes go through this process.
  """
  use GenServer
  require Logger
  alias Testor.{Config, Events, Files, OS, RunTracker, SpecParser, Stats, Storage}
  alias Testor.Storage.Shared

  @table :testor_runs
  @live :testor_live
  @scan_ms 300

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  # --- reads (any process) -------------------------------------------------------------------

  @doc "Every run, newest first."
  def all do
    @table |> :ets.tab2list() |> Enum.map(&elem(&1, 1)) |> Enum.sort_by(& &1["id"], :desc)
  end

  def get(id) do
    case :ets.lookup(@table, id) do
      [{_, run}] -> run
      [] -> nil
    end
  end

  @doc "A running run with its live progress (summary, current spec, last lines) merged in."
  def with_live(%{"status" => "running", "id" => id} = run) do
    case :ets.lookup(@live, id) do
      [{_, live}] -> Map.merge(run, live)
      [] -> run
    end
  end

  def with_live(run), do: run

  def put_live(id, live), do: :ets.insert(@live, {id, live})
  def drop_live(id), do: :ets.delete(@live, id)

  # --- writes --------------------------------------------------------------------------------

  @doc "Re-reads a run's record from disk now."
  def refresh(id), do: GenServer.call(__MODULE__, {:refresh, id})

  @doc "Ends a run that run.ps1 could not end itself (aborted, cancelled)."
  def settle(id, status), do: GenServer.call(__MODULE__, {:settle, id, status})

  @doc "Kills a running run's PowerShell and everything it started."
  def cancel(id), do: GenServer.call(__MODULE__, {:cancel, id}, 30_000)

  @doc """
  Asks a run to end itself: writes `cancel/<id>`, which run.ps1 watches for. The run's own
  session then ends its process tree, so testor never has to kill processes of another account
  (the one tests run as). `cancel/1` settles the run afterwards, and kills it only when it is
  still there.
  """
  def request_cancel(id) do
    File.mkdir_p!(Config.cancel_dir())
    File.write!(Path.join(Config.cancel_dir(), id), "")
  end

  @doc "Deletes a finished run: its record, log, screenshots and artifacts."
  def delete(id), do: GenServer.call(__MODULE__, {:delete, id}, 30_000)

  @doc "A run as the index holds it at `version`, changed by another testor (`Testor.Storage.Shared`)."
  def indexed(run, version), do: GenServer.cast(__MODULE__, {:indexed, run, version})

  @doc "A run another testor removed."
  def unindexed(id), do: GenServer.cast(__MODULE__, {:unindexed, id})

  # --- server --------------------------------------------------------------------------------

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    :ets.new(@live, [:named_table, :public, read_concurrency: true])

    Enum.each(
      [
        Config.runs_dir(),
        Config.logs_dir(),
        Config.shots_dir(),
        Config.artifacts_dir(),
        Config.reports_dir()
      ],
      &File.mkdir_p!/1
    )

    # Without a shared volume, the runs are the index's (Testor.Storage.Shared), local ones added.
    state = %{sigs: %{}, versions: %{}}
    state = if Storage.shared?(), do: Enum.reduce(Shared.all(), state, &index_run(&2, &1, 0)), else: state
    state = scan(state)
    Logger.info("store: #{map_size(state.sigs)} runs in #{Config.runs_dir()}")
    Process.send_after(self(), :scan, @scan_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:scan, state) do
    state =
      try do
        scan(state)
      rescue
        error ->
          Logger.error("store: scan failed: #{Exception.format(:error, error, __STACKTRACE__)}")
          state
      end

    Process.send_after(self(), :scan, @scan_ms)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:indexed, run, version}, state), do: {:noreply, index_run(state, run, version)}

  def handle_cast({:unindexed, id}, state), do: {:noreply, forget(state, id)}

  @impl true
  def handle_call({:refresh, id}, _from, state) do
    # A record that is gone is forgotten: settling it afterwards must not write it back.
    state =
      case signature(id) do
        nil -> forget(state, id)
        sig -> load(state, id, sig)
      end

    {:reply, get(id), state}
  end

  def handle_call({:settle, id, status}, _from, state) do
    {state, run} = settle_run(state, id, status)
    {:reply, run, state}
  end

  def handle_call({:cancel, id}, _from, state) do
    state = load(state, id, signature(id))

    case get(id) do
      %{"status" => "running", "pid" => pid} = run ->
        beam = String.to_integer(System.pid())

        case kill_check(run, [beam | OS.ancestors(beam)], OS.started_at(pid)) do
          :kill ->
            result = OS.kill_tree(pid)
            Logger.info("store: cancelled #{id} (pid #{pid}): #{inspect(result)}")

          :gone ->
            Logger.info("store: cancelled #{id}: its process has ended")

          {:skip, why} ->
            Logger.warning("store: cancelled #{id} without killing pid #{inspect(pid)}: #{why}")
            :ets.insert(@table, {id, Map.put(run, "warning", "cancelled without killing a process: #{why}")})
        end

        {state, run} = settle_run(state, id, "cancelled")
        {:reply, {:ok, run}, state}

      nil ->
        {:reply, {:error, :not_found}, state}

      _ ->
        {:reply, {:error, :not_running}, state}
    end
  end

  def handle_call({:delete, id}, _from, state) do
    case get(id) do
      %{"status" => "running"} ->
        {:reply, {:error, :running}, state}

      _ ->
        File.rm(Config.run_file(id))
        File.rm(Config.log_file(id))
        File.rm(Path.join(Config.cancel_dir(), id))
        File.rm(Path.join(Config.attestations_dir(), id <> ".dsse.json"))
        File.rm(Path.join(Config.attestations_dir(), id <> ".agent.dsse.json"))
        # The bucket keeps the run's archive: only the note that it was made goes.
        File.rm(Testor.Archive.manifest(id))
        File.rm_rf(Path.join(Config.shots_dir(), id))
        File.rm_rf(Path.join(Config.artifacts_dir(), id))
        Testor.Reports.delete(id)
        Storage.delete(id)
        if Storage.shared?(), do: Shared.delete(id)
        {:reply, :ok, forget(state, id)}
    end
  end

  @doc """
  Whether cancelling `run` may kill its process: `:kill`, `:gone` (it has ended, as run.ps1
  does when asked to cancel), or `{:skip, why}`. The pid comes from
  the run's own record, which the run could rewrite, so it is checked first: it must be a
  process id, not testor nor one of the processes above it (`protected`: killing a tree that
  holds testor would stop the service), and a process that did not start after the run did
  (`started`, nil when there is none): a later one has reused the pid of a run that is gone.
  """
  def kill_check(run, protected, started) do
    pid = run["pid"]

    cond do
      not is_integer(pid) or pid <= 0 -> {:skip, "the record has no valid process id"}
      pid in protected -> {:skip, "process #{pid} is testor or runs it"}
      started == nil -> :gone
      reused?(run["startedAt"], started) -> {:skip, "process #{pid} started after the run: its id was reused"}
      true -> :kill
    end
  end

  # run.ps1 records the start after its PowerShell started; a few seconds of clock skew pass.
  defp reused?(run_started, process_started) do
    case parse_time(run_started) do
      {:ok, time} -> DateTime.diff(process_started, time, :second) > 5
      _ -> false
    end
  end

  # --- scanning ------------------------------------------------------------------------------

  defp scan(state) do
    ids = for name <- Files.ls(Config.runs_dir()), String.ends_with?(name, ".json"), do: Path.rootname(name)

    on_disk = MapSet.new(ids)

    # What the table holds, not only what was signed: a scan that failed halfway may have
    # stored a run without its signature. A run the index holds (Testor.Storage.Shared) need not
    # be in this home: the index removes it.
    state =
      all()
      |> Enum.map(& &1["id"])
      |> Enum.reject(&(MapSet.member?(on_disk, &1) or Map.has_key?(state.versions, &1)))
      |> Enum.reduce(state, &forget(&2, &1))

    # Finished runs never change on disk again (only this process writes them), so only new
    # and running records are looked at.
    Enum.reduce(ids, state, fn id, state ->
      if Map.has_key?(state.sigs, id) and get(id)["status"] != "running" do
        state
      else
        sig = signature(id)
        if sig && state.sigs[id] != sig, do: load(state, id, sig), else: state
      end
    end)
  end

  # mtime has a resolution of one second, so the size is part of the signature: a run that
  # starts and ends within the same second still changes its record's size.
  defp signature(id) do
    case Files.entry(Config.run_file(id)) do
      {:file, size, mtime} -> {mtime, size}
      _ -> nil
    end
  end

  defp load(state, _id, nil), do: state

  defp load(state, id, sig) do
    case Files.read_json(Config.run_file(id)) do
      {:ok, run} -> apply_run(state, id, sig, Map.put(run, "id", id))
      # Half written: the next scan reads it.
      :error -> state
    end
  end

  # A run from the index, newer than the version this testor has of it (0: any).
  defp index_run(state, run, version) do
    id = run["id"]

    if version == 0 or version > Map.get(state.versions, id, 0) do
      state = %{state | versions: Map.put(state.versions, id, version)}
      apply_run(state, id, nil, run)
    else
      state
    end
  end

  # `sig` is the local record's (nil: the run came from the index).
  defp apply_run(state, id, sig, run) do
    prev = get(id)
    run = keep_annotations(run, prev)
    shared = sig != nil and Storage.shared?()
    run = if shared, do: Map.put_new(run, "origin", Testor.Cluster.instance()), else: run
    state = if sig, do: %{state | sigs: Map.put(state.sigs, id, sig)}, else: state

    finalizing = run["status"] != "running" and not Map.has_key?(run, "summary")
    {state, run} = if finalizing, do: finalize(state, run), else: {state, run}
    :ets.insert(@table, {id, run})
    # Every run is finalized once, however it was seen: also one that started and ended between
    # two scans, which is never seen running. Signed once it is in the table.
    if finalizing, do: finished(id)
    # The others see a local run while it runs, and once it is stored (Testor.Storage.publish).
    indexed? = shared and (run["status"] == "running" or run["stored"] == true)
    state = if indexed?, do: %{state | versions: Shared.put_version(state.versions, run)}, else: state

    cond do
      prev == nil and run["status"] == "running" ->
        on_start(run)

      # One another testor finished: its files may have to be fetched first, not in this process.
      prev != nil and prev["status"] == "running" and run["status"] != "running" ->
        if sig,
          do: on_finish(run),
          else: Task.Supervisor.start_child(Testor.TaskSupervisor, fn -> on_finish(run) end)

      prev != run ->
        Events.broadcast("global", "run", with_live(run))

      true ->
        :ok
    end

    state
  end

  # Once per run, when it has ended and is in the table: sign it, tell the webhooks. Once
  # across testors sharing a home too (Testor.Cluster).
  defp finished(id) do
    if Testor.Cluster.claim("finished", id) do
      Testor.Attestation.attest_later(id)
      Testor.Webhooks.notify("run.finished", id)
      Testor.CommitStatus.notify(id)
      if run = get(id), do: Testor.Tracing.run_ended(run)
    end
  end

  defp keep_annotations(run, nil), do: run

  defp keep_annotations(run, prev) do
    case prev do
      %{"warning" => warning} -> Map.put_new(run, "warning", warning)
      _ -> run
    end
  end

  defp on_start(run) do
    id = run["id"]

    # Runs of one project share <workspaces>\<project>: a second upload rewrites the first run's files.
    others =
      for other <- all(),
          other["id"] != id,
          other["status"] == "running",
          other["project"] == run["project"],
          do: other["id"]

    run =
      if others == [] do
        run
      else
        warning =
          "started while #{Enum.join(others, ", ")} was running: both use #{Config.workspaces_name()}\\#{run["project"]}"

        Logger.warning("store: #{id} #{warning}")
        run = Map.put(run, "warning", warning)
        :ets.insert(@table, {id, run})
        run
      end

    # A tracker's start cannot fail (its init only schedules a tick); one may already follow it.
    _ = RunTracker.start(id)

    Logger.info("store: #{id} started (#{run["project"]} #{run["kind"]})")
    Events.broadcast("global", "run", run)
    # Its commit's pull request shows it running (Testor.CommitStatus), from one testor.
    if Testor.Cluster.claim("started", id), do: Testor.CommitStatus.notify(id)
  end

  defp on_finish(run) do
    id = run["id"]
    Storage.local(id)
    specs = Testor.Reports.run_specs(id)
    shots = Files.screenshots(id, specs)
    artifacts = Files.artifacts(id)
    Logger.info("store: #{id} #{run["status"]} in #{run["durationMs"]} ms")
    Events.broadcast("global", "run", run)
    Events.broadcast({"run", id}, "run", run)
    Events.broadcast({"run", id}, "specs", with_shot_counts(specs, shots))
    Events.broadcast({"run", id}, "screenshots", shots)
    Events.broadcast({"run", id}, "artifacts", artifacts)
    if shots != [], do: Stats.refresh_screenshots()
    if artifacts != [], do: Stats.refresh_artifacts()
  end

  defp compact_spec(spec) do
    base = %{"file" => spec["file"], "status" => spec["status"], "durationMs" => spec["durationMs"] || 0}
    if (spec["retries"] || 0) > 0, do: Map.put(base, "retries", spec["retries"]), else: base
  end

  @doc false
  def with_shot_counts(specs, shots) do
    Enum.map(specs, fn spec ->
      Map.put(spec, "screenshots", Enum.count(shots, &(&1["spec"] == spec["file"])))
    end)
  end

  # Adds the spec summary (and the screenshot count, for records without one) and saves it.
  defp finalize(state, run) do
    id = run["id"]
    # Its log and reports may be in the bucket only, sent through other testors.
    Storage.gather(id, :finish)
    # What its report files say first (Testor.Reports): test results, which then are its spec
    # table, a mutation score, coverage. Without test reports, the specs its log printed.
    reports = Testor.Reports.summarize(id)
    log_specs = Files.log_specs(id)
    specs = if reports["specsFrom"], do: Testor.Reports.run_specs(id), else: log_specs
    log_summary = SpecParser.summary(log_specs)

    # Each spec file's outcome (and time, retries) is kept with the record: flaky specs and
    # hotspots are found across runs (Testor.Query) without reading every log again.
    run =
      run
      |> Map.put("summary", SpecParser.summary(specs))
      |> Map.put("specs", Enum.map(specs, &compact_spec/1))
      |> Map.merge(reports)
      |> then(
        &if(reports["specsFrom"] && log_summary["specs"] > 0 && log_summary != &1["summary"],
          do: Map.put(&1, "logSummary", log_summary),
          else: &1
        )
      )

    run =
      Map.put_new_lazy(run, "screenshots", fn ->
        id |> Files.screenshots() |> length()
      end)

    Files.write_json(Config.run_file(id), run)
    {%{state | sigs: Map.put(state.sigs, id, signature(id))}, run}
  end

  defp settle_run(state, id, status) do
    case get(id) do
      %{"status" => "running"} = run ->
        Logger.warning("store: #{id} #{status}")

        ended =
          case Files.mtime(Config.log_file(id)) do
            mtime when is_integer(mtime) and status == "aborted" -> DateTime.from_unix!(mtime)
            _ -> DateTime.utc_now()
          end

        run =
          Map.merge(run, %{
            "status" => status,
            "endedAt" => DateTime.to_iso8601(ended),
            "durationMs" => duration(run["startedAt"], ended)
          })

        {state, run} = finalize(state, run)
        :ets.insert(@table, {id, run})
        finished(id)
        on_finish(run)
        File.rm(Path.join(Config.cancel_dir(), id))
        {state, run}

      run ->
        {state, run}
    end
  end

  defp forget(state, id) do
    :ets.delete(@table, id)
    drop_live(id)
    Events.broadcast("global", "run_removed", %{"id" => id})
    Events.broadcast({"run", id}, "removed", %{"id" => id})
    %{state | sigs: Map.delete(state.sigs, id)}
  end

  @doc false
  def duration(started, %DateTime{} = ended) do
    case parse_time(started) do
      {:ok, started} -> DateTime.diff(ended, started, :millisecond)
      _ -> nil
    end
  end

  @doc "Parses PowerShell's round-trip time format, which has 7 fractional digits."
  def parse_time(text) when is_binary(text) do
    text = Regex.replace(~r/(\.\d{6})\d+/, text, "\\1")

    case DateTime.from_iso8601(text) do
      {:ok, time, _} -> {:ok, time}
      error -> error
    end
  end

  def parse_time(_), do: :error
end
