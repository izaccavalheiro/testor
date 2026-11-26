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

  def get(id), do: __MODULE__ |> GenServer.call({:get, id}) |> public()

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
        with {:ok, source} <- snapshot(params),
             {:ok, source} <- exec_claim(params, source, who) do
          source = cached(params, source)

          case GenServer.call(__MODULE__, {:enqueue, params, source, who}) do
            {:ok, job} when cfg != nil -> dispatch(cfg, queue, job)
            other -> other
          end
        end
    end
  end

  # A job's snapshot, read before it is queued: its id, the branch and commit it is of, and with
  # select.affected the files that changed since its base.
  defp snapshot(%{"snapshot" => id, "project" => project} = params)
       when is_binary(id) and is_binary(project) do
    with {:ok, hex} <- Testor.Snapshots.parse_id(id),
         true <- name?(project),
         {:ok, manifest} <- Testor.Snapshots.manifest(project, hex) do
      source = Map.take(manifest, ["branch", "commit"]) |> Map.put("snapshot", id)

      case params["select"] do
        %{"affected" => a} when a in [true, "then-all"] ->
          case Testor.Snapshots.changed(project, hex, manifest["branch"]) do
            {:ok, paths} -> {:ok, Map.put(source, "changed", paths)}
            :none -> {:ok, source}
          end

        _ ->
          {:ok, source}
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
      transact(state, :none, fn _ -> {{:ok, job}, [job]} end)
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

        Logger.info("jobs: #{id} #{status} on #{agent}")
        {{:ok, job}, [job]}
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

        {{runs, gone}, changed}
      end)

    {:reply, result, state} = reply
    # PostgreSQL out of reach answers {:error, :unavailable}: nothing to settle then.
    {runs, gone} = if match?({runs, _} when is_list(runs), result), do: result, else: {[], []}
    Enum.each(runs, &Store.settle(&1, "aborted"))

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

  # What enqueue/2 read before the job was made: its snapshot, the changed files, the exec
  # claim, a cached result (the job is then over at once).
  defp with_source(job, source) do
    {changed, source} = Map.pop(source, "changed")
    {hit, source} = Map.pop(source, "cached")
    job = Map.merge(job, source)
    job = if changed, do: put_in(job, ["select", "changed"], changed), else: job

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
