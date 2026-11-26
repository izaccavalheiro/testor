defmodule Testor.Query do
  @moduledoc """
  Read-side queries the versioned API and the MCP tools share: runs filtered and paged,
  the latest run of each project and task, a run's log filtered by text, and the outcome of
  a run that is still going.
  """
  alias Testor.{Config, Files, Store}

  @statuses ["running", "passed", "failed", "aborted", "cancelled"]
  @fields ~w(id project kind command status exitCode startedAt endedAt durationMs summary warning error screenshots artifacts artifactsBytes actor attested agentAttested archived stored source job remote)

  def statuses, do: @statuses

  @max_tail 8 * 1024 * 1024

  @doc "The most of a log one request reads (8 MB): a larger tail would hold that much memory per request."
  def max_tail, do: @max_tail

  @doc "A run without its process details (pid, workdir), with its live progress when it runs."
  def compact(run) do
    run = Store.with_live(run)
    live = Map.take(run, ["currentSpec", "logBytes"])
    run |> Map.take(@fields) |> Map.merge(live)
  end

  @doc """
  Runs, newest first, filtered by `status`, `project`, `kind` (exact) and `q` (a substring of
  the project, task or command, case-insensitive), at most `limit` from before the run id
  `before`. Returns `{runs, next}`, where `next` is the `before` of the next page or nil.
  """
  def runs(opts) do
    limit = opts |> Map.get(:limit, 50) |> max(1) |> min(500)
    q = opts[:q] && String.downcase(opts[:q])

    page =
      Store.all()
      |> Stream.filter(fn run ->
        (opts[:before] == nil or run["id"] < opts[:before]) and
          (opts[:status] == nil or run["status"] == opts[:status]) and
          (opts[:project] == nil or run["project"] == opts[:project]) and
          (opts[:kind] == nil or run["kind"] == opts[:kind]) and
          (q == nil or matches?(run, q)) and
          (opts[:allow] == nil or opts[:allow].(run["project"]))
      end)
      |> Enum.take(limit + 1)

    {runs, rest} = Enum.split(page, limit)
    next = if rest != [], do: List.last(runs)["id"]
    {Enum.map(runs, &compact/1), next}
  end

  defp matches?(run, q) do
    Enum.any?(["project", "kind", "command"], fn key ->
      is_binary(run[key]) and String.contains?(String.downcase(run[key]), q)
    end)
  end

  @doc """
  Flaky spec files of a project: ones that both passed and failed in runs of the same task on
  the same commit with no local changes (`source.commit`, `source.dirty: false`, which
  `remote.yml` records). Most failures first:

      [%{"file", "kind", "commits", "passed", "failed", "lastFailedRun"}]

  Optionally for one `kind` only. Runs without a recorded commit are left out: a failure on a
  working tree with changes is not evidence of flakiness.
  """
  def flaky(project, kind \\ nil) do
    Store.all()
    |> Enum.filter(fn run ->
      run["project"] == project and (kind == nil or run["kind"] == kind) and
        is_binary(get_in(run, ["source", "commit"])) and get_in(run, ["source", "dirty"]) == false and
        is_list(run["specs"])
    end)
    |> Enum.flat_map(fn run ->
      for %{"file" => file, "status" => status} when status in ["passed", "failed"] <- run["specs"],
          do: {{run["kind"], file}, run["source"]["commit"], status, run["id"]}
    end)
    |> Enum.group_by(&elem(&1, 0))
    |> Enum.flat_map(fn {{kind, file}, results} ->
      flaky_commits =
        results
        |> Enum.group_by(&elem(&1, 1), &elem(&1, 2))
        |> Enum.filter(fn {_commit, statuses} -> "passed" in statuses and "failed" in statuses end)
        |> Enum.map(&elem(&1, 0))

      if flaky_commits == [] do
        []
      else
        on_them = Enum.filter(results, &(elem(&1, 1) in flaky_commits))
        failed = for {_, _, "failed", id} <- on_them, do: id

        [
          %{
            "file" => file,
            "kind" => kind,
            "commits" => Enum.sort(flaky_commits),
            "passed" => Enum.count(on_them, &(elem(&1, 2) == "passed")),
            "failed" => length(failed),
            "lastFailedRun" => Enum.max(failed)
          }
        ]
      end
    end)
    |> Enum.sort_by(&{-&1["failed"], &1["file"]})
  end

  @doc """
  The spec files that cost a project most, over its last `limit` finished runs (of `kind`):
  `mostFailing` (failures, failure rate), `slowest` (mean and longest time) and `mostRetried`
  (retries CTRF reports give), 20 of each. Read from the records' spec outcomes, like `flaky/2`.
  """
  def hotspots(project, kind \\ nil, limit \\ 200) do
    rows =
      Store.all()
      |> Enum.filter(fn run ->
        run["project"] == project and (kind == nil or run["kind"] == kind) and run["status"] != "running" and
          is_list(run["specs"])
      end)
      |> Enum.take(limit)
      |> Enum.flat_map(fn run ->
        for %{"file" => file} = spec <- run["specs"], do: {{run["kind"], file}, spec}
      end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.map(fn {{kind, file}, specs} ->
        times = for %{"durationMs" => ms} <- specs, is_integer(ms), do: ms
        failed = Enum.count(specs, &(&1["status"] == "failed"))

        %{
          "file" => file,
          "kind" => kind,
          "runs" => length(specs),
          "failed" => failed,
          "failureRate" => Float.round(failed / length(specs), 3),
          "meanMs" => if(times == [], do: nil, else: div(Enum.sum(times), length(times))),
          "maxMs" => if(times == [], do: nil, else: Enum.max(times)),
          "retries" => specs |> Enum.map(&(&1["retries"] || 0)) |> Enum.sum()
        }
      end)

    %{
      "runs" => min(limit, rows |> Enum.map(& &1["runs"]) |> Enum.max(fn -> 0 end)),
      "mostFailing" =>
        rows
        |> Enum.filter(&(&1["failed"] > 0))
        |> Enum.sort_by(&{-&1["failed"], -&1["failureRate"], &1["file"]})
        |> Enum.take(20),
      "slowest" =>
        rows |> Enum.filter(& &1["meanMs"]) |> Enum.sort_by(&{-&1["meanMs"], &1["file"]}) |> Enum.take(20),
      "mostRetried" =>
        rows
        |> Enum.filter(&(&1["retries"] > 0))
        |> Enum.sort_by(&{-&1["retries"], &1["file"]})
        |> Enum.take(20)
    }
  end

  @doc "The latest run of each project and task, with the statuses of up to 10 runs before it."
  def projects do
    Store.all()
    |> Enum.group_by(&{&1["project"], &1["kind"]})
    |> Enum.map(fn {{project, kind}, [latest | _] = runs} ->
      %{
        "project" => project,
        "kind" => kind,
        "runs" => length(runs),
        "latest" => compact(latest),
        "recent" => runs |> Enum.take(10) |> Enum.map(& &1["status"])
      }
    end)
    |> Enum.sort_by(&{&1["project"] || "", &1["kind"] || ""})
  end

  @doc """
  The end of a run's output: the last `tail` bytes, and with `grep` only the lines that contain
  it (case-insensitive), each with `context` lines around it and its line number.
  Returns `%{text, size, truncated, matches}`.
  """
  def log(id, tail, grep, context) do
    Testor.Storage.local(id)
    log = Files.tail(Config.log_file(id), tail)

    case grep do
      nil ->
        Map.put(log, :matches, nil)

      "" ->
        Map.put(log, :matches, nil)

      needle ->
        lines = String.split(log.text, "\n")
        needle = String.downcase(needle)

        hits =
          lines
          |> Enum.with_index()
          |> Enum.filter(fn {line, _} -> String.contains?(String.downcase(line), needle) end)
          |> Enum.map(&elem(&1, 1))

        keep =
          hits
          |> Enum.flat_map(&Enum.to_list(max(&1 - context, 0)..(&1 + context)//1))
          |> MapSet.new()

        text =
          lines
          |> Enum.with_index()
          |> Enum.filter(fn {_, i} -> MapSet.member?(keep, i) end)
          |> Enum.map_join("\n", fn {line, i} -> "#{i + 1}: #{line}" end)

        %{log | text: text} |> Map.put(:matches, length(hits))
    end
  end

  @doc """
  Waits up to `timeout_ms` for a run to end. `{:ok, run}` once it has ended (or at the deadline
  while it still runs), `:not_found` when there is no such run.
  """
  def wait(id, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    wait_until(id, deadline)
  end

  defp wait_until(id, deadline) do
    case Store.get(id) do
      nil ->
        :not_found

      %{"status" => "running"} = run ->
        left = deadline - System.monotonic_time(:millisecond)

        if left <= 0 do
          {:ok, run}
        else
          Process.sleep(min(500, left))
          wait_until(id, deadline)
        end

      run ->
        {:ok, run}
    end
  end
end
