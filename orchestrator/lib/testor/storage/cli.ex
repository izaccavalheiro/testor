defmodule Testor.Storage.CLI do
  @moduledoc """
  Moving a home into a bucket, checking it there, and leaving it (`docs/storage.md`), with the
  release's `eval`, the storage in config.json's `storage` (and `TESTOR_DATABASE_URL`, for the
  run index):

      bin/testor eval 'Testor.Storage.CLI.migrate()'          # the home into the bucket (and the index)
      bin/testor eval 'Testor.Storage.CLI.verify()'           # every object and signature read again
      bin/testor eval 'Testor.Storage.CLI.export(~s[/srv/testor-home])'   # the bucket back to files

  `migrate` can be stopped and run again: an object the bucket holds with the same SHA-256 (or,
  when it keeps none, the same size) is not sent twice, and a run's record goes last, with
  `"stored": true`, so a run is in the bucket whole or is sent again. Running runs are left for
  the next time. With PostgreSQL it also fills the run index and copies the agents' pinned keys.
  The audit trail's files go as `audit/<instance>/<yyyy-mm-dd>/<ms>.jsonl` objects.

  Each takes `only: [run ids]` to work on those runs alone.

  `verify` reads every stored run's attestation from the bucket, checks its signature with this
  testor's key, then reads each object it signs and compares its SHA-256: a run whose files were
  changed, lost or not all sent is named.
  """
  alias Testor.{Attestation, Cluster, Config, Files, Storage}
  alias Testor.Storage.Shared

  @doc "Copies the home's finished runs into the bucket: `{:ok, counts}` or `{:error, why}`."
  def migrate(opts \\ []) do
    with {:ok, cfg} <- start() do
      out = Keyword.get(opts, :out, &IO.puts/1)
      pg = Testor.Jobs.Postgres.enabled?()
      if pg, do: Shared.migrate!()

      counts =
        for name <- Files.ls(Config.runs_dir()),
            String.ends_with?(name, ".json"),
            id = Path.rootname(name),
            only?(opts, id),
            {:ok, run} <- [Files.read_json(Config.run_file(id))],
            run["status"] != "running",
            reduce: %{runs: 0, sent: 0, kept: 0, bytes: 0, failed: 0, missed: 0} do
          acc -> migrate_run(cfg, id, Map.put(run, "id", id), pg, acc, out)
        end

      counts = audit(cfg, counts)
      if pg, do: Testor.AgentKeys.Shared.import(Testor.AgentKeys.Local.all())

      out.(
        "#{counts.runs} runs stored, #{counts.sent} objects sent (#{counts.bytes} bytes), " <>
          "#{counts.kept} already there, #{counts.failed} runs and #{counts.missed} audit files not sent"
      )

      if counts.failed + counts.missed == 0,
        do: {:ok, counts},
        else: {:error, "#{counts.failed} runs and #{counts.missed} audit files could not be stored"}
    end
  end

  defp migrate_run(cfg, id, run, pg, acc, out) do
    keys = id |> Storage.local_keys() |> Enum.reject(fn {key, _} -> key == "runs/#{id}.json" end)

    result =
      Enum.reduce_while(keys, {:ok, acc}, fn {key, path}, {:ok, acc} -> send_one(cfg, key, path, acc) end)

    record = Map.put(run, "stored", true)

    with {:ok, acc} <- result,
         :ok <- Storage.adapter_for(cfg).put(cfg, "runs/#{id}.json", JSON.encode!(record)) do
      Files.write_json(Config.run_file(id), record)
      if pg, do: Shared.put(record)
      %{acc | runs: acc.runs + 1}
    else
      {:error, why} ->
        out.("#{id}: #{why}")
        %{acc | failed: acc.failed + 1}
    end
  end

  defp send_one(cfg, key, path, acc) do
    if same?(cfg, key, path) do
      {:cont, {:ok, %{acc | kept: acc.kept + 1}}}
    else
      case Storage.adapter_for(cfg).put(cfg, key, {:file, path}) do
        :ok -> {:cont, {:ok, %{acc | sent: acc.sent + 1, bytes: acc.bytes + Files.size(path)}}}
        {:error, why} -> {:halt, {:error, "#{key}: #{why}"}}
      end
    end
  end

  # The bucket's object is this file: its checksum, or its size when it keeps none.
  defp same?(cfg, key, path) do
    case Storage.adapter_for(cfg).head(cfg, key) do
      {:ok, %{sha256: sum}} when is_binary(sum) -> sum == Base.encode64(sha256(path))
      {:ok, %{size: size}} -> size == Files.size(path)
      _ -> false
    end
  end

  defp audit(cfg, counts) do
    for name <- Files.ls(Config.data_dir()),
        String.starts_with?(name, "audit") and String.ends_with?(name, ".jsonl"),
        path = Path.join(Config.data_dir(), name),
        {:file, _, mtime} = Files.entry(path),
        reduce: counts do
      acc ->
        at = DateTime.from_unix!(mtime)
        ms = (mtime * 1000) |> Integer.to_string() |> String.pad_leading(13, "0")
        key = "audit/#{Cluster.instance()}/#{Date.to_iso8601(DateTime.to_date(at))}/#{ms}.jsonl"

        case send_one(cfg, key, path, acc) do
          {:cont, {:ok, acc}} -> acc
          {:halt, {:error, _}} -> %{acc | missed: acc.missed + 1}
        end
    end
  end

  @doc """
  Reads every stored run's attestation and signed objects from the bucket again:
  `{:ok, %{runs, objects, unsigned}}`, or `{:error, problems}` (`[{run, why}]`).
  """
  def verify(opts \\ []) do
    with {:ok, cfg} <- start(),
         {:ok, objects} <- Storage.adapter_for(cfg).list(cfg, "runs/") do
      out = Keyword.get(opts, :out, &IO.puts/1)
      {public, _} = Attestation.keypair()
      ids = stored_ids(objects, opts)

      result =
        Enum.reduce(ids, %{runs: 0, objects: 0, unsigned: 0, problems: []}, fn id, acc ->
          case verify_run(cfg, id, public) do
            {:ok, n} -> %{acc | runs: acc.runs + 1, objects: acc.objects + n}
            :unsigned -> %{acc | unsigned: acc.unsigned + 1}
            {:error, why} -> %{acc | problems: [{id, why} | acc.problems]}
          end
        end)

      out.(
        "#{result.runs} runs verified (#{result.objects} objects), #{result.unsigned} not signed, #{length(result.problems)} with problems"
      )

      for {id, why} <- Enum.reverse(result.problems), do: out.("#{id}: #{why}")

      if result.problems == [],
        do: {:ok, Map.delete(result, :problems)},
        else: {:error, Enum.reverse(result.problems)}
    end
  end

  defp verify_run(cfg, id, public) do
    with {:ok, text} <- Storage.adapter_for(cfg).get(cfg, "attestations/#{id}.dsse.json", :binary),
         {:ok, envelope} <- JSON.decode(text),
         {:ok, statement} <- Attestation.verify(envelope, public) do
      Enum.reduce_while(statement["subject"] || [], {:ok, 0}, fn subject, {:ok, n} ->
        case check_subject(cfg, id, subject) do
          :ok -> {:cont, {:ok, n + 1}}
          {:error, why} -> {:halt, {:error, why}}
        end
      end)
    else
      :not_found -> :unsigned
      {:error, :signature} -> {:error, "its attestation's signature is not this testor's key's"}
      _ -> {:error, "its attestation cannot be read"}
    end
  end

  defp check_subject(cfg, id, %{"name" => name, "digest" => %{"sha256" => digest}}) do
    key =
      case String.split(name, "/", parts: 2) do
        ["log"] -> "logs/#{id}.log"
        [area, rel] -> "#{area}/#{id}/#{rel}"
      end

    tmp = Path.join(System.tmp_dir!(), "testor-verify-#{System.unique_integer([:positive])}")

    try do
      case Storage.adapter_for(cfg).get(cfg, key, {:file, tmp}) do
        :ok ->
          if Base.encode16(sha256(tmp), case: :lower) == digest, do: :ok, else: {:error, "#{key} has changed"}

        _ ->
          {:error, "#{key} is missing"}
      end
    after
      File.rm(tmp)
    end
  end

  @doc "Copies every run in the bucket into a home at `dir` (to leave the bucket): `{:ok, runs}`."
  def export(dir, opts \\ []) do
    with {:ok, cfg} <- start(),
         {:ok, objects} <- Storage.adapter_for(cfg).list(cfg, "runs/") do
      out = Keyword.get(opts, :out, &IO.puts/1)
      ids = stored_ids(objects, opts)

      for id <- ids do
        {:ok, keys} = Storage.stored_keys(id, Storage.adapter_for(cfg), cfg)

        for %{key: key, size: size} <- keys, Files.size(Path.join(dir, key)) != size or size == 0 do
          with {:error, why} <- Storage.adapter_for(cfg).get(cfg, key, {:file, Path.join(dir, key)}),
               do: out.("#{key}: #{why}")
        end
      end

      out.("#{length(ids)} runs exported to #{dir}")
      {:ok, length(ids)}
    end
  end

  # `only: [ids]` limits a command to those runs.
  defp only?(opts, id), do: opts[:only] == nil or id in opts[:only]

  defp stored_ids(objects, opts) do
    for %{key: "runs/" <> name} <- objects,
        String.ends_with?(name, ".json"),
        id = Path.rootname(name),
        only?(opts, id),
        do: id
  end

  # HTTP for :httpc (eval does not start the application) and the bucket from config.json.
  defp start do
    {:ok, _} = Application.ensure_all_started([:inets, :ssl])
    pg = Testor.Jobs.Postgres.enabled?() and Process.whereis(Testor.Jobs.Postgres) == nil
    if pg, do: {:ok, _} = Testor.Jobs.Postgres.start_link()

    case Storage.read_config() do
      %{type: type} = cfg when type in [:s3, :azure] -> {:ok, cfg}
      _ -> {:error, ~s(config.json has no "storage" of type "s3" or "azure")}
    end
  end

  defp sha256(path) do
    path
    |> File.stream!(1_048_576)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
  end
end
