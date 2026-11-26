defmodule Testor.Reports.Coverage do
  @moduledoc """
  Coverage summaries from report files: the percentage of lines, branches and functions
  covered, per file and in total.

    * `lcov/1`: LCOV tracefiles (`lcov.info`: c8, nyc, Jest, Vitest, cargo-llvm-cov, gcov),
      from each record's `LF`/`LH`, `BRF`/`BRH`, `FNF`/`FNH`;
    * `cobertura/1`: Cobertura XML (coverage.py, JaCoCo's converters, coverlet, gocover-cobertura),
      from `line-rate` and `branch-rate`;
    * `istanbul/1`: Istanbul's `coverage-summary.json` (the json-summary reporter).

  Each gives `{:ok, %{"lines", "branches", "functions", "files"}, files}` with the totals in the
  record and the per-file rows (at most #{500}) kept beside it. Per-line data stays in the
  report file.
  """
  alias Testor.Reports.XML

  @max_files 500

  def lcov(text) do
    records =
      text
      |> String.split("end_of_record")
      |> Enum.flat_map(fn record ->
        fields =
          for line <- String.split(record, ~r/\r?\n/),
              [key, value] <- [String.split(String.trim(line), ":", parts: 2)],
              into: %{},
              do: {key, value}

        if fields["SF"], do: [{fields["SF"], counts(fields)}], else: []
      end)

    if records == [], do: {:error, "no SF records"}, else: summary(records)
  end

  defp counts(f) do
    %{lines: pair(f["LH"], f["LF"]), branches: pair(f["BRH"], f["BRF"]), functions: pair(f["FNH"], f["FNF"])}
  end

  defp pair(hit, found) do
    with {h, ""} <- Integer.parse(hit || ""), {n, ""} <- Integer.parse(found || "") do
      {h, n}
    else
      _ -> nil
    end
  end

  def cobertura(xml) do
    with {:ok, root} <- XML.parse(xml),
         "coverage" <- XML.name(root) do
      classes =
        for class <- XML.all(root, "class"), file = XML.attr(class, "filename"), is_binary(file) do
          {file,
           %{
             lines: rate(XML.attr(class, "line-rate")),
             branches: rate(XML.attr(class, "branch-rate")),
             functions: nil
           }}
        end

      total = %{
        lines: rate(XML.attr(root, "line-rate")),
        branches: rate(XML.attr(root, "branch-rate")),
        functions: nil
      }

      rows =
        classes
        |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
        |> Enum.map(fn {file, [first | _]} -> row(file, first) end)

      {:ok, totals(total, length(rows)), cap(rows)}
    else
      {:error, _} = error -> error
      _ -> {:error, "no coverage element"}
    end
  end

  # A rate of 0 to 1 as a percentage {covered, 100}.
  defp rate(value) do
    case Float.parse(value || "") do
      {r, ""} when r >= 0 and r <= 1 -> {r * 100, 100}
      _ -> nil
    end
  end

  def istanbul(json) do
    case JSON.decode(json) do
      {:ok, %{"total" => %{} = total} = all} ->
        files = for {file, %{} = m} <- Map.delete(all, "total"), do: {file, metric_counts(m)}
        {:ok, totals(metric_counts(total), length(files)), cap(Enum.map(files, fn {f, c} -> row(f, c) end))}

      {:ok, _} ->
        {:error, "no total"}

      {:error, _} ->
        {:error, "not JSON"}
    end
  end

  defp metric_counts(m),
    do: %{lines: metric(m["lines"]), branches: metric(m["branches"]), functions: metric(m["functions"])}

  defp metric(%{"covered" => c, "total" => t}) when is_integer(c) and is_integer(t), do: {c, t}
  defp metric(_), do: nil

  defp summary(records) do
    sum = fn key ->
      pairs = records |> Enum.map(&elem(&1, 1)[key]) |> Enum.reject(&is_nil/1)
      if pairs == [], do: nil, else: Enum.reduce(pairs, {0, 0}, fn {h, n}, {a, b} -> {a + h, b + n} end)
    end

    total = %{lines: sum.(:lines), branches: sum.(:branches), functions: sum.(:functions)}
    {:ok, totals(total, length(records)), cap(Enum.map(records, fn {file, c} -> row(file, c) end))}
  end

  defp totals(c, files) do
    %{
      "lines" => pct(c.lines),
      "branches" => pct(c.branches),
      "functions" => pct(c.functions),
      "files" => files
    }
  end

  defp row(file, c) do
    %{
      "file" => String.slice(file, 0, 300),
      "lines" => pct(c.lines),
      "branches" => pct(c.branches),
      "functions" => pct(c.functions)
    }
  end

  # The least covered files first.
  defp cap(rows), do: rows |> Enum.sort_by(&{&1["lines"] || 101, &1["file"]}) |> Enum.take(@max_files)

  defp pct(nil), do: nil
  defp pct({_, 0}), do: nil
  defp pct({covered, total}), do: Float.round(covered * 100 / total, 2)
end
