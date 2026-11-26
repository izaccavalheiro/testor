defmodule Testor.Reports.Tests do
  @moduledoc """
  Test results from report files, as the spec rows the console parser makes
  (`Testor.SpecParser`): one row per spec file with `tests`, `failed`, `skipped`,
  `durationMs`, `status`, and its `cases` (name, status, duration, a failure's message).

    * `junit/1`: JUnit XML, as Jest (jest-junit), Mocha, Maven Surefire and Gradle, pytest
      `--junitxml`, gotestsum, cargo-nextest, PHPUnit and dotnet's JUnit logger write it. A
      case's file is its `file` attribute, else its suite's, else its `classname`, else its
      suite's name.
    * `trx/1`: Visual Studio's test results (`dotnet test --logger trx`), by test class.
    * `ctrf/1`: the Common Test Report Format, by `filePath` (else suite); its `retries` are
      kept, and its own `flaky` flag shown, though testor's detection decides.
    * `tap/1`: TAP 13 and 14 (node:test, tap, bats): each top-level test point is a spec, its
      subtests (indented) its cases.

  Every string is capped; nothing in a report is opened or run.
  """
  alias Testor.Reports.XML

  @max_text 500

  # --- JUnit ---------------------------------------------------------------------------------

  def junit(xml) do
    with {:ok, root} <- XML.parse(xml) do
      cases =
        for suite <- XML.all(root, "testsuite"),
            {"testcase", _, _, _} = tc <- elem(suite, 2) do
          file =
            XML.attr(tc, "file") || XML.attr(suite, "file") || XML.attr(tc, "classname") ||
              XML.attr(suite, "name")

          problem = XML.child(tc, "failure") || XML.child(tc, "error")

          status =
            cond do
              problem -> "failed"
              XML.child(tc, "skipped") -> "skipped"
              true -> "passed"
            end

          {file || "(unnamed)",
           case_of(XML.attr(tc, "name"), status, seconds(XML.attr(tc, "time")), problem && message(problem))}
        end

      {:ok, rows(cases, "junit")}
    end
  end

  defp message(element), do: text(XML.attr(element, "message") || XML.text(element))

  # --- TRX -----------------------------------------------------------------------------------

  def trx(xml) do
    with {:ok, root} <- XML.parse(xml) do
      classes =
        for unit <- XML.all(root, "UnitTest"), into: %{} do
          method = XML.child(unit, "TestMethod")
          {XML.attr(unit, "id"), (method && XML.attr(method, "className")) || XML.attr(unit, "storage")}
        end

      cases =
        for result <- XML.all(root, "UnitTestResult") do
          status =
            case XML.attr(result, "outcome") do
              "Passed" -> "passed"
              outcome when outcome in ["Failed", "Error", "Timeout", "Aborted"] -> "failed"
              _ -> "skipped"
            end

          error =
            with output when output != nil <- XML.child(result, "Output"),
                 info when info != nil <- XML.child(output, "ErrorInfo"),
                 do: XML.child(info, "Message")

          file = classes[XML.attr(result, "testId")] || "(unnamed)"

          {file,
           case_of(
             XML.attr(result, "testName"),
             status,
             timespan(XML.attr(result, "duration")),
             error && text(XML.text(error))
           )}
        end

      {:ok, rows(cases, "trx")}
    end
  end

  # "00:00:01.2340000"
  defp timespan(value) when is_binary(value) do
    case Regex.run(~r/^(\d+):(\d+):(\d+(?:\.\d+)?)$/, value) do
      [_, h, m, s] ->
        round((String.to_integer(h) * 3600 + String.to_integer(m) * 60) * 1000 + float(s) * 1000)

      _ ->
        0
    end
  end

  defp timespan(_value), do: 0

  # --- CTRF ----------------------------------------------------------------------------------

  def ctrf(json) do
    case JSON.decode(json) do
      {:ok, %{"results" => %{"tests" => tests}}} when is_list(tests) ->
        cases =
          for %{} = t <- tests do
            status =
              case t["status"] do
                "passed" -> "passed"
                "failed" -> "failed"
                _ -> "skipped"
              end

            file = string(t["filePath"]) || string(t["suite"]) || "(unnamed)"
            duration = if is_number(t["duration"]), do: round(t["duration"]), else: 0

            row =
              case_of(t["name"], status, duration, text(t["message"]))
              |> put_number("retries", t["retries"])
              |> then(&if(t["flaky"] == true, do: Map.put(&1, "flaky", true), else: &1))

            {file, row}
          end

        {:ok, rows(cases, "ctrf")}

      {:ok, _} ->
        {:error, "no results.tests"}

      {:error, _} ->
        {:error, "not JSON"}
    end
  end

  defp put_number(map, key, n) when is_integer(n) and n > 0, do: Map.put(map, key, n)
  defp put_number(map, _key, _n), do: map

  # --- TAP -----------------------------------------------------------------------------------

  @point ~r/^(\s*)(not ok|ok)\b\s*(\d+)?\s*(?:-\s*)?([^#]*?)\s*(?:#\s*(SKIP|TODO)\b.*)?$/i

  def tap(text) do
    lines = String.split(text, ~r/\r?\n/)

    {specs, _} =
      Enum.reduce(lines, {[], []}, fn line, {specs, pending} ->
        cond do
          m = Regex.run(@point, line) ->
            [_, indent, ok, _n, name, directive] = pad(m, 6)
            status = point_status(ok, directive)

            if indent == "" do
              cases = Enum.reverse(pending)
              # A test point without subtests is its own case.
              cases = if cases == [], do: [case_of(name, status, 0, nil)], else: cases
              {[{blank(name), cases, status} | specs], []}
            else
              # Only the direct subtests of a top-level point (one indent deep) are its cases.
              if String.length(indent) <= 4,
                do: {specs, [case_of(name, status, 0, nil) | pending]},
                else: {specs, pending}
            end

          d = Regex.run(~r/^\s{2,}duration_ms:\s*(\d+(?:\.\d+)?)/, line) ->
            {add_duration(specs, pending, float(Enum.at(d, 1))), pending}

          true ->
            {specs, pending}
        end
      end)

    cases =
      for {file, cases, status} <- Enum.reverse(specs), c <- cases do
        # A failed point whose subtests all passed failed on its own (a hook, a crash).
        c =
          if status == "failed" and Enum.all?(cases, &(&1["status"] == "passed")),
            do: %{c | "status" => "failed"},
            else: c

        {file, c}
      end

    {:ok, rows(cases, "tap")}
  end

  defp pad(list, n), do: list ++ List.duplicate("", n - length(list))

  defp point_status(_ok, directive) when directive != "", do: "skipped"
  defp point_status(ok, _directive), do: if(String.downcase(ok) == "ok", do: "passed", else: "failed")

  # node:test's YAML block after a top-level point: its duration, given to that point.
  defp add_duration([{file, cases, status} | rest], [], ms) do
    [
      {file,
       Enum.map(cases, &Map.update!(&1, "durationMs", fn d -> d + round(ms / max(length(cases), 1)) end)),
       status}
      | rest
    ]
  end

  defp add_duration(specs, _pending, _ms), do: specs

  defp blank(""), do: "(unnamed)"
  defp blank(name), do: text(name)

  # --- rows ----------------------------------------------------------------------------------

  defp case_of(name, status, duration, message) do
    %{"name" => text(name) || "(unnamed)", "status" => status, "durationMs" => duration}
    |> then(&if(message, do: Map.put(&1, "message", message), else: &1))
  end

  # {file, case} pairs → one row per file, in the order files first appear.
  defp rows(cases, runner) do
    order = cases |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    by_file = Enum.group_by(cases, &elem(&1, 0), &elem(&1, 1))

    for file <- order do
      list = by_file[file]
      failed = Enum.count(list, &(&1["status"] == "failed"))
      skipped = Enum.count(list, &(&1["status"] == "skipped"))

      status =
        cond do
          failed > 0 -> "failed"
          skipped == length(list) -> "skipped"
          true -> "passed"
        end

      %{
        "file" => String.replace(text(file), "\\", "/"),
        "runner" => runner,
        "tests" => length(list),
        "failed" => failed,
        "skipped" => skipped,
        "durationMs" => list |> Enum.map(& &1["durationMs"]) |> Enum.sum(),
        "status" => status,
        "retries" => list |> Enum.map(&(&1["retries"] || 0)) |> Enum.sum(),
        "cases" => Enum.take(list, 1000)
      }
    end
  end

  defp seconds(value) when is_binary(value) do
    case Float.parse(String.replace(value, ",", "")) do
      {s, _} -> round(s * 1000)
      :error -> 0
    end
  end

  defp seconds(_value), do: 0

  defp float(text), do: text |> Float.parse() |> elem(0)

  defp string(value) when is_binary(value) and value != "", do: value
  defp string(_value), do: nil

  defp text(value) when is_binary(value), do: String.slice(value, 0, @max_text)
  defp text(_value), do: nil
end
