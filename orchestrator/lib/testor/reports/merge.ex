defmodule Testor.Reports.Merge do
  @moduledoc """
  A batch's shards merged into one record (`Testor.Batches`):

    * specs: the union of the shards' spec rows (a file two shards ran counts twice);
    * mutation: the shards' files merged by path, the totals summed and the score computed
      again as one run would (a file two shards mutated is listed in `overlaps`);
    * coverage: per file, the best of the shards (testor keeps percentages, not lines), the
      totals averaged over the files, marked `approximate`;
    * the duration: the wall clock from the first start to the last end, and the sum.
  """
  alias Testor.{Reports, SpecParser}

  @doc """
  The merged parts of runs `shards` (records, oldest first): `%{"specs", "summary",
  "durationMs", "cpuMs", "mutation", "mutationDetail", "coverage", "coverageFiles"}`, each
  nil when no shard had it.
  """
  def merge(shards) do
    specs = Enum.flat_map(shards, &Reports.run_specs(&1["id"]))
    {mutation, detail} = mutation(shards)
    {coverage, files} = coverage(shards)

    %{
      "specs" => specs,
      "summary" => SpecParser.summary(specs),
      "durationMs" => wall(shards),
      "cpuMs" => shards |> Enum.map(&(&1["durationMs"] || 0)) |> Enum.sum(),
      "mutation" => mutation,
      "mutationDetail" => detail,
      "coverage" => coverage,
      "coverageFiles" => files
    }
  end

  defp wall(shards) do
    times =
      for run <- shards,
          {:ok, start, _} <- [DateTime.from_iso8601(run["startedAt"] || "")],
          {:ok, stop, _} <- [DateTime.from_iso8601(run["endedAt"] || "")],
          do: {start, stop}

    if times == [] do
      nil
    else
      first = times |> Enum.map(&elem(&1, 0)) |> Enum.min(DateTime)
      last = times |> Enum.map(&elem(&1, 1)) |> Enum.max(DateTime)
      DateTime.diff(last, first, :millisecond)
    end
  end

  # Counts summed, the score as Testor.Reports.Mutation computes it.
  defp mutation(shards) do
    with_mutation = Enum.filter(shards, &is_map(&1["mutation"]))

    if with_mutation == [] do
      {nil, nil}
    else
      counts =
        with_mutation
        |> Enum.map(&(&1["mutation"]["counts"] || %{}))
        |> Enum.reduce(%{}, &Map.merge(&2, &1, fn _, a, b -> a + b end))

      rows = Enum.flat_map(with_mutation, &((Reports.mutation_detail(&1["id"]) || %{})["files"] || []))

      overlaps =
        rows
        |> Enum.frequencies_by(& &1["file"])
        |> Enum.filter(fn {_, n} -> n > 1 end)
        |> Enum.map(&elem(&1, 0))
        |> Enum.sort()

      survivors =
        Enum.flat_map(with_mutation, &((Reports.mutation_detail(&1["id"]) || %{})["survivors"] || []))

      c = Map.merge(%{"killed" => 0, "timeout" => 0, "survived" => 0, "noCoverage" => 0}, counts)
      detected = c["killed"] + c["timeout"]

      summary =
        %{
          "score" => percent(detected, detected + c["survived"] + c["noCoverage"]),
          "coveredScore" => percent(detected, detected + c["survived"]),
          "counts" => counts,
          "total" => counts |> Map.values() |> Enum.sum(),
          "files" => length(rows),
          "source" => "shards"
        }
        |> then(&if(overlaps == [], do: &1, else: Map.put(&1, "overlaps", overlaps)))

      {summary, %{"files" => rows, "survivors" => survivors, "survivorsKept" => length(survivors)}}
    end
  end

  defp percent(_part, 0), do: nil
  defp percent(part, whole), do: Float.round(part * 100 / whole, 2)

  defp coverage(shards) do
    rows =
      shards
      |> Enum.flat_map(fn run ->
        case Testor.Files.read_json(Reports.coverage_file(run["id"])) do
          {:ok, %{"files" => files}} when is_list(files) -> files
          _ -> []
        end
      end)

    if rows == [] do
      {nil, nil}
    else
      best =
        rows
        |> Enum.group_by(& &1["file"])
        |> Enum.map(fn {_, list} -> Enum.max_by(list, &(&1["lines"] || -1)) end)
        |> Enum.sort_by(& &1["file"])

      mean = fn key ->
        values = for row <- best, is_number(row[key]), do: row[key]
        if values == [], do: nil, else: Float.round(Enum.sum(values) / length(values), 2)
      end

      {%{
         "lines" => mean.("lines"),
         "branches" => mean.("branches"),
         "functions" => mean.("functions"),
         "files" => length(best),
         "approximate" => true
       }, best}
    end
  end
end
