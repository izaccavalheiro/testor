defmodule Testor.Reports.Mutation do
  @moduledoc """
  Mutation testing results.

    * `parse/1`: a report in the open mutation-testing-report schema (versions 1 and 2:
      StrykerJS, Stryker.NET, Stryker4s...). Each mutant's status is counted per file and in
      total; the score is (killed + timeout) / (killed + timeout + survived + no coverage),
      the covered score leaves out the mutants no test reached. Surviving mutants (survived
      and no coverage) are kept with their place, mutator, original text and replacement, at
      most #{2000}; files at most #{500}.
    * `from_log/1`: a Stryker run's own summary in its log ("Final mutation score of 87.50",
      "The final mutation score is 87.50 %", the clear-text table's "All files" row) when no
      report was handed over: the score and totals, no mutants.
    * `progress/1`: a progress line (StrykerJS's "Mutation testing 42% ... 12/30 tested (3
      survived, 1 timed out)", Stryker.NET's "Testing mutant 12 / 30 | K 10 | S 2 | T 0"),
      for the live view of a running run.

  Everything in a report is data: names and snippets are capped and shown as text.
  """

  @statuses %{
    "Killed" => "killed",
    "Survived" => "survived",
    "Timeout" => "timeout",
    "NoCoverage" => "noCoverage",
    "CompileError" => "compileError",
    "RuntimeError" => "runtimeError",
    "Ignored" => "ignored",
    "Pending" => "pending"
  }
  @max_survivors 2000
  @max_files 500
  @max_text 200

  defp zero, do: Map.new(Map.values(@statuses), &{&1, 0})

  @doc """
  Reads a report's JSON: `{:ok, summary, detail, tests_by_source}` or `{:error, reason}`.
  `summary` goes in the run's record; `detail` holds the files and surviving mutants;
  `tests_by_source` maps each source file to the test files that cover it (schema 2).
  """
  def parse(text) do
    case JSON.decode(text) do
      {:ok, %{"schemaVersion" => version, "files" => %{} = files} = report} when is_binary(version) ->
        {summary, detail, tests} = summarize(files, report)
        {:ok, summary, detail, tests}

      {:ok, _} ->
        {:error, "no schemaVersion and files"}

      {:error, _} ->
        {:error, "not JSON"}
    end
  end

  defp summarize(files, report) do
    per_file =
      for {name, %{} = file} <- files, is_binary(name) do
        mutants = Enum.filter(List.wrap(file["mutants"]), &is_map/1)
        counts = Enum.reduce(mutants, zero(), &count/2)
        {name, file, mutants, counts}
      end

    totals =
      Enum.reduce(per_file, zero(), fn {_, _, _, c}, acc -> Map.merge(acc, c, fn _, a, b -> a + b end) end)

    survivors =
      per_file
      |> Stream.flat_map(fn {name, file, mutants, _} ->
        for m <- mutants, m["status"] in ["Survived", "NoCoverage"], do: survivor(name, file, m)
      end)
      |> Enum.take(@max_survivors)

    file_rows =
      per_file
      |> Enum.map(fn {name, _, _, counts} ->
        Map.merge(%{"file" => text(name)}, scores(counts)) |> Map.merge(counts)
      end)
      |> Enum.sort_by(&{-(&1["survived"] + &1["noCoverage"]), &1["file"]})
      |> Enum.take(@max_files)

    summary =
      scores(totals)
      |> Map.merge(%{
        "counts" => totals,
        "total" => totals |> Map.values() |> Enum.sum(),
        "files" => length(per_file),
        "source" => "report"
      })

    detail = %{"files" => file_rows, "survivors" => survivors, "survivorsKept" => length(survivors)}
    {summary, detail, tests_by_source(per_file, report["testFiles"])}
  end

  defp count(mutant, acc) do
    case @statuses[mutant["status"]] do
      nil -> acc
      key -> Map.update!(acc, key, &(&1 + 1))
    end
  end

  defp scores(c) do
    detected = c["killed"] + c["timeout"]

    %{
      "score" => percent(detected, detected + c["survived"] + c["noCoverage"]),
      "coveredScore" => percent(detected, detected + c["survived"])
    }
  end

  defp percent(_part, 0), do: nil
  defp percent(part, whole), do: Float.round(part * 100 / whole, 2)

  defp survivor(name, file, m) do
    start = get_in(m, ["location", "start"]) || %{}
    finish = get_in(m, ["location", "end"]) || %{}

    %{
      "file" => text(name),
      "line" => integer(start["line"]),
      "endLine" => integer(finish["line"]),
      "status" => if(m["status"] == "Survived", do: "survived", else: "noCoverage"),
      "mutator" => text(m["mutatorName"]),
      "original" => original(file["source"], start, finish),
      "replacement" => text(m["replacement"])
    }
  end

  # The mutated text, from the file's source and the mutant's place (lines and columns from 1).
  defp original(source, %{"line" => l1, "column" => c1}, %{"line" => l2, "column" => c2})
       when is_binary(source) and is_integer(l1) and is_integer(c1) and is_integer(l2) and is_integer(c2) and
              l1 >= 1 and c1 >= 1 do
    line = source |> String.split("\n") |> Enum.at(l1 - 1, "")
    stop = if l2 == l1, do: max(c2 - c1, 0), else: String.length(line)
    snippet = String.slice(line, c1 - 1, stop)
    text(if l2 > l1, do: snippet <> " …", else: snippet)
  end

  defp original(_source, _start, _finish), do: nil

  # Each source file's tests: the test files whose tests cover one of its mutants.
  defp tests_by_source(per_file, %{} = test_files) do
    test_file_of =
      for {test_file, %{"tests" => tests}} <- test_files,
          is_list(tests),
          %{"id" => id} <- tests,
          into: %{},
          do: {to_string(id), test_file}

    for {name, _, mutants, _} <- per_file,
        tests =
          mutants |> Enum.flat_map(&List.wrap(&1["coveredBy"])) |> Enum.map(&test_file_of[to_string(&1)]),
        tests = tests |> Enum.reject(&is_nil/1) |> Enum.uniq() |> Enum.sort(),
        tests != [],
        into: %{},
        do: {name, tests}
  end

  defp tests_by_source(_per_file, _test_files), do: %{}

  defp text(value) when is_binary(value), do: String.slice(value, 0, @max_text)
  defp text(_value), do: nil

  defp integer(n) when is_integer(n), do: n
  defp integer(_n), do: nil

  # --- the log -------------------------------------------------------------------------------

  @js_final ~r/Final mutation score of (\d+(?:\.\d+)?)/
  @net_final ~r/[Tt]he final mutation score is (\d+(?:\.\d+)?)\s*%/
  @all_files ~r/^\s*All files\s*\|([^\n]*)$/m

  @doc "The summary a Stryker run prints in its log, or nil."
  def from_log(text) when is_binary(text) do
    score =
      case Regex.scan(@js_final, text) ++ Regex.scan(@net_final, text) do
        [] -> nil
        matches -> matches |> List.last() |> Enum.at(1) |> Float.parse() |> elem(0) |> Float.round(2)
      end

    row =
      case Regex.scan(@all_files, text) do
        [] -> nil
        rows -> rows |> List.last() |> Enum.at(1) |> table_row()
      end

    cond do
      row -> Map.merge(row, %{"source" => "log"}) |> Map.update!("score", &(score || &1))
      score -> %{"score" => score, "source" => "log"}
      true -> nil
    end
  end

  # "  87.50 |  90.00 |  70 |  0 |  10 |  2 |  0 |" (score, covered, killed, timeout, survived,
  # no coverage, errors), or without the covered column.
  defp table_row(cells) do
    numbers =
      cells
      |> String.split("|")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&Float.parse/1)

    if Enum.all?(numbers, &match?({_, ""}, &1)) and length(numbers) in [6, 7] do
      [score | rest] = Enum.map(numbers, &elem(&1, 0))
      {covered, [k, t, s, nc, errors]} = if length(rest) == 6, do: {hd(rest), tl(rest)}, else: {nil, rest}

      counts = %{
        "killed" => round(k),
        "timeout" => round(t),
        "survived" => round(s),
        "noCoverage" => round(nc),
        "errors" => round(errors)
      }

      %{
        "score" => Float.round(score, 2),
        "coveredScore" => covered && Float.round(covered, 2),
        "counts" => counts
      }
    end
  end

  # --- progress ------------------------------------------------------------------------------

  @js_progress ~r/Mutation testing\s.*?(\d+)%.*?(\d+)\/(\d+) tested \((\d+) survived, (\d+) timed out\)/
  @net_progress ~r/Testing mutant (\d+)\s*\/\s*(\d+).*?K\s*(\d+).*?S\s*(\d+).*?T\s*(\d+)/

  @doc "The progress a line reports: `%{\"tested\", \"total\", \"percent\", \"survived\", \"timedOut\"}` or nil."
  def progress(line) do
    cond do
      m = Regex.run(@js_progress, line, capture: :all_but_first) ->
        [percent, tested, total, survived, timed_out] = Enum.map(m, &String.to_integer/1)

        %{
          "percent" => percent,
          "tested" => tested,
          "total" => total,
          "survived" => survived,
          "timedOut" => timed_out
        }

      m = Regex.run(@net_progress, line, capture: :all_but_first) ->
        [tested, total, _killed, survived, timed_out] = Enum.map(m, &String.to_integer/1)
        percent = if total > 0, do: div(tested * 100, total), else: 0

        %{
          "percent" => percent,
          "tested" => tested,
          "total" => total,
          "survived" => survived,
          "timedOut" => timed_out
        }

      true ->
        nil
    end
  end
end
