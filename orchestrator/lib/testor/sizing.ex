defmodule Testor.Sizing do
  @moduledoc """
  Predictive sizing (`docs/zero-config.md`, "Sizing"): from a project's last runs of a task, its
  p50 and p95 duration and p95 peak memory (`memory.peakMB`, what run.ps1 saw).

    * `"shards": "auto"` with `"target": "10m"` picks the number of shards from the p95
      duration (one shard per target's worth), at least 2 and at most 64, and no more than the
      slots of the agents seen lately (`Testor.Jobs.capacity/0`); a run that fits the target
      alone is a plain job.
    * Profiles in config.json (`execution.profiles`: `{name: {memoryMB, labels}}`) give a job a
      suggested profile, the smallest whose memory holds the p95 peak with a fifth to spare,
      shown on the job (`suggestedProfile`); `"profile": "auto"` adds its labels.
  """
  alias Testor.{Shards, Store}

  @history 30

  @doc "The history of `project`'s `kind`: `%{\"runs\", \"p50Ms\", \"p95Ms\", \"peakMB\"}` (nils without runs)."
  def estimate(project, kind) do
    runs =
      Store.all()
      |> Enum.filter(
        &(&1["project"] == project and &1["kind"] == kind and &1["status"] in ["passed", "failed"] and
            &1["shard"] == nil)
      )
      |> Enum.sort_by(&(&1["startedAt"] || ""), :desc)
      |> Enum.take(@history)

    durations = for %{"durationMs" => d} <- runs, is_integer(d), do: d
    peaks = for %{"memory" => %{"peakMB" => p}} <- runs, is_number(p), do: p

    %{
      "runs" => length(runs),
      "p50Ms" => pct(durations, 50),
      "p95Ms" => pct(durations, 95),
      "peakMB" => pct(peaks, 95)
    }
  end

  defp pct([], _p), do: nil
  defp pct(list, p), do: Shards.percentile(list, p)

  @doc """
  The shards for `"shards": "auto"` and `target` (seconds): `{:ok, n}` (1 means a plain job), or
  `{:error, message}`.
  """
  def shards(project, kind, target, capacity) do
    case estimate(project, kind) do
      %{"p95Ms" => nil} ->
        {:error, "shards auto needs history: no finished run of #{project} #{kind} yet"}

      %{"p95Ms" => p95} ->
        wanted = ceil(p95 / (target * 1000))
        {:ok, wanted |> min(64) |> min(max(capacity, 2)) |> then(&if(wanted <= 1, do: 1, else: max(&1, 2)))}
    end
  end

  @doc "The profile for `project`'s `kind` among `profiles` (`{name: {memoryMB, labels}}`): `{name, labels}` or nil."
  def profile(project, kind, profiles) when is_map(profiles) and map_size(profiles) > 0 do
    with %{"peakMB" => peak} when is_number(peak) <- estimate(project, kind) do
      profiles
      |> Enum.filter(fn {_, p} -> is_number(p["memoryMB"]) and p["memoryMB"] >= peak * 1.2 end)
      |> Enum.min_by(fn {name, p} -> {p["memoryMB"], name} end, fn -> nil end)
      |> case do
        nil -> nil
        {name, p} -> {name, Enum.filter(List.wrap(p["labels"]), &is_binary/1)}
      end
    else
      _ -> nil
    end
  end

  def profile(_project, _kind, _profiles), do: nil
end
