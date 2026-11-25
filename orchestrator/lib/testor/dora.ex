defmodule Testor.Dora do
  @moduledoc """
  The four DORA metrics of a project, from the runs of the task that delivers it (a `deploy`
  job, a release pipeline's run) over a window of days:

    * **deployment frequency**: its passed runs, and per week;
    * **change failure rate**: its failed runs out of the passed and failed ones;
    * **time to restore**: from a failure (the first of a streak) to the next passed run, the
      median;
    * **lead time for changes**: from a passed run's commit (`source.committedAt`, which the
      agent and `remote.yml` record) to its end, the median.

  Cancelled and aborted runs count as neither. Medians are in seconds, nil without data.
  """
  alias Testor.Store

  @doc "The metrics of `project`'s runs of `kind` that ended within `days` days before `now`."
  def metrics(project, kind, days, now \\ DateTime.utc_now()) do
    since = DateTime.add(now, -days * 86_400)

    runs =
      Store.all()
      |> Enum.filter(
        &(&1["project"] == project and &1["kind"] == kind and &1["status"] in ["passed", "failed"])
      )
      |> Enum.map(&Map.put(&1, :ended, time(&1["endedAt"])))
      |> Enum.filter(
        &(&1.ended != nil and DateTime.compare(&1.ended, since) != :lt and
            DateTime.compare(&1.ended, now) != :gt)
      )
      |> Enum.sort_by(&DateTime.to_unix(&1.ended, :microsecond))

    passed = Enum.filter(runs, &(&1["status"] == "passed"))
    failed = length(runs) - length(passed)
    restores = restores(runs)

    lead_times =
      for run <- passed,
          at = time(get_in(run, ["source", "committedAt"])),
          at != nil,
          do: DateTime.diff(run.ended, at)

    %{
      "project" => project,
      "kind" => kind,
      "days" => days,
      "since" => DateTime.to_iso8601(since),
      "deployments" => length(passed),
      "deploymentsPerWeek" => Float.round(length(passed) * 7 / days, 2),
      "failures" => failed,
      "changeFailureRate" => if(runs != [], do: Float.round(failed / length(runs), 3)),
      "restores" => length(restores),
      "medianTimeToRestoreSeconds" => median(restores),
      "leadTimes" => length(lead_times),
      "medianLeadTimeSeconds" => median(lead_times)
    }
  end

  # From the first failure of each streak to the pass that ends it.
  defp restores(runs) do
    {restores, _down_since} =
      Enum.reduce(runs, {[], nil}, fn run, {restores, down_since} ->
        case {run["status"], down_since} do
          {"failed", nil} -> {restores, run.ended}
          {"failed", since} -> {restores, since}
          {"passed", nil} -> {restores, nil}
          {"passed", since} -> {[DateTime.diff(run.ended, since) | restores], nil}
        end
      end)

    restores
  end

  defp median([]), do: nil

  defp median(values) do
    sorted = Enum.sort(values)
    count = length(sorted)
    middle = div(count, 2)

    if rem(count, 2) == 1,
      do: Enum.at(sorted, middle),
      else: div(Enum.at(sorted, middle - 1) + Enum.at(sorted, middle), 2)
  end

  defp time(text) do
    case Store.parse_time(text) do
      {:ok, at} -> at
      _ -> nil
    end
  end
end
