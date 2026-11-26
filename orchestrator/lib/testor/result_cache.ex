defmodule Testor.ResultCache do
  @moduledoc """
  Results kept by what was run (`docs/handoff.md`, "Result cache"): a job of a snapshot whose
  result is already known is answered at once, pointing at the run that gave it, instead of
  running again.

  Only projects whose `agent.json` says `"cache": true` (passing results) or `"cache": "all"`
  (failures too) are kept, since only their owner knows the tests are hermetic: the agent then
  sends, with the job's end, the hash of everything it declares as an input (the command entry,
  the values of its `inputs` variables, its version, platform and executor image). The key is a
  SHA-256 over that hash, the snapshot, the project, the kind or `argv`, the selection and the
  labels. A run the agent marks `noCache` (a flaky spec) is never kept, a job with
  `"cache": false` or `"clean": true` never reads it, and entries go after `cache.days` (7) or
  once the agent reports another hash for the command (its entry changed).

  Keys (`Testor.Storage`): `results/<project>/<key>.json`, and the latest input hash of each
  kind at `results/<project>/inputs/<kind>.json`.
  """
  alias Testor.{Config, Storage}

  @day 86_400

  def days, do: get_in(Config.user(), ["cache", "days"]) || 7

  @doc "The key of `job` given the agent's input hash."
  def key(job, inputs) do
    [
      job["snapshot"],
      job["project"],
      job["kind"],
      job["argv"],
      Map.delete(job["select"] || %{}, "changed"),
      Enum.sort(job["labels"] || []),
      inputs
    ]
    |> JSON.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc "A cached result for a job about to be queued: `{:ok, %{\"job\", \"status\", \"exitCode\"}}` or `:miss`."
  def lookup(%{"snapshot" => _} = job, now \\ System.os_time(:second)) do
    {adapter, cfg} = Storage.blob()

    with {:ok, data} <- adapter.get(cfg, inputs_key(job), :binary),
         {:ok, %{"inputs" => inputs}} <- JSON.decode(data),
         key = key(job, inputs),
         {:ok, data} <- adapter.get(cfg, result_key(job["project"], key), :binary),
         {:ok, %{"at" => at, "inputs" => ^inputs} = hit} <- JSON.decode(data),
         true <- now - at <= days() * @day do
      {:ok, Map.take(hit, ["job", "status", "exitCode"])}
    else
      _ -> :miss
    end
  end

  @doc """
  Keeps the result of `job`, which ended with `result` (the agent's `finish`: `cache`, `noCache`)
  and `status`.
  """
  def record(%{"snapshot" => _} = job, result, status) do
    with %{"inputs" => inputs, "mode" => mode} when is_binary(inputs) and mode in ["passed", "all"] <-
           result["cache"],
         true <- result["noCache"] != true,
         true <- status == "passed" or (mode == "all" and status == "failed") do
      {adapter, cfg} = Storage.blob()
      now = System.os_time(:second)
      adapter.put(cfg, inputs_key(job), JSON.encode!(%{"inputs" => inputs, "at" => now}))

      entry = %{
        "job" => job["id"],
        "status" => status,
        "exitCode" => result["exitCode"],
        "inputs" => inputs,
        "at" => now
      }

      adapter.put(cfg, result_key(job["project"], key(job, inputs)), JSON.encode!(entry))
    else
      _ -> :skip
    end
  end

  def record(_job, _result, _status), do: :skip

  defp inputs_key(job), do: "results/#{job["project"]}/inputs/#{job["kind"]}.json"
  defp result_key(project, key), do: "results/#{project}/#{key}.json"

  @doc "Deletes entries older than `cache.days`: how many."
  def sweep(now \\ System.os_time(:second)) do
    {adapter, cfg} = Storage.blob()

    with {:ok, entries} <- adapter.list(cfg, "results/"),
         old = for(%{key: k, modified: at} <- entries, is_integer(at) and now - at > days() * @day, do: k),
         {:ok, deleted, _} <- adapter.delete(cfg, old) do
      length(deleted)
    else
      _ -> 0
    end
  end
end
