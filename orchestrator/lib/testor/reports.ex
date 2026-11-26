defmodule Testor.Reports do
  @moduledoc """
  Report files a run hands over (`run.ps1 -Reports`, `TESTOR_REPORTS`, an agent's `reports`):
  machine-readable results testor reads instead of, or besides, the log. They are kept in
  `<home>/reports/<run>/`, signed with the run's other files, and read once when the run ends:

    * `mutation`: the open mutation-testing-report schema (StrykerJS, Stryker.NET, Stryker4s
      and others), read by `Testor.Reports.Mutation`. Without one, the log's summary of a
      Stryker run (its "Final mutation score") stands in, with the score and totals only.

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

  @doc "Removes a run's reports and what was read from them."
  def delete(id) do
    File.rm_rf(dir(id))
    File.rm(detail_file(id))
    File.rm(tests_file(id))
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
  What a report file is: `mutation` (a JSON object with `schemaVersion` and `files`, found in
  its first or last 64 KB: tools write the keys in either order), or `file` for one testor
  does not read.
  """
  def kind(path) do
    {head, tail} =
      case File.open(path, [:read, :binary], &ends/1) do
        {:ok, ends} -> ends
        _ -> {"", ""}
      end

    if String.contains?(head, "\"files\"") and String.contains?(head <> tail, "\"schemaVersion\""),
      do: "mutation",
      else: "file"
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
          if bytes <= max_bytes(), do: from_report(id, Path.join(dir(id), file))

        nil ->
          nil
      end || Mutation.from_log(log_tail || tail(id))

    %{}
    |> put_if("reports", reports != [] && reports)
    |> put_if("mutation", mutation)
  end

  defp from_report(id, path) do
    task =
      Task.Supervisor.async_nolink(Testor.TaskSupervisor, fn -> path |> File.read!() |> Mutation.parse() end)

    case Task.yield(task, Application.get_env(:testor, :report_parse_ms, @parse_ms)) ||
           Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, summary, detail, tests}} ->
        Testor.Files.write_json(detail_file(id), detail)
        if tests != %{}, do: Testor.Files.write_json(tests_file(id), tests)
        summary

      {:ok, {:error, reason}} ->
        Logger.warning("reports: #{id}: #{Path.basename(path)} is not a mutation report (#{reason})")
        nil

      other ->
        Logger.warning("reports: #{id}: #{Path.basename(path)} could not be read in time (#{inspect(other)})")
        nil
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
