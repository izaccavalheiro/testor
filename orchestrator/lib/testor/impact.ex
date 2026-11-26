defmodule Testor.Impact do
  @moduledoc """
  Which tests to run first for a change (`docs/impact.md`): spec files ranked by a score from
  the project's history, each with the reasons for it.

    * **co-failure:** each finished run that failed with `changedFiles` gives the pairs
      (changed file, failing spec file), weighed down by age (a 30-day half-life): 3 points each;
    * **coverage:** the tests that cover a source file, from the latest mutation report that says
      (`coveredBy`, `testFiles`): 2 points;
    * **naming:** `src/foo.ts` and `foo.test.ts`, `foo.spec.ts`, `test_foo.py`, `foo_test.go`:
      2 points; a changed spec file is itself first (5 points);
    * **recency:** a spec that failed in the last 10 runs: 1 point.

  Without history it falls back to naming, then to the shortest specs first. The history is
  read from the run records when asked (the project's last #{500} runs).
  `replay/1` measures the ranking on recorded history: APFD, and where each failing run's
  first failing spec ranked.
  """
  alias Testor.{Reports, Shards, Store}

  @history 500
  @half_life_days 30

  @doc "Changed paths as a request gives them, checked: `{:ok, paths}` or `{:error, message}`."
  def changed(list) when is_list(list) and length(list) <= 2_000 do
    if Enum.all?(list, &Testor.Snapshots.path?/1),
      do: {:ok, Enum.uniq(list)},
      else: {:error, "changed is a list of paths inside the project"}
  end

  def changed(_), do: {:error, "changed is a list of up to 2000 paths"}

  @doc "The spec files of `project` ranked for `changed`: `[%{\"file\", \"score\", \"reasons\"}]`, at most `limit`."
  def rank(project, changed, limit \\ 50, runs \\ nil) do
    runs = runs || history(project)
    changed = changed |> Enum.filter(&is_binary/1) |> Enum.uniq()
    now = System.os_time(:second)
    specs = known_specs(runs)
    scores = %{}

    scores =
      for run <- runs,
          run["status"] == "failed",
          is_list(run["changedFiles"]),
          shared = Enum.filter(run["changedFiles"], &(&1 in changed)),
          shared != [],
          spec <- failed_specs(run),
          reduce: scores do
        acc ->
          weight = 3 * decay(run, now)
          add(acc, spec, weight, "co-failed with #{hd(shared)}")
      end

    scores =
      for {source, tests} <- coverage(runs), source in changed, test <- tests, reduce: scores do
        acc -> add(acc, test, 2, "covers #{source}")
      end

    scores =
      for spec <- Enum.uniq(specs ++ Enum.filter(changed, &Shards.test_file?/1)),
          source <- changed,
          reduce: scores do
        acc ->
          cond do
            spec == source -> add(acc, spec, 5, "changed")
            named?(spec, source) -> add(acc, spec, 2, "named after #{source}")
            true -> acc
          end
      end

    recent = runs |> Enum.take(10) |> Enum.flat_map(&failed_specs/1) |> MapSet.new()

    scores =
      for spec <- specs, MapSet.member?(recent, spec), Map.has_key?(scores, spec), reduce: scores do
        acc -> add(acc, spec, 1, "failed recently")
      end

    durations = durations(runs)

    scores
    |> Enum.map(fn {file, %{score: score, reasons: reasons}} ->
      %{
        "file" => file,
        "score" => Float.round(score * 1.0, 3),
        "reasons" => reasons |> Enum.reverse() |> Enum.uniq() |> Enum.take(5)
      }
    end)
    |> Enum.sort_by(&{-&1["score"], Map.get(durations, &1["file"], 0), &1["file"]})
    |> then(fn ranked ->
      # The rest of the known specs, the shortest first, so a ranking always covers the suite.
      rest =
        for spec <- Enum.sort_by(specs, &{Map.get(durations, &1, 0), &1}),
            not Enum.any?(ranked, &(&1["file"] == spec)),
            do: %{"file" => spec, "score" => 0.0, "reasons" => []}

      ranked ++ rest
    end)
    |> Enum.take(limit)
  end

  defp add(scores, spec, points, reason) do
    Map.update(
      scores,
      spec,
      %{score: points, reasons: [reason]},
      &%{score: &1.score + points, reasons: [reason | &1.reasons]}
    )
  end

  defp decay(run, now) do
    case DateTime.from_iso8601(run["startedAt"] || "") do
      {:ok, at, _} -> :math.pow(0.5, max(now - DateTime.to_unix(at), 0) / 86_400 / @half_life_days)
      _ -> 0.5
    end
  end

  @doc false
  def named?(spec, source) do
    stem = source |> Path.basename() |> Path.rootname()
    name = Path.basename(spec)

    stem != "" and spec != source and
      (Regex.match?(~r/^#{Regex.escape(stem)}(\.|_|-)(test|spec)s?\./, name) or name == "test_#{stem}.py")
  end

  defp history(project) do
    Store.all()
    |> Enum.filter(&(&1["project"] == project and &1["status"] in ["passed", "failed"]))
    |> Enum.sort_by(&(&1["startedAt"] || ""), :desc)
    |> Enum.take(@history)
  end

  defp failed_specs(run), do: for(%{"status" => "failed", "file" => f} <- specs_of(run), do: f)
  defp known_specs(runs), do: runs |> Enum.flat_map(&specs_of/1) |> Enum.map(& &1["file"]) |> Enum.uniq()

  defp specs_of(run), do: Shards.specs_of(run)

  defp durations(runs) do
    runs
    |> Enum.flat_map(&specs_of/1)
    |> Enum.filter(&is_integer(&1["durationMs"]))
    |> Enum.group_by(& &1["file"], & &1["durationMs"])
    |> Map.new(fn {file, list} -> {file, Shards.percentile(list, 50)} end)
  end

  # Source file → the test files covering it, from the latest mutation report that says.
  defp coverage(runs) do
    Enum.find_value(runs, %{}, fn run ->
      case Testor.Files.read_json(Reports.tests_file(run["id"])) do
        {:ok, %{} = map} when map_size(map) > 0 -> map
        _ -> nil
      end
    end)
  end

  @doc """
  The ranking replayed on `project`'s history: for each failed run with `changedFiles`, the
  rank its first failing spec gets from the runs before it. `%{"runs", "apfd", "medianRank",
  "medianRankPercent"}`.
  """
  def replay(project) do
    runs = project |> history() |> Enum.reverse()

    results =
      for {run, i} <- Enum.with_index(runs),
          run["status"] == "failed",
          is_list(run["changedFiles"]),
          failing = failed_specs(run),
          failing != [] do
        before = runs |> Enum.take(i) |> Enum.reverse()
        ranked = rank(project, run["changedFiles"], 10_000, before) |> Enum.map(& &1["file"])
        total = max(length(Enum.uniq(ranked ++ failing)), 1)
        positions = for f <- failing, do: (Enum.find_index(ranked, &(&1 == f)) || total - 1) + 1
        apfd = 1 - Enum.sum(positions) / (total * length(failing)) + 1 / (2 * total)
        %{rank: Enum.min(positions), percent: Enum.min(positions) * 100 / total, apfd: apfd}
      end

    if results == [] do
      %{"runs" => 0, "apfd" => nil, "medianRank" => nil, "medianRankPercent" => nil}
    else
      %{
        "runs" => length(results),
        "apfd" => Float.round(Enum.sum(Enum.map(results, & &1.apfd)) / length(results), 3),
        "medianRank" => Shards.percentile(Enum.map(results, & &1.rank), 50),
        "medianRankPercent" => Float.round(Shards.percentile(Enum.map(results, & &1.percent), 50) * 1.0, 1)
      }
    end
  end
end
