defmodule Testor.Schedules do
  @moduledoc """
  Scheduled jobs: `schedules` in config.json queue a job when their cron expression (UTC, see
  `Testor.Cron`) matches the minute, as a person queuing it through the API would:

      "schedules": [
        {"name": "nightly-web", "cron": "0 2 * * *", "project": "web", "kind": "test",
         "labels": ["linux"], "ref": "main"}
      ]

  Jobs must be on (`execution.enabled`). A schedule whose last job is still queued, leased or
  running queues none, so a slow suite never piles up. Its jobs are requested by
  `schedule:<name>`. A schedule that is not valid is left out, and `testor.log` says why once.
  config.json is read again every minute: no restart.
  """
  use GenServer
  require Logger
  alias Testor.{Config, Cron, Jobs}

  @waiting ["queued", "leased", "running"]
  @name ~r/^[A-Za-z0-9_.-]{1,64}$/

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "The schedules of config.json: each valid one with its next time, the others with why not."
  def list(now \\ DateTime.utc_now()) do
    for result <- checked() do
      case result do
        {:ok, schedule} ->
          next = Cron.next(schedule.spec, now)

          schedule
          |> Map.delete(:spec)
          |> Map.put("next", next && DateTime.to_iso8601(next))

        {:error, raw, why} ->
          %{"name" => raw["name"], "error" => why}
      end
    end
  end

  @doc "Queues the jobs of the schedules matching `at` (the minute); returns those queued."
  def fire(at) do
    GenServer.call(__MODULE__, {:fire, %{at | second: 0, microsecond: {0, 0}}})
  end

  @impl true
  def init(nil) do
    tick()
    {:ok, %{last: nil, logged: MapSet.new()}}
  end

  @impl true
  def handle_info(:tick, state) do
    tick()
    now = %{DateTime.utc_now() | second: 0, microsecond: {0, 0}}

    if state.last == now,
      do: {:noreply, state},
      else: {:noreply, elem(run(now, state), 1)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def handle_call({:fire, at}, _from, state) do
    {queued, state} = run(at, state)
    {:reply, queued, state}
  end

  # Just after the next minute begins (not in tests, which fire their own minutes).
  defp tick do
    if Application.get_env(:testor, :schedule_ticks, true),
      do: Process.send_after(self(), :tick, 60_000 - rem(System.os_time(:millisecond), 60_000) + 50)
  end

  defp run(at, state) do
    results = checked()

    errors = for {:error, raw, why} <- results, into: MapSet.new(), do: {raw["name"], why}

    for {name, why} <- MapSet.difference(errors, state.logged),
        do: Logger.warning("schedules: #{inspect(name)} is left out: #{why}")

    queued =
      if Jobs.settings()["enabled"] == true do
        # One job for a schedule's minute across testors sharing a queue (Testor.Cluster).
        for {:ok, schedule} <- results,
            Cron.matches?(schedule.spec, at),
            Testor.Cluster.claim("schedule", "#{schedule["name"]}@#{DateTime.to_iso8601(at)}"),
            job = enqueue(schedule),
            do: job
      else
        []
      end

    {queued, %{state | last: at, logged: errors}}
  end

  defp enqueue(%{"name" => name} = schedule) do
    who = "schedule:" <> name

    if Enum.any?(Jobs.list(), &(&1["requestedBy"] == who and &1["status"] in @waiting)) do
      Logger.info("schedules: #{name}'s last job has not ended: none queued")
      nil
    else
      case Jobs.enqueue(Map.take(schedule, ["project", "kind", "labels", "ref"]), who) do
        {:ok, job} ->
          job

        {:error, why} ->
          Logger.warning("schedules: #{name} could not queue its job: #{inspect(why)}")
          nil
      end
    end
  end

  defp checked do
    case Config.user()["schedules"] do
      list when is_list(list) ->
        {results, _names} =
          Enum.map_reduce(list, MapSet.new(), fn raw, names ->
            result = check(raw, names)
            {result, if(match?({:ok, _}, result), do: MapSet.put(names, raw["name"]), else: names)}
          end)

        results

      nil ->
        []

      other ->
        [{:error, %{"name" => nil}, "schedules is a list, not #{inspect(other)}"}]
    end
  end

  defp check(%{} = raw, names) do
    with :ok <- valid(name?(raw["name"]), "a name is 1 to 64 letters, digits, or _ . -"),
         :ok <- valid(not MapSet.member?(names, raw["name"]), "another schedule has this name"),
         {:ok, spec} <- Cron.parse(raw["cron"]),
         :ok <- valid(name?(raw["project"]) and name?(raw["kind"]), "project and kind are names"),
         :ok <- valid(labels?(raw["labels"]), "labels are a list of names"),
         :ok <- valid(raw["ref"] == nil or is_binary(raw["ref"]), "ref is a git ref") do
      schedule =
        raw
        |> Map.take(["name", "cron", "project", "kind", "labels", "ref"])
        |> Map.reject(fn {_k, v} -> v == nil end)

      {:ok, Map.put(schedule, :spec, spec)}
    else
      {:error, why} -> {:error, raw, why}
    end
  end

  defp check(raw, _names), do: {:error, %{"name" => nil}, "a schedule is an object, not #{inspect(raw)}"}

  defp valid(true, _why), do: :ok
  defp valid(_false, why), do: {:error, why}

  defp name?(value), do: is_binary(value) and Regex.match?(@name, value)
  defp labels?(nil), do: true
  defp labels?(labels), do: is_list(labels) and Enum.all?(labels, &name?/1)
end
