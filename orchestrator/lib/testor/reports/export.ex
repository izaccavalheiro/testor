defmodule Testor.Reports.Export do
  @moduledoc """
  A run's spec table as a report for other tools (`GET /api/v1/runs/<id>/report.junit.xml`
  and `.../report.ctrf.json`), so a CI system shows the results of runs testor ran: one suite
  per spec file, its cases when a report gave them, else one case for the file.
  """

  @doc "JUnit XML (the common Jenkins/Surefire schema)."
  def junit(run, specs) do
    suites =
      for spec <- specs do
        cases = cases(spec)

        [
          ~s(  <testsuite name="#{esc(spec["file"])}" tests="#{length(cases)}" failures="#{count(cases, "failed")}" ),
          ~s(errors="0" skipped="#{count(cases, "skipped")}" time="#{secs(spec["durationMs"])}">\n),
          Enum.map(cases, &testcase(spec, &1)),
          "  </testsuite>\n"
        ]
      end

    total = specs |> Enum.flat_map(&cases/1)

    IO.iodata_to_binary([
      ~s(<?xml version="1.0" encoding="UTF-8"?>\n),
      ~s(<testsuites name="#{esc("#{run["project"]} #{run["kind"]}")}" tests="#{length(total)}" ),
      ~s(failures="#{count(total, "failed")}" errors="0" time="#{secs(run["durationMs"])}">\n),
      suites,
      "</testsuites>\n"
    ])
  end

  defp testcase(spec, c) do
    inner =
      case c["status"] do
        "failed" -> ~s(      <failure message="#{esc(c["message"] || "failed")}"/>\n)
        "skipped" -> "      <skipped/>\n"
        _ -> ""
      end

    open =
      ~s(    <testcase name="#{esc(c["name"])}" classname="#{esc(spec["file"])}" time="#{secs(c["durationMs"])}")

    if inner == "", do: [open, "/>\n"], else: [open, ">\n", inner, "    </testcase>\n"]
  end

  @doc "CTRF JSON (the Common Test Report Format)."
  def ctrf(run, specs) do
    tests =
      for spec <- specs, c <- cases(spec) do
        %{
          "name" => c["name"],
          "status" => c["status"],
          "duration" => c["durationMs"] || 0,
          "filePath" => spec["file"]
        }
        |> then(&if(c["message"], do: Map.put(&1, "message", c["message"]), else: &1))
        |> then(&if(c["retries"], do: Map.put(&1, "retries", c["retries"]), else: &1))
      end

    %{
      "results" => %{
        "tool" => %{"name" => "testor", "version" => to_string(Application.spec(:testor, :vsn))},
        "summary" => %{
          "tests" => length(tests),
          "passed" => Enum.count(tests, &(&1["status"] == "passed")),
          "failed" => Enum.count(tests, &(&1["status"] == "failed")),
          "skipped" => Enum.count(tests, &(&1["status"] == "skipped")),
          "pending" => 0,
          "other" => 0,
          "start" => millis(run["startedAt"]),
          "stop" => millis(run["endedAt"])
        },
        "tests" => tests,
        "environment" => %{"appName" => run["project"], "testEnvironment" => run["kind"]}
      }
    }
  end

  # A spec's cases, or the spec file itself as one case (from the console parser).
  defp cases(%{"cases" => [_ | _] = cases}), do: cases

  defp cases(spec),
    do: [%{"name" => spec["file"], "status" => spec["status"], "durationMs" => spec["durationMs"]}]

  defp count(cases, status), do: Enum.count(cases, &(&1["status"] == status))
  defp secs(ms) when is_integer(ms), do: :erlang.float_to_binary(ms / 1000, decimals: 3)
  defp secs(_ms), do: "0.000"

  defp millis(iso) do
    case Testor.Store.parse_time(iso) do
      {:ok, at} -> DateTime.to_unix(at, :millisecond)
      _ -> 0
    end
  end

  # Escaped, without the control characters XML 1.0 does not allow (a log's ANSI codes).
  defp esc(text) do
    text |> to_string() |> String.replace(~r/[\x00-\x08\x0B\x0C\x0E-\x1F]/, "") |> Plug.HTML.html_escape()
  end
end
