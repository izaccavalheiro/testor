defmodule Testor.Batches do
  @moduledoc """
  A batch's end (`Testor.Shards`): once its last shard has ended, its runs are merged
  (`Testor.Reports.Merge`) into one run of the batch, signed like any other run, and the parent
  job ends with it. The parent fails if any shard failed or has no run.

  The merged run's record lists each shard (job, run, status, duration) with the SHA-256 of the
  shard's attestation, so its own signature binds theirs. Its spec table comes from a CTRF
  report of the shards' results (`reports/<id>/shards.ctrf.json`), its mutation and coverage
  from the merge; gates and commit statuses read it, not the shards (they carry `shard`).
  """
  require Logger
  alias Testor.{Config, Files, Jobs, Reports, Store}
  alias Testor.Reports.Merge

  @over ["passed", "failed", "cancelled", "expired"]

  @doc "Merges batch `parent`'s shards when they have all ended; once (the first caller claims it)."
  def settle(parent) do
    with %{"batch" => true, "children" => ids} <- Jobs.stored(parent),
         children = Enum.map(ids, &Jobs.get/1),
         true <- Enum.all?(children, &(&1["status"] in @over)),
         :ok <- Jobs.claim_batch(parent) do
      runs = for %{"runId" => run} <- children, record = wait_run(run), do: record
      passed = Enum.all?(children, &(&1["status"] == "passed")) and length(runs) == length(children)

      status =
        cond do
          Jobs.stored(parent)["cancelRequested"] -> "cancelled"
          passed -> "passed"
          true -> "failed"
        end

      run = write(Jobs.stored(parent), children, runs, status)
      Jobs.end_batch(parent, status, run)
      {:ok, run}
    else
      _ -> :pending
    end
  end

  # A shard's run record, once testor has it as ended (an agent's upload lands a moment later).
  defp wait_run(id, tries \\ Application.get_env(:testor, :batch_wait_tries, 120)) do
    case Store.get(id) do
      %{"status" => s} = run when s != "running" ->
        run

      _ when tries > 0 ->
        Process.sleep(250)
        wait_run(id, tries - 1)

      _ ->
        nil
    end
  end

  defp write(parent, children, runs, status) do
    id =
      Calendar.strftime(DateTime.utc_now(), "%Y%m%d-%H%M%S-") <>
        Base.encode16(:crypto.strong_rand_bytes(3), case: :lower)

    merged = Merge.merge(runs)
    first = List.first(runs) || %{}

    dir = Reports.dir(id)
    File.mkdir_p!(dir)
    Files.write_json(Path.join(dir, "shards.ctrf.json"), ctrf(merged["specs"]))
    if merged["mutationDetail"], do: Files.write_json(Reports.detail_file(id), merged["mutationDetail"])

    if merged["coverageFiles"],
      do: Files.write_json(Reports.coverage_file(id), %{"files" => merged["coverageFiles"]})

    shards =
      for child <- children do
        run = Enum.find(runs, &(&1["id"] == child["runId"]))

        %{"job" => child["id"], "index" => child["shard"]["index"], "status" => child["status"]}
        |> put_if("run", run && run["id"])
        |> put_if("durationMs", run && run["durationMs"])
        |> put_if("attestation", run && attestation_digest(run["id"]))
      end

    started = runs |> Enum.map(& &1["startedAt"]) |> Enum.reject(&is_nil/1) |> Enum.min(fn -> nil end)
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    record =
      %{
        "id" => id,
        "project" => parent["project"],
        "kind" => parent["kind"],
        "command" => "batch of #{parent["shards"]} shards",
        "pid" => nil,
        "workdir" => nil,
        "startedAt" => started || now,
        "status" => status,
        "exitCode" => if(status == "passed", do: 0, else: 1),
        "endedAt" => now,
        "durationMs" => merged["durationMs"] || 0,
        "job" => parent["id"],
        "batch" => %{"shards" => shards, "cpuMs" => merged["cpuMs"]}
      }
      |> put_if("source", first["source"])
      |> put_if("mutation", merged["mutation"])
      |> put_if("coverage", merged["coverage"])

    # Ended, without a summary: Testor.Store finalizes it (its spec table from the CTRF report),
    # signs and announces it as any run.
    Files.write_json(Config.run_file(id), record)

    note =
      "batches: #{parent["id"]} #{status}: #{length(runs)} of #{length(children)} shards merged into #{id}"

    Logger.info(note)

    id
  end

  defp attestation_digest(run) do
    path = Path.join(Config.attestations_dir(), run <> ".dsse.json")
    if File.exists?(path), do: :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)
  end

  # The shards' spec rows as a CTRF report: the merged run's spec table, read as any report.
  defp ctrf(specs) do
    tests =
      Enum.flat_map(specs, fn spec ->
        case spec["cases"] do
          [_ | _] = cases ->
            for c <- cases,
                do:
                  %{
                    "name" => c["name"],
                    "status" => c["status"],
                    "duration" => c["durationMs"] || 0,
                    "filePath" => spec["file"]
                  }
                  |> put_if("message", c["message"])

          _ ->
            [
              %{
                "name" => spec["file"],
                "status" => spec["status"],
                "duration" => spec["durationMs"] || 0,
                "filePath" => spec["file"]
              }
            ]
        end
      end)

    %{"results" => %{"tool" => %{"name" => "testor shards"}, "tests" => tests}}
  end

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)
end
