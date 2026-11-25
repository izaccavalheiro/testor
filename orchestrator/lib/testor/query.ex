defmodule Testor.Query do
  @moduledoc """
  Read-side queries the versioned API and the MCP tools share: runs filtered and paged,
  the latest run of each project and task, a run's log filtered by text, and the outcome of
  a run that is still going.
  """
  alias Testor.{Config, Files, Store}

  @statuses ["running", "passed", "failed", "aborted", "cancelled"]
  @fields ~w(id project kind command status exitCode startedAt endedAt durationMs summary warning error screenshots artifacts artifactsBytes actor attested)

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
          (q == nil or matches?(run, q))
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
