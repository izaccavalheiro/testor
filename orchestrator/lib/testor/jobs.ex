defmodule Testor.Jobs do
  @moduledoc """
  Jobs: runs asked for through the API (`POST /api/v1/jobs`) and taken by agents
  (`runner/agent.ps1`), which run them on their machine through run.ps1. Off until
  `execution.enabled` in config.json, and only with authentication on.

  A job names a project and a task (`kind`), never a command: the agent's own configuration
  maps them to the command it runs, so whoever owns a runner decides what can run on it. A job
  may also name `labels` an agent must have (`windows`, `gpu`, ...) and a git `ref` the agent
  checks out first, or a `snapshot` of the project (`Testor.Snapshots`) it materializes instead.

  The queue prefers the agent that ran a project last (its caches and snapshot are warm): a
  queued job waits up to `execution.warmSeconds` for it while it is polling, then goes to any.

      queued ──lease──▶ leased ──heartbeat──▶ running ──finish──▶ passed | failed | cancelled
         ▲                 │ lease expires (agent gone)
         └─────────────────┘ again, up to execution.maxAttempts; then expired

  An agent holds a job by its lease (`execution.leaseSeconds`, 30 by default) and renews it
  with heartbeats; a job whose lease runs out goes back to the queue. One job per project is
  leased at a time, so two runs never share a project's snapshot folder. Jobs are kept in
  `<home>/jobs/<id>.json` (`Testor.Jobs.FileStore`) and survive a restart; with
  `TESTOR_DATABASE_URL`, in PostgreSQL (`Testor.Jobs.Postgres`), shared by several testors.

  With `execution.queue`, a broker (SQS, NATS JetStream) dispatches them instead
  (`Testor.Queue`): the records stay here; the broker's message decides who takes a job, and
  its visibility follows the lease.
  """
  use GenServer
  require Logger
  alias Testor.{Config, Store}

  @sweep_ms 5_000
  @name ~r/^[A-Za-z0-9_.-]{1,100}$/
  @ref ~r/^[A-Za-z0-9_][A-Za-z0-9_.\/-]{0,199}$/
  @active ["leased", "running"]
  @statuses ["queued", "leased", "running", "passed", "failed", "cancelled", "expired"]
  @over ["passed", "failed", "cancelled", "expired"]
  # Who ran each project last, and when each agent last asked for a job (the lease hint).
  @warm :testor_jobs_warm

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def statuses, do: @statuses
  def dir, do: Testor.Jobs.FileStore.dir()

  @doc "The execution settings: `enabled`, `leaseSeconds`, `maxAttempts`."
  def settings, do: Config.retention()["execution"]

  # --- reads --------------------------------------------------------------------------------

  def get(id) do
    case __MODULE__ |> GenServer.call({:get, id}) |> public() do
      # A batch shows its shards.
      %{"batch" => true, "children" => ids} = job ->
        Map.put(
          job,
          "shardJobs",
          for(child <- ids, do: child |> get() |> Map.take(["id", "status", "shard", "runId", "agent"]))
        )

      job ->
        job
    end
  end

  @doc "Jobs, newest first, optionally with one status."
  def list(status \\ nil), do: __MODULE__ |> GenServer.call({:list, status}) |> Enum.map(&public/1)

  # The broker's receipt stays inside testor.
  defp public(nil), do: nil
  defp public(job), do: Map.delete(job, "dispatch")

  # --- writes -------------------------------------------------------------------------------

  @doc """
  Queues a job from `params` (`project`, `kind`, optional `labels` and `ref`) asked for by
  `who`: `{:ok, job}` or `{:error, reason}` (`:disabled`, or a message for a bad request).
  """
  def enqueue(params, who) do
    cfg = Testor.Queue.config()
    labels = params["labels"] || []
    queue = cfg && is_list(labels) && Testor.Queue.queue_for(cfg, labels)

    cond do
      cfg && is_list(labels) && queue == nil ->
        {:error, "no queue takes jobs with the labels #{Enum.join(labels, ", ")} (execution.queue.queues)"}

      true ->
        with {:ok, params} <- sized(params),
             {:ok, source} <- snapshot(params),
             {:ok, source} <- exec_claim(params, source, who) do
          source = params |> cached(source) |> plan(params) |> order(params)

          case GenServer.call(__MODULE__, {:enqueue, params, source, who}) do
            {:ok, job} when cfg != nil -> dispatch(cfg, queue, job)
            other -> other
          end
        end
    end
  end

  # Predictive sizing (Testor.Sizing): "shards": "auto" with a target becomes a number of
  # shards (or a plain job); a suggested profile, whose labels "profile": "auto" adds.
  defp sized(params) do
    project = params["project"]
    kind = params["kind"]

    with {:ok, params} <- auto_shards(params, project, kind) do
      case (is_binary(project) and is_binary(kind)) &&
             Testor.Sizing.profile(project, kind, settings()["profiles"]) do
        {name, labels} ->
          params = Map.put(params, "suggestedProfile", name)

          {:ok, if(params["profile"] == "auto", do: add_labels(params, labels), else: params)}

        _ ->
          {:ok, params}
      end
    end
  end

  defp add_labels(params, labels), do: Map.update(params, "labels", labels, &(List.wrap(&1) ++ labels))

  defp auto_shards(%{"shards" => "auto"} = params, project, kind) do
    with n when is_integer(n) <-
           seconds(params["target"]) ||
             {:error, "shards auto needs a target: the time a shard should take (10m)"},
         true <- (is_binary(project) and is_binary(kind)) || {:error, "project and kind are names"},
         {:ok, shards} <- Testor.Sizing.shards(project, kind, n, capacity()["slots"]) do
      {:ok, if(shards > 1, do: Map.put(params, "shards", shards), else: Map.delete(params, "shards"))}
    else
      :error -> {:error, "target is seconds (1 to 86400) or 90s, 45m, 2h"}
      error -> error
    end
  end

  defp auto_shards(params, _project, _kind), do: {:ok, params}

  # A job's snapshot, read before it is queued: its id, the branch and commit it is of, and with
  # select.affected the files that changed since its base.
  defp snapshot(%{"snapshot" => id, "project" => project})
       when is_binary(id) and is_binary(project) do
    with {:ok, hex} <- Testor.Snapshots.parse_id(id),
         true <- name?(project),
         {:ok, manifest} <- Testor.Snapshots.manifest(project, hex) do
      source = Map.take(manifest, ["branch", "commit"]) |> Map.put("snapshot", id)

      # What changed since the branch's last snapshot: the runs' changedFiles (impact analysis),
      # and select.affected's files.
      case Testor.Snapshots.changed(project, hex, manifest["branch"]) do
        {:ok, paths} -> {:ok, Map.put(source, "changed", paths)}
        :none -> {:ok, source}
      end
    else
      _ -> {:error, "snapshot is the id of a snapshot of this project (sha256:<hex>)"}
    end
  end

  defp snapshot(%{"snapshot" => nil}), do: {:ok, %{}}
  defp snapshot(%{"watch" => true}), do: {:error, "a watch session runs a snapshot"}

  defp snapshot(%{"snapshot" => _}),
    do: {:error, "snapshot is the id of a snapshot of this project (sha256:<hex>)"}

  defp snapshot(_params), do: {:ok, %{}}

  # Exec mode: a job that carries its argv, with a claim testor signs (its job-token key) of who
  # asked and the argv's hash, which the agent checks against its own list of subjects.
  defp exec_claim(%{"argv" => argv} = params, source, who) when is_list(argv) do
    case argv?(argv) && Testor.Auth.settings() do
      false ->
        # new_job/2 says what is wrong with it.
        {:ok, source}

      %{job_token_keys: %{signing: signing}} ->
        now = System.system_time(:second)

        claims = %{
          "iss" => "testor",
          "sub" => "user:" <> who,
          "project" => params["project"],
          "argv_sha256" => argv_hash(argv),
          "iat" => now,
          "exp" => now + 86_400,
          "jti" => Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
        }

        {:ok, Map.put(source, "claim", Testor.Auth.JobTokens.sign(claims, signing))}

      _ ->
        {:error, "exec mode needs jobTokens in auth.json: their key signs who asked"}
    end
  end

  defp exec_claim(_params, source, _who), do: {:ok, source}

  @doc "The SHA-256 of an argv, as the exec claim holds it: of its arguments joined by NUL (UTF-8)."
  def argv_hash(argv), do: :crypto.hash(:sha256, Enum.join(argv, <<0>>)) |> Base.encode16(case: :lower)

  # A result the cache holds for this job (Testor.ResultCache): the job is answered with it.
  defp cached(%{"snapshot" => _} = params, %{"snapshot" => _} = source) do
    with false <- params["cache"] == false or params["clean"] == true or params["watch"] == true,
         {:ok, select} <- Testor.Select.check(params["select"]),
         probe = %{
           "snapshot" => source["snapshot"],
           "project" => params["project"],
           "kind" => params["kind"],
           "argv" => params["argv"],
           "select" => select,
           "labels" => Enum.uniq(params["labels"] || [])
         },
         {:ok, hit} <- Testor.ResultCache.lookup(probe) do
      run = (get(hit["job"]) || %{})["runId"]
      Map.put(source, "cached", Map.put(hit, "runId", run))
    else
      _ -> source
    end
  end

  defp cached(_params, source), do: source

  # A snapshot batch's weighted plan (Testor.Shards): the files of each shard, when every shard
  # gets some.
  defp plan(source, %{"shards" => n, "project" => project, "kind" => kind})
       when is_integer(n) and n in 2..64 do
    with "sha256:" <> hex <- source["snapshot"],
         {:ok, manifest} <- Testor.Snapshots.manifest(project, hex),
         [_ | _] = weighted <- Testor.Shards.weighted(project, kind, manifest),
         bins = Testor.Shards.plan(weighted, n),
         true <- Enum.all?(bins, &(&1 != [])) do
      Map.put(source, "plan", bins)
    else
      _ -> source
    end
  end

  defp plan(source, _params), do: source

  # "order": "impact": the spec files ranked for the change (Testor.Impact), for the agent's
  # TESTOR_TEST_ORDER; "impact": {"first": n} runs the first n alone, then the rest.
  defp order(source, %{"order" => "impact", "project" => project}) do
    ranked = Testor.Impact.rank(project, source["changed"] || [], 2_000) |> Enum.map(& &1["file"])
    if ranked == [], do: source, else: Map.put(source, "testOrder", ranked)
  end

  defp order(source, _params), do: source

  # The broker's message for a new job; a job the broker refused is not left queued.
  defp dispatch(cfg, queue, job) do
    case Testor.Queue.call(cfg, "enqueue", fn -> cfg.adapter.enqueue(cfg, queue, job) end) do
      :ok ->
        {:ok, job}

      {:error, _} ->
        GenServer.call(__MODULE__, {:undispatched, job["id"]})
        {:error, :queue_unavailable}
    end
  end

  @doc """
  The oldest queued job `agent` (with `labels`) can take, leased to it: `{:ok, job}` or `:none`.
  `allow` says which projects the agent may take (an agent user restricted to projects);
  `instance` tells apart agents that share a user (pods of one chart), for the warm hint.
  """
  def lease(agent, labels, allow \\ fn _project -> true end, instance \\ nil) do
    case Testor.Queue.config() do
      nil -> GenServer.call(__MODULE__, {:lease, agent, labels, allow, instance || agent})
      cfg -> lease_from(cfg, Testor.Queue.queues_for(cfg, labels), agent, labels, allow, 10)
    end
  end

  # A message from the agent's queues, in order. Its job is leased when it is still queued and
  # this agent may take it; a job that is gone (cancelled, ended) has its message deleted; one
  # whose project is busy or that this agent may not take is put back for another.
  defp lease_from(_cfg, [], _agent, _labels, _allow, _tries), do: :none

  defp lease_from(cfg, [_ | rest], agent, labels, allow, 0),
    do: lease_from(cfg, rest, agent, labels, allow, 10)

  defp lease_from(cfg, [queue | rest] = queues, agent, labels, allow, tries) do
    seconds = settings()["leaseSeconds"]

    case Testor.Queue.call(cfg, "receive", fn -> cfg.adapter.receive(cfg, queue, seconds) end) do
      {:ok, %{id: id, receipt: receipt}} ->
        dispatch = %{"queue" => queue.name, "receipt" => receipt}

        case GenServer.call(__MODULE__, {:lease_id, agent, labels, allow, id, dispatch}) do
          {:ok, job} ->
            {:ok, public(job)}

          :gone ->
            Testor.Queue.call(cfg, "ack", fn -> cfg.adapter.ack(cfg, queue, receipt) end)
            lease_from(cfg, queues, agent, labels, allow, tries - 1)

          :later ->
            Testor.Queue.call(cfg, "release", fn -> cfg.adapter.release(cfg, queue, receipt) end)
            lease_from(cfg, rest, agent, labels, allow, 10)
        end

      _ ->
        lease_from(cfg, rest, agent, labels, allow, 10)
    end
  end

  @doc "Renews `agent`'s lease on job `id`: `{:ok, %{\"cancel\" => bool}}` or `{:error, reason}`."
  def heartbeat(id, agent) do
    case GenServer.call(__MODULE__, {:heartbeat, id, agent}) do
      {:ok, reply, dispatch} ->
        broker(dispatch, fn cfg, queue, receipt ->
          cfg.adapter.extend(cfg, queue, receipt, settings()["leaseSeconds"])
        end)

        {:ok, reply}

      error ->
        error
    end
  end

  @doc "Ends job `id` for `agent` with `result` (`exitCode`, optional `error`)."
  def finish(id, agent, result) do
    case GenServer.call(__MODULE__, {:finish, id, agent, result}) do
      {:ok, job} ->
        broker(job["dispatch"], fn cfg, queue, receipt -> cfg.adapter.ack(cfg, queue, receipt) end)
        Testor.ResultCache.record(job, result, job["status"])
        if job["parent"], do: Task.start(fn -> Testor.Batches.settle(job["parent"]) end)
        {:ok, public(job)}

      error ->
        error
    end
  end

  # A broker call on the message a job was dispatched with, when there is a broker and the
  # queue is still configured.
  defp broker(%{"queue" => name, "receipt" => receipt}, fun) do
    with %{} = cfg <- Testor.Queue.config(),
         %{} = queue <- Enum.find(cfg.queues, &(&1.name == name)) do
      Testor.Queue.call(cfg, "message", fn -> fun.(cfg, queue, receipt) end)
    end
  end

  defp broker(_dispatch, _fun), do: nil

  @doc """
  Cancels job `id`: a queued job at once; a job an agent holds is marked, the agent hears it at
  its next heartbeat, and its run (when there is one) is cancelled the usual way.
  """
  def cancel(id) do
    case request_cancel(id) do
      {:ok, %{"batch" => true, "children" => children} = job} ->
        Enum.each(children, &cancel/1)
        Task.start(fn -> Testor.Batches.settle(id) end)
        {:ok, job}

      {:ok, %{"runId" => run} = job} when is_binary(run) ->
        # A run on this machine is cancelled here; a remote one by its agent, which hears it
        # at its next heartbeat.
        if not is_binary(get_in(Store.get(run) || %{}, ["remote"])), do: Testor.Web.Actions.cancel(run)
        {:ok, job}

      other ->
        other
    end
  end

  @doc "Marks job `id` cancelled (queued) or to be cancelled (held), without touching its run."
  def request_cancel(id), do: GenServer.call(__MODULE__, {:cancel, id})

  @doc "Job `id` when `agent` holds it: `{:ok, job}` or `{:error, :not_found | :not_yours | :ended}`."
  def held(id, agent), do: GenServer.call(__MODULE__, {:held, id, agent})

  @doc """
  Binds run `run` to job `id` held by `agent` (a remote agent's first record of it): `{:ok, job}`,
  or `{:error, :other_run}` when the job already has another run.
  """
  def bind_run(id, agent, run), do: GenServer.call(__MODULE__, {:bind_run, id, agent, run})

  @doc "Removes every job (tests)."
  def reset, do: GenServer.call(__MODULE__, :reset)

  @doc "Sweeps leases as at `now` (Unix seconds); the timer does it every few seconds."
  def sweep_now(now), do: GenServer.call(__MODULE__, {:sweep, now})

  @doc "What an agent says of itself when it asks for a job: its labels, slots and busy ones."
  def seen(who, labels, slots, busy),
    do: :ets.insert(@warm, {{:agent, who}, System.os_time(:second), labels, slots, busy})

  @doc """
  The agents seen in the last minute (per label), their slots and free ones, the queued jobs
  (per label), and the wait estimated from the last leases (the median, in seconds).
  """
  def capacity do
    now = System.os_time(:second)

    agents =
      for {{:agent, _}, at, labels, slots, busy} <- :ets.tab2list(@warm),
          now - at <= 60,
          do: {labels, slots, busy}

    jobs = list()
    queued = Enum.filter(jobs, &(&1["status"] == "queued"))

    waits =
      for %{"leasedAt" => leased, "createdAt" => created} <- Enum.take(jobs, 50),
          {:ok, l, _} <- [DateTime.from_iso8601(leased)],
          {:ok, c, _} <- [DateTime.from_iso8601(created)],
          do: max(DateTime.diff(l, c, :millisecond), 0) / 1000

    %{
      "agents" => length(agents),
      "agentsByLabel" => agents |> Enum.flat_map(&elem(&1, 0)) |> Enum.frequencies(),
      "slots" => agents |> Enum.map(&elem(&1, 1)) |> Enum.sum(),
      "freeSlots" => agents |> Enum.map(fn {_, slots, busy} -> max(slots - busy, 0) end) |> Enum.sum(),
      "queued" => length(queued),
      "queuedByLabel" => queued |> Enum.flat_map(& &1["labels"]) |> Enum.frequencies(),
      "estimatedWaitSeconds" =>
        if(waits == [], do: nil, else: Float.round(Testor.Shards.percentile(waits, 50) * 1.0, 1))
    }
  end

  @doc "Claims batch `id`'s merge: `:ok` once, `:taken` after."
  def claim_batch(id), do: GenServer.call(__MODULE__, {:batch, id, :claim})

  @doc "Ends batch `id` with `status` and its merged run."
  def end_batch(id, status, run), do: GenServer.call(__MODULE__, {:batch, id, {:end, status, run}})

  @doc "A watch session's new snapshot, from its client: `{:ok, job}` or `{:error, :not_found | :ended}`."
  def watch_change(id, snapshot), do: GenServer.call(__MODULE__, {:watch, id, snapshot})

  @doc "A watch session's client is still there."
  def watch_seen(id), do: GenServer.call(__MODULE__, {:watch, id, nil})

  @doc "Job `id` as stored, without the run reads link to it (tests)."
  def stored(id), do: GenServer.call(__MODULE__, {:stored, id})

  # --- server -------------------------------------------------------------------------------

  # The state is the backend and its own: files (one testor) or PostgreSQL (several).
  @impl true
  def init(nil) do
    backend = if Testor.Jobs.Postgres.enabled?(), do: Testor.Jobs.Postgres, else: Testor.Jobs.FileStore
    if :ets.whereis(@warm) == :undefined, do: :ets.new(@warm, [:named_table, :public])
    Process.send_after(self(), :sweep, @sweep_ms)
    {:ok, {backend, backend.init()}}
  end

  @impl true
  def handle_call({:get, id}, _from, state) do
    transact(state, {:id, id}, fn jobs -> {jobs |> Map.get(id) |> with_run(runs_by_job()), []} end)
  end

  def handle_call({:stored, id}, _from, state), do: transact(state, {:id, id}, &{Map.get(&1, id), []})

  def handle_call({:list, status}, _from, state) do
    transact(state, {:all, status}, fn jobs ->
      index = runs_by_job()

      list =
        jobs
        |> Map.values()
        |> Enum.filter(&(status == nil or &1["status"] == status))
        |> Enum.sort_by(&order/1, :desc)
        |> Enum.map(&with_run(&1, index))

      {list, []}
    end)
  end

  def handle_call({:enqueue, params, source, who}, _from, state) do
    with true <- settings()["enabled"] == true || {:error, :disabled},
         {:ok, job} <- new_job(params, who),
         job = with_source(job, source) do
      Logger.info("jobs: #{job["id"]} queued (#{job["project"]} #{job["kind"]}) by #{who}")
      jobs = if job["shards"], do: batch(job, source["plan"]), else: [job]
      transact(state, :none, fn _ -> {{:ok, with_children(hd(jobs), tl(jobs))}, jobs} end)
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:lease, agent, labels, allow, who}, _from, state) do
    now = System.monotonic_time(:millisecond)
    :ets.insert(@warm, {{:seen, who}, now, labels})

    transact(state, :open, fn jobs ->
      busy =
        for {_, %{"status" => s, "project" => p} = j} <- jobs,
            s in @active,
            into: MapSet.new(),
            do: {p, j["workspace"]}

      candidate =
        jobs
        |> Map.values()
        |> Enum.filter(
          &(&1["status"] == "queued" and not MapSet.member?(busy, {&1["project"], &1["workspace"]}) and
              allow.(&1["project"]))
        )
        |> Enum.filter(&Enum.all?(&1["labels"], fn label -> label in labels end))
        |> Enum.reject(&warm_elsewhere?(&1, who, now))
        |> Enum.min_by(&order/1, fn -> nil end)

      case candidate do
        nil ->
          {:none, []}

        job ->
          # Busy now: no job waits for it until it asks again.
          :ets.insert(@warm, {{:last, job["project"]}, who})
          :ets.delete(@warm, {:seen, who})
          job = take(job, agent)
          {{:ok, job}, [job]}
      end
    end)
  end

  # A job a broker's message names: leased when it is still queued and this agent may take it.
  def handle_call({:lease_id, agent, labels, allow, id, dispatch}, _from, state) do
    transact(state, :open, fn jobs ->
      busy =
        for {_, %{"status" => s, "project" => p} = j} <- jobs,
            s in @active,
            into: MapSet.new(),
            do: {p, j["workspace"]}

      case Map.get(jobs, id) do
        %{"status" => "queued"} = job ->
          if allow.(job["project"]) and Enum.all?(job["labels"], &(&1 in labels)) and
               not MapSet.member?(busy, {job["project"], job["workspace"]}) do
            job = take(job, agent) |> Map.put("dispatch", dispatch)
            {{:ok, job}, [job]}
          else
            {:later, []}
          end

        _ ->
          {:gone, []}
      end
    end)
  end

  # A job the broker would not take: ended, with why.
  def handle_call({:undispatched, id}, _from, state) do
    transact(state, {:id, id}, fn jobs ->
      job =
        Map.merge(jobs[id], %{
          "status" => "cancelled",
          "error" => "the queue did not take it",
          "endedAt" => now_iso()
        })

      {:ok, [job]}
    end)
  end

  def handle_call({:heartbeat, id, agent}, _from, state) do
    transact(state, {:id, id}, fn jobs ->
      case held(jobs, id, agent) do
        {:ok, job} ->
          job = Map.merge(job, %{"status" => "running", "leaseUntil" => lease_until()})
          job = Map.put_new(job, "startedAt", now_iso()) |> link_run()
          {{:ok, %{"cancel" => job["cancelRequested"] == true}, job["dispatch"]}, [job]}

        error ->
          {error, []}
      end
    end)
  end

  def handle_call({:finish, id, agent, result}, _from, state) do
    transact(state, {:id, id}, fn jobs ->
      with {:ok, job} <- held(jobs, id, agent) do
        if result["preempted"] == true and job["cancelRequested"] != true,
          do: preempted(job, agent),
          else: finished(job, agent, result)
      else
        error -> {error, []}
      end
    end)
  end

  def handle_call({:held, id, agent}, _from, state),
    do: transact(state, {:id, id}, &{held(&1, id, agent), []})

  def handle_call({:bind_run, id, agent, run}, _from, state) do
    transact(state, {:id, id}, fn jobs ->
      case held(jobs, id, agent) do
        {:ok, %{"runId" => ^run} = job} -> {{:ok, job}, []}
        {:ok, %{"runId" => _}} -> {{:error, :other_run}, []}
        {:ok, job} -> job |> Map.put("runId", run) |> then(&{{:ok, &1}, [&1]})
        error -> {error, []}
      end
    end)
  end

  def handle_call({:cancel, id}, _from, state) do
    transact(state, {:id, id}, fn jobs ->
      case Map.get(jobs, id) do
        nil ->
          {{:error, :not_found}, []}

        %{"status" => "queued"} = job ->
          job = Map.merge(job, %{"status" => "cancelled", "endedAt" => now_iso()})
          {{:ok, job}, [job]}

        %{"status" => status} = job when status in @active ->
          job = job |> Map.put("cancelRequested", true) |> link_run()
          {{:ok, job}, [job]}

        _ ->
          {{:error, :ended}, []}
      end
    end)
  end

  def handle_call(:reset, _from, {backend, state}) do
    :ets.delete_all_objects(@warm)
    {:reply, :ok, {backend, backend.clear(state)}}
  end

  def handle_call({:sweep, now}, _from, state) do
    {:reply, _, state} = sweep(state, now)
    {:reply, :ok, end_idle(state, now)}
  end

  def handle_call({:batch, id, what}, _from, state) do
    transact(state, {:id, id}, fn jobs ->
      case {Map.get(jobs, id), what} do
        # Claimed once: a running batch no one merges yet; any other is taken.
        {%{"batch" => true, "status" => "running"} = job, :claim} when not is_map_key(job, "merging") ->
          job = Map.put(job, "merging", true)
          {:ok, [job]}

        {%{"batch" => true}, :claim} ->
          {:taken, []}

        {%{"batch" => true} = job, {:end, status, run}} ->
          job =
            job
            |> Map.merge(%{
              "status" => status,
              "exitCode" => if(status == "passed", do: 0, else: 1),
              "endedAt" => now_iso(),
              "runId" => run
            })
            |> Map.delete("merging")

          {{:ok, job}, [job]}
      end
    end)
  end

  def handle_call({:watch, id, snapshot}, _from, state) do
    transact(state, {:id, id}, fn jobs ->
      case Map.get(jobs, id) do
        %{"watch" => true, "status" => s} = job when s not in @over ->
          job = Map.put(job, "lastSeen", System.os_time(:second))
          job = if snapshot, do: Map.merge(job, %{"snapshot" => snapshot, "seq" => job["seq"] + 1}), else: job
          {{:ok, job}, [job]}

        %{"watch" => true} ->
          {{:error, :ended}, []}

        _ ->
          {{:error, :not_found}, []}
      end
    end)
  end

  @impl true
  def handle_info(:sweep, state) do
    Process.send_after(self(), :sweep, @sweep_ms)
    now = System.os_time(:second)
    {:reply, _, state} = sweep(state, now)
    {:noreply, end_idle(state, now)}
  end

  # Jobs whose agent stopped renewing its lease go back to the queue, or expire after the
  # last attempt; their runs (a remote one has no process here to watch) end with them.
  defp sweep(state, now) do
    max = settings()["maxAttempts"]

    reply =
      transact(state, :open, fn jobs ->
        changed =
          for {_, %{"status" => s, "leaseUntil" => until} = job} <- jobs, s in @active and until < now do
            {status, note} =
              if job["attempts"] < max and job["cancelRequested"] != true,
                do: {"queued", "its agent stopped answering; queued again"},
                else: {"expired", "its agent stopped answering"}

            Logger.warning("jobs: #{job["id"]} #{note} (#{job["agent"]})")

            job
            |> Map.merge(%{"status" => status, "error" => note})
            |> Map.drop(["leaseUntil", "agent", "runId", "dispatch"])
            |> then(&if(status == "expired", do: Map.put(&1, "endedAt", now_iso()), else: &1))
          end

        runs = for job <- changed, run = get_in(jobs, [job["id"], "runId"]), is_binary(run), do: run
        # An expired job's message goes; a requeued one's comes back on its own (its visibility
        # was the lease).
        gone =
          for job <- changed,
              job["status"] == "expired",
              d = get_in(jobs, [job["id"], "dispatch"]),
              d != nil,
              do: d

        parents = for %{"status" => "expired", "parent" => p} <- changed, do: p
        {{runs, gone, parents}, changed}
      end)

    {:reply, result, state} = reply
    # PostgreSQL out of reach answers {:error, :unavailable}: nothing to settle then.
    {runs, gone, parents} = if match?({runs, _, _} when is_list(runs), result), do: result, else: {[], [], []}
    Enum.each(runs, &Store.settle(&1, "aborted"))
    # A batch whose last shard expired ends now.
    if parents != [], do: Task.start(fn -> parents |> Enum.uniq() |> Enum.each(&Testor.Batches.settle/1) end)

    if gone != [],
      do: Task.start(fn -> Enum.each(gone, &broker(&1, fn cfg, q, r -> cfg.adapter.ack(cfg, q, r) end)) end)

    {:reply, runs, state}
  end

  # Watch sessions whose client stopped calling for execution.watchIdleMinutes (15) end.
  defp end_idle(state, now) do
    idle = settings()["watchIdleMinutes"] * 60

    {:reply, ids, state} =
      transact(state, :open, fn jobs ->
        {for({id, %{"watch" => true, "lastSeen" => seen}} <- jobs, now - seen > idle, do: id), []}
      end)

    if is_list(ids) and ids != [], do: Task.start(fn -> Enum.each(ids, &cancel/1) end)
    state
  end

  # Runs `fun` on the jobs `scope` names in the backend, saves those it changed, and tells
  # about them (the job event; the trace of one that ended).
  defp transact({backend, state}, scope, fun) do
    {reply, before, changed, state} = backend.transaction(state, scope, fun)

    for job <- changed do
      if job["status"] in @over and get_in(before, [job["id"], "status"]) not in @over,
        do: Testor.Tracing.job_ended(job)

      Testor.Events.broadcast("global", "job", job)
    end

    {:reply, reply, {backend, state}}
  end

  # Its agent was evicted (a spot notice, a drain): queued again without spending an attempt, up
  # to execution.maxPreemptions times.
  defp preempted(job, agent) do
    count = (job["preemptions"] || 0) + 1

    job =
      if count > settings()["maxPreemptions"] do
        Map.merge(job, %{"status" => "failed", "error" => "preempted #{count} times", "endedAt" => now_iso()})
      else
        Map.merge(job, %{"status" => "queued", "attempts" => job["attempts"] - 1})
        |> Map.drop(["agent", "leaseUntil", "leasedAt", "runId", "dispatch"])
      end
      |> Map.put("preemptions", count)

    Logger.warning("jobs: #{job["id"]} preempted on #{agent} (#{count}): #{job["status"]}")
    {{:ok, job}, [job]}
  end

  defp finished(job, agent, result) do
    exit_code = if is_integer(result["exitCode"]), do: result["exitCode"], else: nil

    status =
      cond do
        job["cancelRequested"] == true -> "cancelled"
        exit_code == 0 and result["error"] == nil -> "passed"
        true -> "failed"
      end

    job =
      job
      |> Map.merge(%{"status" => status, "exitCode" => exit_code, "endedAt" => now_iso()})
      |> put_if("error", short(result["error"]))
      |> Map.delete("leaseUntil")
      |> link_run()

    Logger.info("jobs: #{job["id"]} #{status} on #{agent}")
    {{:ok, job}, [job]}
  end

  # --- helpers ------------------------------------------------------------------------------

  # A job another agent ran the project of last: while that agent is idle (polling) and could
  # take it, the job waits warmSeconds for it.
  defp warm_elsewhere?(job, agent, now) do
    wait = (settings()["warmSeconds"] || 0) * 1000

    with true <- wait > 0,
         [{_, last}] when last != agent <- :ets.lookup(@warm, {:last, job["project"]}),
         [{_, seen, labels}] <- :ets.lookup(@warm, {:seen, last}),
         true <- now - seen < 5_000 and Enum.all?(job["labels"], &(&1 in labels)),
         {:ok, created, _} <- DateTime.from_iso8601(job["createdAt"]) do
      DateTime.diff(DateTime.utc_now(), created, :millisecond) < wait
    else
      _ -> false
    end
  end

  defp take(job, agent) do
    job =
      Map.merge(job, %{
        "status" => "leased",
        "agent" => agent,
        "attempts" => job["attempts"] + 1,
        "leasedAt" => now_iso(),
        "leaseUntil" => lease_until()
      })

    Logger.info("jobs: #{job["id"]} leased to #{agent} (attempt #{job["attempts"]})")
    job
  end

  defp new_job(params, who) do
    case Testor.Select.check(params["select"]) do
      {:ok, select} -> new_job(params, select, who)
      error -> error
    end
  end

  defp new_job(params, select, who) do
    labels = params["labels"] || []
    ref = params["ref"]
    argv = params["argv"]

    cond do
      not name?(params["project"]) ->
        {:error, "project is a name: letters, digits, _ . -"}

      not name?(params["kind"]) ->
        {:error, "kind is a name: letters, digits, _ . -"}

      not (is_list(labels) and Enum.all?(labels, &name?/1)) ->
        {:error, "labels is a list of names"}

      ref != nil and not ref?(ref) ->
        {:error, "ref is a git branch, tag or commit"}

      ref != nil and params["snapshot"] != nil ->
        {:error, "a job names a ref or a snapshot, not both"}

      params["traceparent"] != nil and Testor.Tracing.parse(params["traceparent"]) == :error ->
        {:error, "traceparent is a W3C trace context (00-<trace id>-<span id>-<flags>)"}

      params["clean"] not in [nil, true, false] ->
        {:error, "clean is true or false"}

      seconds(params["timeout"]) == :error ->
        {:error, "timeout is seconds (1 to 86400) or 90s, 45m, 2h"}

      params["workspace"] != nil and not name?(params["workspace"]) ->
        {:error, "workspace is a name: letters, digits, _ . -"}

      Enum.any?(["failFast", "cache"], &(params[&1] not in [nil, true, false])) ->
        {:error, "failFast and cache are true or false"}

      params["watch"] not in [nil, true] ->
        {:error, "watch is true"}

      argv != nil and not argv?(argv) ->
        {:error, "argv is a list of 1 to 100 arguments (4000 bytes each, no NUL)"}

      params["shards"] != nil and not (is_integer(params["shards"]) and params["shards"] in 2..64) ->
        {:error, "shards is a number of shards, 2 to 64"}

      params["shards"] != nil and (select != nil or argv != nil or params["watch"] == true) ->
        {:error, "a batch takes no select, argv or watch: its shards get their files"}

      params["profile"] not in [nil, "auto"] ->
        {:error, ~s(profile is "auto": the suggested profile's labels)}

      params["order"] not in [nil, "impact"] ->
        {:error, ~s(order is "impact")}

      params["impact"] != nil and
          not match?(%{"first" => n} when is_integer(n) and n in 1..2000, params["impact"]) ->
        {:error, "impact is {first: n}: the n first-ranked specs alone, then the rest"}

      select["affected"] && params["snapshot"] == nil ->
        {:error, "select.affected needs a snapshot (its changes are counted from the branch's last one)"}

      true ->
        job =
          build(params["project"], params["kind"], Enum.uniq(labels), ref, who)
          # The agent drops the project's preserved caches first (agent.json's "preserve").
          |> then(&if(params["clean"] == true, do: Map.put(&1, "clean", true), else: &1))
          |> put_timeout(params["timeout"] || settings()["defaultTimeout"])
          |> put_if("select", select)
          |> put_if("argv", argv)
          |> put_if("workspace", params["workspace"])
          |> put_if("failFast", if(params["failFast"] == true, do: true))
          |> put_if("cache", if(params["cache"] == false, do: false))
          |> put_if("shards", params["shards"])
          |> put_if("suggestedProfile", params["suggestedProfile"])
          |> put_if("impact", params["impact"])
          |> then(
            &if(params["watch"] == true,
              do: Map.merge(&1, %{"watch" => true, "seq" => 0, "lastSeen" => System.os_time(:second)}),
              else: &1
            )
          )

        {:ok, Map.merge(job, Testor.Tracing.job_fields(params["traceparent"]))}
    end
  end

  defp build(project, kind, labels, ref, who) do
    stamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d-%H%M%S")
    id = "job-#{stamp}-#{:crypto.strong_rand_bytes(3) |> Base.encode16(case: :lower)}"

    %{
      "id" => id,
      "project" => project,
      "kind" => kind,
      "labels" => labels,
      "status" => "queued",
      "attempts" => 0,
      "requestedBy" => who,
      # To the microsecond: the queue's order (ids made in one second sort by chance).
      "createdAt" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
    |> put_if("ref", ref)
  end

  defp order(job), do: {job["createdAt"], job["id"]}

  # A batch: the parent (running from the start, never leased, ended by Testor.Batches) and its
  # shards, each a job of its own workspace with its index and, from a plan, its files.
  defp batch(job, plan) do
    n = job["shards"]

    children =
      for i <- 1..n do
        job
        |> Map.drop(["shards"])
        |> Map.merge(%{
          "id" => "#{job["id"]}-s#{i}",
          "parent" => job["id"],
          "shard" => %{"index" => i, "total" => n},
          "workspace" => "#{job["workspace"] || "shard"}-#{i}"
        })
        |> then(&if(plan, do: Map.put(&1, "select", %{"files" => Enum.at(plan, i - 1)}), else: &1))
      end

    parent =
      Map.merge(job, %{
        "batch" => true,
        "status" => "running",
        "startedAt" => now_iso(),
        "children" => Enum.map(children, & &1["id"])
      })
      |> then(&if(plan, do: Map.put(&1, "plan", plan), else: &1))

    [parent | children]
  end

  defp with_children(job, []), do: job

  defp with_children(job, children),
    do: Map.put(job, "shardJobs", Enum.map(children, &Map.take(&1, ["id", "status", "shard"])))

  # What enqueue/2 read before the job was made: its snapshot, the changed files, the exec
  # claim, a cached result (the job is then over at once).
  defp with_source(job, source) do
    {changed, source} = Map.pop(source, "changed")
    {hit, source} = Map.pop(source, "cached")
    {_plan, source} = Map.pop(source, "plan")
    job = Map.merge(job, source)
    job = if changed, do: Map.put(job, "changedFiles", Enum.take(changed, 1000)), else: job
    job = if changed && job["select"]["affected"], do: put_in(job, ["select", "changed"], changed), else: job

    case hit do
      nil ->
        job

      hit ->
        Map.merge(job, %{
          "status" => hit["status"],
          "exitCode" => hit["exitCode"],
          "cached" => %{"job" => hit["job"]},
          "endedAt" => now_iso()
        })
        |> put_if("runId", hit["runId"])
    end
  end

  # The longest the run may take, as data: the agent's own timeout for the task caps it
  # (execution.defaultTimeout when the job names none).
  defp put_timeout(job, value) do
    case seconds(value) do
      n when is_integer(n) -> Map.put(job, "timeout", n)
      _ -> job
    end
  end

  @doc false
  # A timeout: seconds (1 to a day), or "90s", "45m", "2h"; nil for none, :error otherwise.
  def seconds(nil), do: nil
  def seconds(n) when is_integer(n) and n >= 1 and n <= 86_400, do: n

  def seconds(text) when is_binary(text) do
    case Regex.run(~r/^(\d+)(s|m|h)?$/, text) do
      [_, n | unit] ->
        seconds(String.to_integer(n) * %{[] => 1, ["s"] => 1, ["m"] => 60, ["h"] => 3600}[unit])

      nil ->
        :error
    end
  end

  def seconds(_), do: :error

  defp name?(value), do: is_binary(value) and Regex.match?(@name, value)

  defp argv?(argv) do
    is_list(argv) and length(argv) in 1..100 and
      Enum.all?(argv, &(is_binary(&1) and byte_size(&1) in 1..4000 and not String.contains?(&1, <<0>>)))
  end

  @doc "Whether `value` is a git branch, tag or commit as a job may name it."
  def ref?(value), do: is_binary(value) and Regex.match?(@ref, value)

  defp held(jobs, id, agent) do
    case Map.get(jobs, id) do
      nil -> {:error, :not_found}
      %{"status" => s, "agent" => ^agent} = job when s in @active -> {:ok, job}
      %{"status" => s} when s in @active -> {:error, :not_yours}
      _ -> {:error, :ended}
    end
  end

  # A quick job can end before the store has read its run's record: reads link it as soon as
  # the store has it.
  # Oldest first, so a job tried again shows its newest run.
  defp runs_by_job do
    for %{"job" => job, "id" => run} when is_binary(job) <- Enum.reverse(Store.all()),
        into: %{},
        do: {job, run}
  end

  defp with_run(nil, _index), do: nil
  defp with_run(%{"runId" => _} = job, _index), do: job

  defp with_run(job, index) do
    case Map.get(index, job["id"]) do
      nil -> job
      run -> Map.put(job, "runId", run)
    end
  end

  # The run run.ps1 recorded for this job (it records the job's id from TESTOR_JOB_ID).
  defp link_run(%{"runId" => _} = job), do: job

  defp link_run(job) do
    case Enum.find(Store.all(), &(&1["job"] == job["id"])) do
      nil -> job
      run -> Map.put(job, "runId", run["id"])
    end
  end

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)

  defp short(nil), do: nil
  defp short(text) when is_binary(text), do: String.slice(text, 0, 500)
  defp short(other), do: short(inspect(other))

  defp lease_until, do: System.os_time(:second) + settings()["leaseSeconds"]
  defp now_iso, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
