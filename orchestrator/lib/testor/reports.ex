defmodule Testor.Reports do
  @moduledoc """
  Report files a run hands over (`run.ps1 -Reports`, `TESTOR_REPORTS`, an agent's `reports`):
  machine-readable results testor reads instead of, or besides, the log. They are kept in
  `<home>/reports/<run>/`, signed with the run's other files, and read once when the run ends:

    * `mutation`: the open mutation-testing-report schema (StrykerJS, Stryker.NET, Stryker4s
      and others), read by `Testor.Reports.Mutation`. Without one, the log's summary of a
      Stryker run (its "Final mutation score") stands in, with the score and totals only.
    * test results, `junit`, `trx`, `ctrf` and `tap` (`Testor.Reports.Tests`): a run with any
      takes its spec table from them (several are merged), not from its log; the record says
      which (`specsFrom`) and keeps the log's own summary when it differs (`logSummary`).
    * coverage, `lcov`, `cobertura` and `istanbul` (`Testor.Reports.Coverage`): the record's
      `coverage` (lines, branches, functions %), the files' rows beside it.

  A report is untrusted data: at most #{20} files of #{50} MB each, parsed in a task with a
  time limit; no path inside it is ever opened.

  The run record gets a small, signed summary (`reports`, `mutation`); the details (files,
  surviving mutants) are kept beside it (`<home>/reports/<run>.mutation.json`) and served with
  the run, and the tests that cover each source file in `<home>/reports/<run>.tests.json`.
  """
  require Logger
  alias Testor.Config
  alias Testor.Reports.Mutation

  @max_bytes 50 * 1024 * 1024
  @max_files 20
  @parse_ms 30_000

  def max_bytes, do: Application.get_env(:testor, :report_max_bytes, @max_bytes)
  def max_files, do: @max_files

  def dir(id), do: Path.join(Config.reports_dir(), id)
  def detail_file(id), do: Path.join(Config.reports_dir(), id <> ".mutation.json")
  def tests_file(id), do: Path.join(Config.reports_dir(), id <> ".tests.json")
  def specs_file(id), do: Path.join(Config.reports_dir(), id <> ".specs.json")
  def coverage_file(id), do: Path.join(Config.reports_dir(), id <> ".coverage.json")

  @test_kinds ["junit", "trx", "ctrf", "tap"]
  @coverage_kinds ["lcov", "cobertura", "istanbul"]

  @doc "Removes a run's reports and what was read from them."
  def delete(id) do
    File.rm_rf(dir(id))
    File.rm(detail_file(id))
    File.rm(tests_file(id))
    File.rm(specs_file(id))
    File.rm(coverage_file(id))
  end

  @doc "A run's report files: `[%{\"file\", \"kind\", \"bytes\"}]`, sorted, at most #{@max_files}."
  def list(id) do
    dir = dir(id)

    dir
    |> Testor.Files.ls()
    |> Enum.sort()
    |> Enum.map(&Path.join(dir, &1))
    |> Enum.filter(&match?({:file, _, _}, Testor.Files.entry(&1)))
    |> Enum.take(@max_files)
    |> Enum.map(fn path ->
      %{"file" => Path.basename(path), "kind" => kind(path), "bytes" => Testor.Files.size(path)}
    end)
  end

  @doc """
  What a report file is, from its first and last 64 KB (tools write JSON keys in any order):
  `mutation`, `junit`, `trx`, `ctrf`, `tap`, `lcov`, `cobertura`, `istanbul`, or `file` for one
  testor does not read.
  """
  def kind(path) do
    {head, tail} =
      case File.open(path, [:read, :binary], &ends/1) do
        {:ok, ends} -> ends
        _ -> {"", ""}
      end

    both = head <> tail
    has = &String.contains?(both, &1)

    cond do
      has.("\"schemaVersion\"") and has.("\"files\"") -> "mutation"
      has.("\"results\"") and has.("\"tests\"") and has.("\"tool\"") -> "ctrf"
      has.("\"total\"") and has.("\"pct\"") -> "istanbul"
      Regex.match?(~r/<testsuites?[\s>]/, head) -> "junit"
      Regex.match?(~r/<TestRun[\s>]/, head) -> "trx"
      Regex.match?(~r/<coverage[\s>]/, head) -> "cobertura"
      Regex.match?(~r/^SF:/m, head) and has.("end_of_record") -> "lcov"
      Regex.match?(~r/\A\s*(TAP version \d+|1\.\.\d+|(not )?ok\b)/, head) -> "tap"
      true -> "file"
    end
  end

  defp ends(io) do
    {:ok, size} = :file.position(io, :eof)
    {:ok, head} = Testor.Files.read_at(io, 0, min(size, 65_536))
    {:ok, tail} = Testor.Files.read_at(io, max(size - 65_536, 0), min(size, 65_536))
    {head, tail}
  end

  @doc """
  What the run's record gets from its reports and log once it ends: `%{"reports" => [...],
  "mutation" => summary}`, each only when there is one. Writes the details beside the reports.
  """
  def summarize(id, log_tail \\ nil) do
    reports = list(id)

    mutation =
      case Enum.find(reports, &(&1["kind"] == "mutation")) do
        %{"file" => file, "bytes" => bytes} ->
          if bytes <= max_bytes(), do: from_report(id, file)

        nil ->
          nil
      end || Mutation.from_log(log_tail || tail(id))

    {specs, coverage} = {test_specs(id, reports), coverage(id, reports)}

    %{}
    |> put_if("reports", reports != [] && reports)
    |> put_if("mutation", mutation)
    |> put_if("specsFrom", specs != [] && "reports")
    |> put_if("coverage", coverage)
  end

  # Every test report's rows, merged by file (a file in two reports adds up), cached.
  defp test_specs(id, reports) do
    rows =
      for %{"kind" => kind, "file" => file, "bytes" => bytes} <- reports,
          kind in @test_kinds,
          bytes <= max_bytes(),
          {:ok, rows} <- [read(id, file, &apply(Testor.Reports.Tests, String.to_existing_atom(kind), [&1]))],
          row <- rows,
          do: row

    specs =
      rows
      |> Enum.group_by(& &1["file"])
      |> Enum.map(fn {_file, [first | _] = same} -> merge(first, same) end)
      |> Enum.sort_by(&{&1["status"] != "failed", &1["file"]})

    if specs != [], do: Testor.Files.write_json(specs_file(id), %{"specs" => specs})
    specs
  end

  defp merge(first, [_]), do: first

  defp merge(first, same) do
    sum = fn key -> same |> Enum.map(& &1[key]) |> Enum.sum() end
    failed = sum.("failed")

    %{
      first
      | "tests" => sum.("tests"),
        "failed" => failed,
        "skipped" => sum.("skipped"),
        "durationMs" => sum.("durationMs"),
        "retries" => sum.("retries"),
        "cases" => same |> Enum.flat_map(& &1["cases"]) |> Enum.take(1000),
        "status" => if(failed > 0, do: "failed", else: first["status"])
    }
  end

  # The first coverage report's totals in the record, its files beside it.
  defp coverage(id, reports) do
    Enum.find_value(reports, fn
      %{"kind" => kind, "file" => file, "bytes" => bytes} when kind in @coverage_kinds ->
        if bytes <= max_bytes() do
          case read(id, file, &apply(Testor.Reports.Coverage, String.to_existing_atom(kind), [&1])) do
            {:ok, totals, files} ->
              Testor.Files.write_json(coverage_file(id), %{"files" => files})
              Map.put(totals, "source", kind)

            _ ->
              nil
          end
        end

      _ ->
        nil
    end)
  end

  # A report read in a task with a time limit; a failure is logged and is nil.
  defp read(id, file, parse) do
    path = Path.join(dir(id), file)
    task = Task.Supervisor.async_nolink(Testor.TaskSupervisor, fn -> path |> File.read!() |> parse.() end)

    case Task.yield(task, Application.get_env(:testor, :report_parse_ms, @parse_ms)) ||
           Task.shutdown(task, :brutal_kill) do
      {:ok, {:error, reason}} ->
        Logger.warning("reports: #{id}: #{file} could not be read (#{reason})")
        nil

      {:ok, result} ->
        result

      other ->
        Logger.warning("reports: #{id}: #{file} could not be read in time (#{inspect(other)})")
        nil
    end
  end

  @doc """
  A finished run's spec table: from its test reports when it had any (read when it ended),
  else from its log.
  """
  def run_specs(id) do
    case Testor.Files.read_json(specs_file(id)) do
      {:ok, %{"specs" => specs}} when is_list(specs) -> specs
      _ -> Testor.Files.log_specs(id)
    end
  end

  @doc "The coverage of each file of a run, or nil."
  def coverage_detail(id) do
    case Testor.Files.read_json(coverage_file(id)) do
      {:ok, %{"files" => files}} -> files
      _ -> nil
    end
  end

  defp from_report(id, file) do
    with {:ok, summary, detail, tests} <- read(id, file, &Mutation.parse/1) do
      Testor.Files.write_json(detail_file(id), detail)
      if tests != %{}, do: Testor.Files.write_json(tests_file(id), tests)
      summary
    end
  end

  # The end of the log, where Stryker prints its summary.
  defp tail(id) do
    case File.read(Config.log_file(id)) do
      {:ok, text} -> binary_part(text, max(byte_size(text) - 262_144, 0), min(byte_size(text), 262_144))
      _ -> ""
    end
  end

  @doc "The mutation details of a run (files, surviving mutants), or nil."
  def mutation_detail(id) do
    case Testor.Files.read_json(detail_file(id)) do
      {:ok, %{} = detail} -> detail
      _ -> nil
    end
  end

  defp put_if(map, _key, value) when value in [nil, false], do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)
end
