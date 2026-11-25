defmodule Testor.Remote do
  @moduledoc """
  Runs recorded on other machines: an agent (`runner/agent.ps1` with `"upload": true`) runs a
  job through run.ps1 in a testor home of its own, and sends what run.ps1 writes there:

    * the run's record, as it changes (`PUT /api/v1/agent/jobs/:id/run`);
    * its log, in chunks appended at a given offset (`POST /api/v1/agent/jobs/:id/log?offset=`),
      so a chunk sent twice is not appended twice;
    * its screenshots and artifacts (`PUT /api/v1/agent/jobs/:id/files/<area>/<path>`).

  testor writes them into its own home as run.ps1 would, so everything else (the store, live
  log, specs, attestations, webhooks) treats the run like a local one.

  An agent only writes the run of a job it holds. The record's project, task (`kind`) and job
  come from the job, never from the agent; `remote` names the agent and `pid` is dropped (the
  process is on the agent's machine: the job's lease watches it). A run whose record is final
  cannot be changed. Paths of files are checked like the file routes' (no `..`, no
  separators), screenshots must be images, and a run's artifacts stay under
  `artifacts.maxRunMB`.
  """
  alias Testor.{Config, Files, Jobs}

  @run_id ~r/^\d{8}-\d{6}-[0-9a-f]{6}$/
  @fields ~w(id command workdir startedAt endedAt durationMs status exitCode error actor source screenshots artifacts artifactsBytes artifactsSkipped)
  @statuses ["running", "passed", "failed", "cancelled", "aborted"]

  @doc "Writes the record `params` of job `id`'s run for `agent`: `{:ok, run}` or `{:error, reason}`."
  def record(id, agent, params) do
    with {:ok, run_id} <- run_id(params["id"]),
         true <- params["status"] in @statuses || {:error, :bad_status},
         {:ok, _job} <- Jobs.held(id, agent),
         :ok <- open(run_id, id),
         {:ok, job} <- Jobs.bind_run(id, agent, run_id) do
      run =
        params
        |> Map.take(@fields)
        |> Map.merge(%{
          "project" => job["project"],
          "kind" => job["kind"],
          "job" => id,
          "remote" => agent,
          "pid" => nil
        })

      File.mkdir_p!(Config.runs_dir())
      Files.write_json(Config.run_file(run_id), run)
      {:ok, run}
    end
  end

  @doc "Appends `data` to the log of job `id`'s run at `offset`: `{:ok, size}` or `{:error, reason}`."
  def append_log(id, agent, offset, data) do
    with {:ok, run_id} <- bound_run(id, agent) do
      path = Config.log_file(run_id)
      size = Files.size(path)

      cond do
        offset != size ->
          {:error, {:offset, size}}

        size + byte_size(data) > Application.get_env(:testor, :remote_log_max, 256 * 1024 * 1024) ->
          {:error, :too_large}

        true ->
          File.mkdir_p!(Config.logs_dir())
          File.write!(path, data, [:append])
          {:ok, size + byte_size(data)}
      end
    end
  end

  @agent_predicate "https://github.com/izaccavalheiro/testor/blob/main/docs/attestation.md#agent-run-v1"
  @statement_type "https://in-toto.io/Statement/v1"
  @payload_type "application/vnd.in-toto+json"

  def agent_predicate, do: @agent_predicate
  def agent_file(run_id), do: Path.join(Config.attestations_dir(), run_id <> ".agent.dsse.json")

  @doc """
  Keeps the agent's own attestation of job `id`'s run (a DSSE envelope of an in-toto statement,
  ECDSA P-256 with the agent's pinned key): `{:ok, %{"subjects" => n}}` once its signature holds
  and its subjects are exactly the run's files testor has, each with the SHA-256 testor computes
  (nothing lost or changed on the way), or `{:error, reason}`.
  """
  def attest(id, agent, envelope) do
    with {:ok, run_id} <- bound_run(id, agent),
         {:ok, key} <- key_of(agent),
         {:ok, statement} <- verify(envelope, key),
         :ok <- about(statement, run_id, id),
         :ok <- same_files(statement["subject"], run_id) do
      File.mkdir_p!(Config.attestations_dir())
      Files.write_json(agent_file(run_id), envelope)
      {:ok, %{"subjects" => length(statement["subject"])}}
    end
  end

  defp key_of(agent) do
    case Testor.AgentKeys.get(agent) do
      nil -> {:error, :no_key}
      key -> {:ok, key}
    end
  end

  @doc "The statement in an agent's `envelope` when its signature is `key`'s; else `{:error, reason}`."
  def verify(
        %{"payloadType" => @payload_type, "payload" => payload, "signatures" => [_ | _] = signatures},
        key
      ) do
    with {:ok, payload} <- Base.decode64(payload),
         true <- Enum.any?(signatures, &signed?(&1, payload, key)) || {:error, :signature},
         {:ok, %{"_type" => @statement_type, "predicateType" => @agent_predicate} = statement} <-
           JSON.decode(payload) do
      {:ok, statement}
    else
      {:error, :signature} -> {:error, :signature}
      _ -> {:error, :malformed}
    end
  end

  def verify(_envelope, _key), do: {:error, :malformed}

  defp signed?(%{"sig" => sig}, payload, key) when is_binary(sig) do
    case Base.decode64(sig) do
      # A signature that is not DER verifies as false.
      {:ok, der} -> :public_key.verify(pae(payload), :sha256, der, key)
      :error -> false
    end
  end

  defp signed?(_signature, _payload, _key), do: false

  defp pae(payload),
    do: "DSSEv1 #{byte_size(@payload_type)} #{@payload_type} #{byte_size(payload)} " <> payload

  defp about(%{"predicate" => %{"run" => %{"id" => run_id, "job" => job}}}, run_id, job), do: :ok
  defp about(_statement, _run_id, _job), do: {:error, :not_this_run}

  # The subjects name the run's log, screenshots and artifacts: all of them, as testor has them.
  defp same_files(subjects, run_id) when is_list(subjects) do
    signed =
      for %{"name" => name, "digest" => %{"sha256" => digest}} <- subjects,
          into: %{},
          do: {name, String.downcase(digest)}

    held = held_files(run_id)

    cond do
      map_size(signed) != length(subjects) -> {:error, :malformed}
      Map.keys(signed) |> Enum.sort() != Map.keys(held) |> Enum.sort() -> {:error, :files_differ}
      Enum.any?(held, fn {name, path} -> sha256(path) != signed[name] end) -> {:error, :files_differ}
      true -> :ok
    end
  end

  defp same_files(_subjects, _run_id), do: {:error, :malformed}

  defp held_files(run_id) do
    log = if Files.entry(Config.log_file(run_id)) != :skip, do: [{"log", Config.log_file(run_id)}], else: []

    areas =
      for {area, dir} <- [{"screenshots", Config.shots_dir()}, {"artifacts", Config.artifacts_dir()}],
          file <- Files.walk(Path.join(dir, run_id)),
          do: {area <> "/" <> String.replace(file.rel, "\\", "/"), file.full}

    Map.new(log ++ areas)
  end

  defp sha256(path) do
    path
    |> File.stream!(65_536)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  @doc """
  Writes a screenshot or artifact (`area`: `"screenshots"` or `"artifacts"`) of job `id`'s run
  at the path `segments`: `{:ok, bytes}` or `{:error, reason}`.
  """
  def put_file(id, agent, area, segments, data) do
    with {:ok, run_id} <- bound_run(id, agent),
         {:ok, root} <- area_root(area, run_id),
         true <- safe?(segments) || {:error, :bad_path},
         path = Path.join([root | segments]),
         true <- (area != "screenshots" or Files.image_type(path) != nil) || {:error, :not_an_image},
         :ok <- fits(area, root, path, byte_size(data)) do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, data)
      {:ok, byte_size(data)}
    end
  end

  # --- helpers ------------------------------------------------------------------------------

  defp run_id(id) do
    if is_binary(id) and Regex.match?(@run_id, id), do: {:ok, id}, else: {:error, :bad_run_id}
  end

  # A run that is another job's, or that has ended, is not this agent's to write.
  defp open(run_id, job) do
    case Files.read_json(Config.run_file(run_id)) do
      :error -> :ok
      {:ok, %{"job" => ^job, "status" => "running"}} -> :ok
      {:ok, %{"job" => ^job}} -> {:error, :final}
      {:ok, _} -> {:error, :other_run}
    end
  end

  defp bound_run(id, agent) do
    with {:ok, job} <- Jobs.held(id, agent) do
      case job["runId"] do
        nil -> {:error, :no_run}
        run_id -> with :ok <- open(run_id, id), do: {:ok, run_id}
      end
    end
  end

  defp area_root("screenshots", run_id), do: {:ok, Path.join(Config.shots_dir(), run_id)}
  defp area_root("artifacts", run_id), do: {:ok, Path.join(Config.artifacts_dir(), run_id)}
  defp area_root(_area, _run_id), do: {:error, :bad_path}

  defp safe?(segments) do
    segments != [] and length(segments) <= 32 and
      Enum.all?(segments, &(&1 not in ["", ".", ".."] and not String.contains?(&1, ["/", "\\", ":", <<0>>])))
  end

  defp fits("artifacts", root, path, bytes) do
    limit = Config.retention()["artifacts"]["maxRunMB"] * 1024 * 1024
    used = root |> Files.usage() |> Map.fetch!("bytes")
    if used - Files.size(path) + bytes > limit, do: {:error, :too_large}, else: :ok
  end

  defp fits("screenshots", _root, _path, _bytes), do: :ok
end
