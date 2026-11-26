defmodule Testor.Archive do
  @moduledoc """
  Archiving finished runs to S3-compatible object storage (AWS S3, MinIO, Cloudflare R2, Google
  Cloud Storage's interoperability API, Ceph...): once a run is signed, its record, log,
  screenshots, artifacts and attestations are copied to a bucket, encrypted there, and kept
  however the bucket keeps them (lifecycle rules, Object Lock), whatever happens to the runner.

  `archive` in config.json:

      "archive": {
        "bucket": "acme-test-evidence",
        "region": "eu-west-1",
        "prefix": "testor/runner-1",                    (optional)
        "endpoint": "https://minio.example.com:9000",   (not AWS: the server's URL)
        "pathStyle": true,                              (MinIO and most compatibles)
        "encryption": "aws:kms", "kmsKeyId": "arn:aws:kms:...",   (or "AES256": SSE-S3)
        "objectLock": {"mode": "COMPLIANCE", "days": 365}         (a bucket with Object Lock)
      }

  Credentials come as AWS SDKs take them: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` and
  `AWS_SESSION_TOKEN`; or `AWS_ROLE_ARN` with `AWS_WEB_IDENTITY_TOKEN_FILE` (IAM roles for
  service accounts, or testor's own job tokens), traded with STS for short-lived ones. Each
  object carries its SHA-256 (`x-amz-checksum-sha256`), which the server checks.

  A run's archive is listed in `<home>/archive/<id>.json` (`archived` on the run); one that
  fails is tried again three times, then logged.
  """
  require Logger
  alias Testor.{Config, Files, Remote}

  # --- configuration -------------------------------------------------------------------------

  @doc "The `archive` section of config.json, checked; nil when absent or not valid (logged)."
  def config do
    case Config.user()["archive"] do
      nil -> nil
      %{} = raw -> check(raw)
      _ -> invalid("it is an object")
    end
  end

  defp check(raw) do
    lock = raw["objectLock"]

    cond do
      lock != nil and
          not (is_map(lock) and lock["mode"] in ["GOVERNANCE", "COMPLIANCE"] and is_integer(lock["days"]) and
                   lock["days"] > 0) ->
        invalid("objectLock is {mode: GOVERNANCE or COMPLIANCE, days}")

      true ->
        case Testor.Blob.S3.config(raw) do
          {:ok, config} -> %{config | lock: lock}
          {:error, why} -> invalid(why)
        end
    end
  end

  defp invalid(why) do
    Logger.warning("archive: config.json's archive is not valid (#{why}): runs are not archived")
    nil
  end

  # --- archiving -----------------------------------------------------------------------------

  def manifest(id), do: Path.join([Config.data_dir(), "archive", id <> ".json"])
  def archived?(id), do: File.regular?(manifest(id))

  @doc "Archives run `id` when an archive is set up: in the caller (a background task)."
  def maybe(id) do
    case config() do
      nil -> :off
      config -> archive(id, config, Application.get_env(:testor, :archive_backoff, [2_000, 30_000, 300_000]))
    end
  end

  defp archive(id, config, backoff) do
    with {:ok, _creds} <- Testor.Aws.credentials(config.region),
         {:ok, keys} <- upload_all(id, config) do
      File.mkdir_p!(Path.dirname(manifest(id)))

      Files.write_json(manifest(id), %{
        "archivedAt" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
        "bucket" => config.bucket,
        "keys" => keys
      })

      Logger.info("archive: #{id} archived to #{config.bucket} (#{length(keys)} objects)")
      :ok
    else
      {:error, why} ->
        case backoff do
          [wait | rest] ->
            Process.sleep(wait)
            archive(id, config, rest)

          [] ->
            Logger.error("archive: #{id} could not be archived: #{why}")
            {:error, why}
        end
    end
  end

  # The run's files, under <prefix><area>/<id>...
  defp files(id) do
    singles = [
      {"runs/#{id}.json", Config.run_file(id)},
      {"logs/#{id}.log", Config.log_file(id)},
      {"attestations/#{id}.dsse.json", Testor.Attestation.file(id)},
      {"attestations/#{id}.agent.dsse.json", Remote.agent_file(id)}
    ]

    trees =
      for area <- ["screenshots", "artifacts"],
          dir = Path.join(Config.data_dir(), area) |> Path.join(id),
          file <- Files.walk(dir),
          do: {"#{area}/#{id}/" <> String.replace(file.rel, "\\", "/"), file.full}

    Enum.filter(singles ++ trees, fn {_key, path} -> File.regular?(path) end)
  end

  defp upload_all(id, config) do
    Enum.reduce_while(files(id), {:ok, []}, fn {name, path}, {:ok, keys} ->
      key = config.prefix <> name

      case Testor.Blob.S3.put(config, name, {:file, path}) do
        :ok -> {:cont, {:ok, [key | keys]}}
        {:error, why} -> {:halt, {:error, "#{key}: #{why}"}}
      end
    end)
    |> then(fn
      {:ok, keys} -> {:ok, Enum.reverse(keys)}
      error -> error
    end)
  end
end
