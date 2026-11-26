defmodule Testor.Digest do
  @moduledoc """
  A run's failures in a few lines (`GET /api/v1/runs/:id/digest`, `testor run --digest`, MCP
  `get_run`): its counts and duration, each failing spec and test with its message, and the
  first stack frames inside the project (frames of dependencies, the runtime and the standard
  library dropped). For people and AI agents that need what failed, not the whole log.
  """
  alias Testor.{Query, Reports, SpecParser, Store}

  @max_failures 50
  @max_frames 10
  @tail 256 * 1024

  # A frame's file:line, as JavaScript, Python, Go, Rust, Java and .NET print them.
  @frames [
    ~r/\bat (?:.+? \()?((?:[A-Za-z]:)?[^\s():]+\.\w+):(\d+)(?::\d+)?\)?$/,
    ~r/File "([^"]+)", line (\d+)/,
    ~r/^\s*((?:[A-Za-z]:)?[\w.\/\\-]+\.(?:go|rs|java|kt|cs|py|rb|ts|js|ex|exs)):(\d+)/,
    ~r/ in ((?:[A-Za-z]:)?[^\s:]+\.cs):line (\d+)/
  ]
  @foreign ~r{node_modules|site-packages|dist-packages|node:internal|<anonymous>|/usr/|/lib/python|\.cargo[/\\]registry|/rustc/|/go/src/|go/pkg/mod|\$GOROOT|/deps/}

  @doc "The digest of run `id`: a map (see the moduledoc), or nil when there is no such run."
  def get(id) do
    case Store.get(id) do
      nil -> nil
      run -> build(run, Reports.run_specs(id), Query.log(id, @tail, nil, 0).text)
    end
  end

  @doc false
  def build(run, specs, log) do
    failed = Enum.filter(specs, &(&1["status"] == "failed"))

    failures =
      failed
      |> Enum.flat_map(fn spec ->
        case for(c <- spec["cases"] || [], c["status"] == "failed", do: c) do
          [] ->
            [%{"file" => spec["file"]}]

          cases ->
            for c <- cases,
                do: %{"file" => spec["file"], "name" => c["name"]} |> put_if("message", c["message"])
        end
      end)
      |> Enum.take(@max_failures)

    %{
      "id" => run["id"],
      "project" => run["project"],
      "kind" => run["kind"],
      "status" => run["status"],
      "exitCode" => run["exitCode"],
      "durationMs" => run["durationMs"],
      "counts" => SpecParser.summary(specs),
      "failures" => failures,
      "frames" => frames(SpecParser.strip_ansi(log))
    }
    |> put_if("select", run["select"])
  end

  defp frames(log) do
    log
    |> String.split(~r/\r?\n/)
    |> Enum.flat_map(fn line ->
      case Enum.find_value(@frames, &Regex.run(&1, String.trim_trailing(line))) do
        [_, file, number] ->
          if Regex.match?(@foreign, file), do: [], else: ["#{String.replace(file, "\\", "/")}:#{number}"]

        _ ->
          []
      end
    end)
    |> Enum.uniq()
    |> Enum.take(@max_frames)
  end

  @doc "The digest as text: a line of counts, then each failure and the frames."
  def text(digest) do
    c = digest["counts"]

    seconds =
      if is_integer(digest["durationMs"]),
        do: " in #{Float.round(digest["durationMs"] / 1000, 1)} s",
        else: ""

    head =
      "#{digest["project"]} #{digest["kind"]}: #{digest["status"]} (exit #{inspect(digest["exitCode"])})#{seconds}; " <>
        "#{c["specs"]} spec files, #{c["passed"]} passed, #{c["failed"]} failed, #{c["skipped"]} skipped" <>
        if(digest["select"], do: " (scoped)", else: "")

    failures =
      for f <- digest["failures"] do
        "FAIL #{f["file"]}" <>
          if(f["name"], do: " > #{f["name"]}", else: "") <>
          if(f["message"], do: "\n  " <> String.replace(f["message"], "\n", "\n  "), else: "")
      end

    frames = for frame <- digest["frames"], do: "  at #{frame}"
    Enum.join([head | failures] ++ frames, "\n") <> "\n"
  end

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)
end
