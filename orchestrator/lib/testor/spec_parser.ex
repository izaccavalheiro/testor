defmodule Testor.SpecParser do
  @moduledoc """
  Per-spec results read from a run's output, fed line by line so a live run's results grow as
  its log does. Understands Vitest's default reporter, Playwright's list reporter (ok/x on
  Windows terminals), pytest, go test and cargo test. No project has to change its reporters.
  """

  defstruct specs: %{}, order: [], cargo: nil

  @type t :: %__MODULE__{}

  def new, do: %__MODULE__{}

  @doc "Feeds lines (ANSI codes allowed) into the parser."
  def feed(%__MODULE__{} = state, lines), do: Enum.reduce(lines, state, &line/2)

  @doc "Parses a whole text at once."
  def parse(text), do: new() |> feed(String.split(text, ~r/\r?\n/)) |> specs()

  @doc "The specs in the order they first appeared, each with a status."
  def specs(%__MODULE__{specs: specs, order: order}) do
    order |> Enum.reverse() |> Enum.map(&finish(Map.fetch!(specs, &1)))
  end

  def summary(specs) do
    %{
      "specs" => length(specs),
      "passed" => Enum.count(specs, &(&1["status"] == "passed")),
      "failed" => Enum.count(specs, &(&1["status"] == "failed")),
      "skipped" => Enum.count(specs, &(&1["status"] == "skipped")),
      "tests" => specs |> Enum.map(& &1["tests"]) |> Enum.sum()
    }
  end

  def strip_ansi(text), do: Regex.replace(re(:ansi), text, "")

  @doc "The spec a screenshot belongs to: Playwright names its folders after the spec file."
  def spec_of(path, specs) do
    path = String.downcase(path)

    specs
    |> Enum.map(fn spec -> {stem(spec["file"]), spec["file"]} end)
    |> Enum.filter(fn {stem, _} -> stem != "" and String.contains?(path, stem) end)
    |> Enum.max_by(fn {stem, _} -> String.length(stem) end, fn -> {nil, nil} end)
    |> elem(1)
  end

  defp stem(file) do
    file |> Path.basename() |> String.replace(re(:spec_ext), "") |> String.downcase()
  end

  # --- lines -------------------------------------------------------------------------------

  defp line(raw, state) do
    line = strip_ansi(raw)

    cond do
      m = Regex.run(re(:vitest), line) -> vitest(state, m)
      m = Regex.run(re(:playwright), line) -> playwright(state, m)
      m = Regex.run(re(:pytest), line) -> pytest(state, m)
      m = Regex.run(re(:go), line) -> go(state, m)
      m = Regex.run(re(:cargo_running), line) -> %{state | cargo: Enum.at(m, 1)}
      (m = Regex.run(re(:cargo_result), line)) && state.cargo -> cargo(state, m)
      true -> state
    end
  end

  defp vitest(state, m) do
    [_, mark, file | rest] = m
    info = Enum.at(rest, 0, "")
    duration = Enum.at(rest, 1, "")

    update(state, file, "vitest", fn spec ->
      tests = capture_int(:tests, info) || spec["tests"]
      failed = capture_int(:failed, info) || 0
      failed = if mark in ["×", "✗", "✘"] and failed == 0, do: 1, else: failed
      skipped = capture_int(:skipped, info) || 0
      skipped = if mark == "↓", do: max(tests, 1), else: skipped

      %{
        spec
        | "tests" => tests,
          "failed" => failed,
          "skipped" => skipped,
          "durationMs" => to_ms(duration) || spec["durationMs"]
      }
    end)
  end

  defp playwright(state, m) do
    [_, mark, file | rest] = m

    update(state, file, "playwright", fn spec ->
      %{
        spec
        | "tests" => spec["tests"] + 1,
          "failed" => spec["failed"] + if(mark in ["x", "✘", "×"], do: 1, else: 0),
          "skipped" => spec["skipped"] + if(mark in ["-", "°", "~"], do: 1, else: 0),
          "durationMs" => spec["durationMs"] + (to_ms(Enum.at(rest, 0, "")) || 0)
      }
    end)
  end

  defp pytest(state, [_, file, marks]) do
    update(state, file, "pytest", fn spec ->
      %{
        spec
        | "tests" => spec["tests"] + String.length(marks),
          "failed" => spec["failed"] + count(marks, ~w(F E)),
          "skipped" => spec["skipped"] + count(marks, ~w(s x))
      }
    end)
  end

  defp go(state, [_, result, package, duration]) do
    update(state, package, "go", fn spec ->
      %{
        spec
        | "tests" => max(spec["tests"], 1),
          "failed" => if(result == "FAIL", do: 1, else: 0),
          "durationMs" => to_ms(duration) || 0
      }
    end)
  end

  defp cargo(state, [_, _result, passed, failed, ignored]) do
    [passed, failed, ignored] = Enum.map([passed, failed, ignored], &String.to_integer/1)

    update(state, state.cargo, "cargo", fn spec ->
      %{spec | "tests" => passed + failed + ignored, "failed" => failed, "skipped" => ignored}
    end)
  end

  defp update(state, file, runner, fun) do
    key = String.replace(file, "\\", "/")

    {spec, order} =
      case state.specs do
        %{^key => spec} ->
          {spec, state.order}

        _ ->
          spec = %{
            "file" => key,
            "runner" => runner,
            "tests" => 0,
            "failed" => 0,
            "skipped" => 0,
            "durationMs" => 0
          }

          {spec, [key | state.order]}
      end

    %{state | specs: Map.put(state.specs, key, fun.(spec)), order: order}
  end

  defp finish(spec) do
    status =
      cond do
        spec["failed"] > 0 -> "failed"
        spec["tests"] > 0 and spec["skipped"] == spec["tests"] -> "skipped"
        true -> "passed"
      end

    Map.put(spec, "status", status)
  end

  defp count(marks, chars), do: marks |> String.graphemes() |> Enum.count(&(&1 in chars))

  defp capture_int(name, text) do
    case Regex.run(re(name), text) do
      [_, n] -> String.to_integer(n)
      _ -> nil
    end
  end

  defp to_ms(""), do: nil
  defp to_ms(nil), do: nil

  defp to_ms(text) do
    case Float.parse(text) do
      {value, "ms"} -> round(value)
      {value, "s"} -> round(value * 1000)
      _ -> nil
    end
  end

  # --- patterns ----------------------------------------------------------------------------
  # Compiled once into :persistent_term: OTP 28+ cannot keep compiled regexes in attributes.

  defp re(name) do
    case :persistent_term.get({__MODULE__, name}, nil) do
      nil -> Map.fetch!(compile(), name)
      re -> re
    end
  end

  defp compile do
    spec = ~S"[\w@.+/\\-]+?\.(?:test|spec)\.[cm]?[jt]sx?"

    sources = %{
      ansi: ~S"\e\[[0-9;?]*[ -/]*[@-~]",
      spec_ext: ~S"\.(?:test|spec)\.[cm]?[jt]sx?$",
      # " ✓ tests/a.test.ts (12 tests) 34ms", " ❯ |web| src/b.test.ts (3 tests | 1 failed) 8ms"
      vitest:
        ~S"^\s*([✓√✔×✗✘❯>↓])\s+(?:\|[^|]+\|\s+)?(" <>
          spec <> ~S")(?:\s+\(([^)]*)\))?(?:\s+(\d+(?:\.\d+)?m?s))?\s*$",
      # "  ok 3 [chromium] › e2e/auth.spec.ts:12:3 › signs in (1.2s)"
      playwright:
        ~S"^\s*(ok|x|✓|✘|×|-|°|~)\s+\d+\s+(?:\[[^\]]+\]\s+[›>]\s+)?(" <>
          spec <> ~S"):\d+:\d+\s+[›>]\s+.*?(?:\((\d+(?:\.\d+)?m?s)\))?\s*$",
      # "tests/test_api.py ..F.s   [ 40%]"
      pytest: ~S"^(\S+\.py)\s+([.FEsxX]+)\s*(?:\[\s*\d+%\])?\s*$",
      # "ok  	example.com/pkg	0.12s", "FAIL	example.com/pkg	0.3s"
      go: ~S"^(ok|FAIL)\s+(\S+)\s+(\d+(?:\.\d+)?s|\(cached\))",
      # "     Running tests/conformance.rs (target\...)", then "test result: ok. 12 passed; ..."
      cargo_running: ~S"^\s*Running (?:unittests )?(\S+)",
      cargo_result: ~S"^test result: (ok|FAILED)\. (\d+) passed; (\d+) failed; (\d+) ignored",
      tests: ~S"(\d+) tests?",
      failed: ~S"(\d+) failed",
      skipped: ~S"(\d+) skipped"
    }

    compiled = Map.new(sources, fn {name, source} -> {name, Regex.compile!(source, "u")} end)
    Enum.each(compiled, fn {name, re} -> :persistent_term.put({__MODULE__, name}, re) end)
    compiled
  end
end
