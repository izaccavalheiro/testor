defmodule Testor.Shards do
  @moduledoc """
  Batches (`docs/sharding.md`): a job with `"shards": N` (2 to 64) is a parent and N child
  jobs, each with `shard: {index, total}` and the parent's ref or snapshot, labels and timeout,
  leased at once on different agents or slots (each shard has a workspace of its own). The
  command gets `TESTOR_SHARD_INDEX` and `TESTOR_SHARD_TOTAL`; with a weighted plan, its files
  too, as `select.files` (appended to an `argv`, or `TESTOR_SELECT_FILES`, also named
  `TESTOR_SHARD_FILES`).

  A plan (`plan/2`) is LPT bin-packing: the heaviest file first, onto the lightest shard. A test
  file weighs its p75 duration over the project's last runs of the task; a file to mutate, its
  mutants (the last mutation report's); an unknown file, the median. A snapshot batch is planned
  over the snapshot's test files (or, for a mutation task, the last report's files); the plan is
  kept with the batch, so a retried shard runs the same files.
  """
  alias Testor.{Reports, Store}

  @history 20
  @test_file ~r/(\.|_|-)(test|spec)s?\.[^.\/]+$|(^|\/)test_[^\/]+\.py$/

  def test_file?(path), do: Regex.match?(@test_file, path)

  @doc "The files in `n` shards, LPT: a list of `n` sorted lists (some may be empty)."
  def plan(weighted, n) when is_integer(n) and n >= 1 do
    bins = for i <- 0..(n - 1), do: {0, i, []}

    weighted
    |> Enum.sort_by(fn {file, weight} -> {-weight, file} end)
    |> Enum.reduce(bins, fn {file, weight}, bins ->
      [{load, i, files} | rest] = Enum.sort(bins)
      [{load + weight, i, [file | files]} | rest]
    end)
    |> Enum.sort_by(&elem(&1, 1))
    |> Enum.map(fn {_, _, files} -> Enum.sort(files) end)
  end

  @doc """
  The files of a batch of `project`'s `kind` over `manifest` (a snapshot's), each with its
  weight: `[{file, weight}]`, or `[]` when there is nothing to plan over.
  """
  def weighted(project, kind, manifest) do
    runs =
      Store.all()
      |> Enum.filter(
        &(&1["project"] == project and &1["kind"] == kind and &1["status"] in ["passed", "failed"])
      )
      |> Enum.sort_by(&(&1["startedAt"] || ""), :desc)
      |> Enum.take(@history)

    case Enum.find(runs, & &1["mutation"]) do
      %{"id" => id} -> mutation_weights(id)
      nil -> test_weights(runs, manifest)
    end
  end

  defp mutation_weights(id) do
    case Reports.mutation_detail(id) do
      %{"files" => [_ | _] = files} ->
        for f <- files, is_binary(f["file"]), do: {f["file"], max(mutants(f), 1)}

      _ ->
        []
    end
  end

  defp mutants(row),
    do: Enum.sum(for k <- ~w(killed survived timeout noCoverage), is_integer(row[k]), do: row[k])

  defp test_weights(runs, manifest) do
    files = for %{"path" => path} <- manifest["files"] || [], test_file?(path), do: path

    durations =
      runs
      |> Enum.flat_map(&specs_of/1)
      |> Enum.filter(&is_integer(&1["durationMs"]))
      |> Enum.group_by(& &1["file"], & &1["durationMs"])
      |> Map.new(fn {file, list} -> {file, percentile(list, 75)} end)

    median = durations |> Map.values() |> then(&if(&1 == [], do: 1, else: percentile(&1, 50)))
    for file <- files, do: {file, max(Map.get(durations, file, median), 1)}
  end

  @doc "A run's spec rows: its record's, else its report's or log's."
  def specs_of(%{"specs" => [_ | _] = specs}), do: specs
  def specs_of(run), do: Reports.run_specs(run["id"])

  @doc false
  def percentile(list, p) do
    sorted = Enum.sort(list)
    Enum.at(sorted, min(length(sorted) - 1, round(p / 100 * (length(sorted) - 1))))
  end
end
