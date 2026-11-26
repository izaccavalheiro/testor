defmodule Testor.Jobs do
  @moduledoc """
  Jobs: runs asked for through the API (`POST /api/v1/jobs`) and taken by agents
  (`runner/agent.ps1`), which run them on their machine through run.ps1. Off until
  `execution.enabled` in config.json, and only with authentication on.

  A job names a project and a task (`kind`), never a command: the agent's own configuration
  maps them to the command it runs, so whoever owns a runner decides what can run on it. A job
  may also name `labels` an agent must have (`windows`, `gpu`, ...) and a git `ref` the agent
  checks out first.

      queued ──lease──▶ leased ──heartbeat──▶ running ──finish──▶ passed | failed | cancelled
         ▲                 │ lease expires (agent gone)
         └─────────────────┘ again, up to execution.maxAttempts; then expired

  An agent holds a job by its lease (`execution.leaseSeconds`, 30 by default) and renews it
  with heartbeats; a job whose lease runs out goes back to the queue. One job per project is
  leased at a time, so two runs never share a project's snapshot folder. Jobs are kept in
  `<home>/jobs/<id>.json` (`Testor.Jobs.FileStore`) and survive a restart; with
  `TESTOR_DATABASE_URL`, in PostgreSQL (`Testor.Jobs.Postgres`), shared by several testors.
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

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def statuses, do: @statuses
  def dir, do: Testor.Jobs.FileStore.dir()

  @doc "The execution settings: `enabled`, `leaseSeconds`, `maxAttempts`."
  def settings, do: Config.retention()["execution"]

  # --- reads --------------------------------------------------------------------------------

  def get(id), do: GenServer.call(__MODULE__, {:get, id})

  @doc "Jobs, newest first, optionally with one status."
  def list(status \\ nil), do: GenServer.call(__MODULE__, {:list, status})

  # --- writes -------------------------------------------------------------------------------

  @doc """
  Queues a job from `params` (`project`, `kind`, optional `labels` and `ref`) asked for by
  `who`: `{:ok, job}` or `{:error, reason}` (`:disabled`, or a message for a bad request).
  """
  def enqueue(params, who), do: GenServer.call(__MODULE__, {:enqueue, params, who})

  @doc """
  The oldest queued job `agent` (with `labels`) can take, leased to it: `{:ok, job}` or `:none`.
  `allow` says which projects the agent may take (an agent user restricted to projects).
  """
  def lease(agent, labels, allow \\ fn _project -> true end),
    do: GenServer.call(__MODULE__, {:lease, agent, labels, allow})

  @doc "Renews `agent`'s lease on job `id`: `{:ok, %{\"cancel\" => bool}}` or `{:error, reason}`."
  def heartbeat(id, agent), do: GenServer.call(__MODULE__, {:heartbeat, id, agent})

  @doc "Ends job `id` for `agent` with `result` (`exitCode`, optional `error`)."
  def finish(id, agent, result), do: GenServer.call(__MODULE__, {:finish, id, agent, result})

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

  @doc "Job `id` as stored, without the run reads link to it (tests)."
  def stored(id), do: GenServer.call(__MODULE__, {:stored, id})

  # --- server -------------------------------------------------------------------------------

  # The state is the backend and its own: files (one testor) or PostgreSQL (several).
  @impl true
  def init(nil) do
    backend = if Testor.Jobs.Postgres.enabled?(), do: Testor.Jobs.Postgres, else: Testor.Jobs.FileStore
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

  def handle_call({:enqueue, params, who}, _from, state) do
    with true <- settings()["enabled"] == true || {:error, :disabled},
         {:ok, job} <- new_job(params, who) do
      Logger.info("jobs: #{job["id"]} queued (#{job["project"]} #{job["kind"]}) by #{who}")
      transact(state, :none, fn _ -> {{:ok, job}, [job]} end)
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:lease, agent, labels, allow}, _from, state) do
    transact(state, :open, fn jobs ->
      busy = for {_, %{"status" => s, "project" => p}} <- jobs, s in @active, into: MapSet.new(), do: p

      candidate =
        jobs
        |> Map.values()
        |> Enum.filter(
          &(&1["status"] == "queued" and not MapSet.member?(busy, &1["project"]) and allow.(&1["project"]))
        )
        |> Enum.filter(&Enum.all?(&1["labels"], fn label -> label in labels end))
        |> Enum.min_by(&order/1, fn -> nil end)

      case candidate do
        nil ->
          {:none, []}

        job ->
          job =
            Map.merge(job, %{
              "status" => "leased",
              "agent" => agent,
              "attempts" => job["attempts"] + 1,
              "leasedAt" => now_iso(),
              "leaseUntil" => lease_until()
            })

          Logger.info("jobs: #{job["id"]} leased to #{agent} (attempt #{job["attempts"]})")
          {{:ok, job}, [job]}
      end
    end)
  end

  def handle_call({:heartbeat, id, agent}, _from, state) do
    transact(state, {:id, id}, fn jobs ->
      case held(jobs, id, agent) do
        {:ok, job} ->
          job = Map.merge(job, %{"status" => "running", "leaseUntil" => lease_until()})
          job = Map.put_new(job, "startedAt", now_iso()) |> link_run()
          {{:ok, %{"cancel" => job["cancelRequested"] == true}}, [job]}

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

  def handle_call(:reset, _from, {backend, state}), do: {:reply, :ok, {backend, backend.clear(state)}}

  def handle_call({:sweep, now}, _from, state) do
    {:reply, _, state} = sweep(state, now)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    Process.send_after(self(), :sweep, @sweep_ms)
    {:reply, _, state} = sweep(state, System.os_time(:second))
    {:noreply, state}
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
            |> Map.drop(["leaseUntil", "agent", "runId"])
            |> then(&if(status == "expired", do: Map.put(&1, "endedAt", now_iso()), else: &1))
          end

        runs = for job <- changed, run = get_in(jobs, [job["id"], "runId"]), is_binary(run), do: run
        {runs, changed}
      end)

    {:reply, runs, _state} = reply
    if is_list(runs), do: Enum.each(runs, &Store.settle(&1, "aborted"))
    reply
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

  defp new_job(params, who) do
    labels = params["labels"] || []
    ref = params["ref"]

    cond do
      not name?(params["project"]) ->
        {:error, "project is a name: letters, digits, _ . -"}

      not name?(params["kind"]) ->
        {:error, "kind is a name: letters, digits, _ . -"}

      not (is_list(labels) and Enum.all?(labels, &name?/1)) ->
        {:error, "labels is a list of names"}

      ref != nil and not (is_binary(ref) and Regex.match?(@ref, ref)) ->
        {:error, "ref is a git branch, tag or commit"}

      params["traceparent"] != nil and Testor.Tracing.parse(params["traceparent"]) == :error ->
        {:error, "traceparent is a W3C trace context (00-<trace id>-<span id>-<flags>)"}

      params["clean"] not in [nil, true, false] ->
        {:error, "clean is true or false"}

      seconds(params["timeout"]) == :error ->
        {:error, "timeout is seconds (1 to 86400) or 90s, 45m, 2h"}

      true ->
        job =
          build(params["project"], params["kind"], Enum.uniq(labels), ref, who)
          # The agent drops the project's preserved caches first (agent.json's "preserve").
          |> then(&if(params["clean"] == true, do: Map.put(&1, "clean", true), else: &1))
          |> put_timeout(params["timeout"] || settings()["defaultTimeout"])

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
