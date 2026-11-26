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
  alias Testor.Archive.SigV4

  @chunk 1_048_576

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
      not (is_binary(raw["bucket"]) and Regex.match?(~r/^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$/, raw["bucket"])) ->
        invalid("bucket is a bucket name")

      not (is_binary(raw["region"]) and raw["region"] != "") ->
        invalid("region is required")

      raw["endpoint"] != nil and not Testor.Auth.OIDC.url?(raw["endpoint"]) ->
        invalid("endpoint is an http(s) URL")

      raw["encryption"] not in [nil, "AES256", "aws:kms"] ->
        invalid("encryption is AES256 or aws:kms")

      lock != nil and
          not (is_map(lock) and lock["mode"] in ["GOVERNANCE", "COMPLIANCE"] and is_integer(lock["days"]) and
                   lock["days"] > 0) ->
        invalid("objectLock is {mode: GOVERNANCE or COMPLIANCE, days}")

      true ->
        %{
          bucket: raw["bucket"],
          region: raw["region"],
          prefix: (raw["prefix"] || "") |> String.trim("/") |> then(&if(&1 == "", do: "", else: &1 <> "/")),
          endpoint: String.trim_trailing(raw["endpoint"] || "https://s3.#{raw["region"]}.amazonaws.com", "/"),
          path_style: raw["pathStyle"] == true,
          encryption: raw["encryption"],
          kms_key_id: raw["kmsKeyId"],
          lock: lock
        }
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
    with {:ok, creds} <- credentials(config.region),
         {:ok, keys} <- upload_all(id, config, creds) do
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

  defp upload_all(id, config, creds) do
    Enum.reduce_while(files(id), {:ok, []}, fn {name, path}, {:ok, keys} ->
      key = config.prefix <> name

      case put(config, creds, key, path) do
        :ok -> {:cont, {:ok, [key | keys]}}
        {:error, why} -> {:halt, {:error, "#{key}: #{why}"}}
      end
    end)
    |> then(fn
      {:ok, keys} -> {:ok, Enum.reverse(keys)}
      error -> error
    end)
  end

  @doc "Puts the file at `path` as `key`: streamed, with its SHA-256 for the server to check."
  def put(config, creds, key, path) do
    uri = object_uri(config, key)
    size = File.stat!(path).size

    checksum =
      path
      |> File.stream!(@chunk)
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final()

    extra =
      [{"content-length", Integer.to_string(size)}, {"x-amz-checksum-sha256", Base.encode64(checksum)}] ++
        encryption_headers(config) ++ lock_headers(config)

    signed =
      SigV4.authorize("PUT", uri, extra, "UNSIGNED-PAYLOAD", creds, config.region, "s3", DateTime.utc_now())

    headers = for {k, v} <- signed, k != "content-length", do: {String.to_charlist(k), String.to_charlist(v)}
    headers = [{~c"content-length", String.to_charlist(Integer.to_string(size))} | headers]

    {:ok, device} = File.open(path, [:read, :binary])

    body = fn device ->
      case IO.binread(device, @chunk) do
        :eof -> :eof
        data -> {:ok, data, device}
      end
    end

    request = {String.to_charlist(URI.to_string(uri)), headers, content_type(key), {body, device}}

    try do
      case :httpc.request(:put, request, Testor.Webhooks.http_options(), body_format: :binary) do
        {:ok, {{_, status, _}, _, _}} when status in 200..299 -> :ok
        {:ok, {{_, status, _}, _, answer}} -> {:error, "answered #{status}#{s3_error(answer)}"}
        {:error, reason} -> {:error, "failed (#{inspect(reason)})"}
      end
    after
      File.close(device)
    end
  end

  defp object_uri(config, key) do
    base = URI.parse(config.endpoint)
    path = "/" <> Enum.map_join(String.split(key, "/"), "/", &SigV4.encode/1)

    if config.path_style,
      do: %{base | path: "/" <> config.bucket <> path},
      else: %{base | host: config.bucket <> "." <> base.host, path: path}
  end

  defp encryption_headers(%{encryption: nil}), do: []
  defp encryption_headers(%{encryption: "AES256"}), do: [{"x-amz-server-side-encryption", "AES256"}]

  defp encryption_headers(%{encryption: "aws:kms", kms_key_id: key}) do
    [{"x-amz-server-side-encryption", "aws:kms"}] ++
      if(is_binary(key), do: [{"x-amz-server-side-encryption-aws-kms-key-id", key}], else: [])
  end

  defp lock_headers(%{lock: nil}), do: []

  defp lock_headers(%{lock: %{"mode" => mode, "days" => days}}) do
    until =
      DateTime.utc_now() |> DateTime.add(days * 86_400) |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    [{"x-amz-object-lock-mode", mode}, {"x-amz-object-lock-retain-until-date", until}]
  end

  defp content_type(key) do
    case Path.extname(key) do
      ".json" -> ~c"application/json"
      ".log" -> ~c"text/plain; charset=utf-8"
      ext -> ext |> String.trim_leading(".") |> MIME.type() |> String.to_charlist()
    end
  end

  defp s3_error(answer) do
    case Regex.run(~r/<Code>([^<]+)<\/Code>/, to_string(answer)) do
      [_, code] -> ": " <> code
      _ -> ""
    end
  end

  # --- credentials ---------------------------------------------------------------------------

  @doc "Credentials from the environment, or from STS for a web identity (cached until near expiry)."
  def credentials(region) do
    case {System.get_env("AWS_ACCESS_KEY_ID"), System.get_env("AWS_SECRET_ACCESS_KEY")} do
      {key, secret} when key not in [nil, ""] and secret not in [nil, ""] ->
        {:ok, %{key: key, secret: secret, token: blank_nil(System.get_env("AWS_SESSION_TOKEN"))}}

      _ ->
        web_identity(region)
    end
  end

  defp web_identity(region) do
    role = System.get_env("AWS_ROLE_ARN")
    file = System.get_env("AWS_WEB_IDENTITY_TOKEN_FILE")
    now = System.system_time(:second)

    case :persistent_term.get({__MODULE__, :sts}, nil) do
      {^role, expires, creds} when expires - 300 > now ->
        {:ok, creds}

      _ when role in [nil, ""] or file in [nil, ""] ->
        {:error,
         "no credentials (AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY, or AWS_ROLE_ARN and AWS_WEB_IDENTITY_TOKEN_FILE)"}

      _ ->
        assume(role, file, region)
    end
  end

  defp assume(role, file, region) do
    with {:ok, token} <- File.read(file) do
      query =
        URI.encode_query(%{
          "Action" => "AssumeRoleWithWebIdentity",
          "Version" => "2011-06-15",
          "RoleArn" => role,
          "RoleSessionName" => "testor",
          "WebIdentityToken" => String.trim(token)
        })

      endpoint = System.get_env("AWS_STS_ENDPOINT") || "https://sts.#{region}.amazonaws.com"
      url = String.to_charlist(String.trim_trailing(endpoint, "/") <> "/?" <> query)

      case :httpc.request(:get, {url, []}, Testor.Webhooks.http_options(), body_format: :binary) do
        {:ok, {{_, 200, _}, _, body}} -> sts_credentials(role, body)
        {:ok, {{_, status, _}, _, body}} -> {:error, "STS answered #{status}#{s3_error(body)}"}
        {:error, reason} -> {:error, "STS cannot be reached (#{inspect(reason)})"}
      end
    else
      {:error, reason} -> {:error, "cannot read #{file}: #{:file.format_error(reason)}"}
    end
  end

  defp sts_credentials(role, body) do
    field = fn name ->
      case Regex.run(~r/<#{name}>([^<]+)<\/#{name}>/, body) do
        [_, value] -> value
        _ -> nil
      end
    end

    with key when is_binary(key) <- field.("AccessKeyId"),
         secret when is_binary(secret) <- field.("SecretAccessKey"),
         {:ok, expires, _} <- DateTime.from_iso8601(field.("Expiration") || "") do
      creds = %{key: key, secret: secret, token: field.("SessionToken")}
      :persistent_term.put({__MODULE__, :sts}, {role, DateTime.to_unix(expires), creds})
      {:ok, creds}
    else
      _ -> {:error, "STS's answer holds no credentials"}
    end
  end

  @doc "Forgets credentials from STS."
  def reset, do: :persistent_term.erase({__MODULE__, :sts})

  defp blank_nil(""), do: nil
  defp blank_nil(value), do: value
end
