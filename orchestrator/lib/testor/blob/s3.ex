defmodule Testor.Blob.S3 do
  @moduledoc """
  `Testor.Blob` over an S3-compatible bucket, with `:httpc` and SigV4 (`Testor.Aws`): no SDK.

  Its config (`config/1`, from config.json's `storage` or `archive`):

      "bucket": "acme-testor", "region": "eu-west-1",
      "prefix": "testor",                                   (optional)
      "endpoint": "https://minio.example.com:9000",         (not AWS: the server's URL)
      "publicEndpoint": "https://files.example.com",        (the URL browsers reach it by,
                                                             for presigned links; else endpoint)
      "pathStyle": true,                                    (MinIO and most compatibles)
      "encryption": "aws:kms", "kmsKeyId": "arn:aws:kms:..." (or "AES256": SSE-S3)

  Each object carries its SHA-256 (`x-amz-checksum-sha256`), which the server checks; a file
  larger than 64 MB goes in 16 MB parts (multipart upload), each with its own checksum, and the
  upload is aborted when a part fails. `list` follows `ListObjectsV2`'s continuation tokens;
  `delete` sends `DeleteObjects` in batches of 1,000 (with the body's checksum, which S3
  requires) and reports the keys it refused, such as objects under Object Lock or legal hold.
  """
  @behaviour Testor.Blob
  require Logger
  alias Testor.Aws
  alias Testor.Aws.SigV4

  @chunk 1_048_576

  @doc "The bucket's config from `raw` (config.json's object): `{:ok, cfg}` or `{:error, why}`."
  def config(raw) when is_map(raw) do
    cond do
      not (is_binary(raw["bucket"]) and Regex.match?(~r/^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$/, raw["bucket"])) ->
        {:error, "bucket is a bucket name"}

      not (is_binary(raw["region"]) and raw["region"] != "") ->
        {:error, "region is required"}

      raw["endpoint"] != nil and not Testor.Auth.OIDC.url?(raw["endpoint"]) ->
        {:error, "endpoint is an http(s) URL"}

      raw["publicEndpoint"] != nil and not Testor.Auth.OIDC.url?(raw["publicEndpoint"]) ->
        {:error, "publicEndpoint is an http(s) URL"}

      raw["encryption"] not in [nil, "AES256", "aws:kms"] ->
        {:error, "encryption is AES256 or aws:kms"}

      true ->
        endpoint = String.trim_trailing(raw["endpoint"] || "https://s3.#{raw["region"]}.amazonaws.com", "/")

        {:ok,
         %{
           bucket: raw["bucket"],
           region: raw["region"],
           prefix: (raw["prefix"] || "") |> String.trim("/") |> then(&if(&1 == "", do: "", else: &1 <> "/")),
           endpoint: endpoint,
           public_endpoint: String.trim_trailing(raw["publicEndpoint"] || endpoint, "/"),
           path_style: raw["pathStyle"] == true,
           encryption: raw["encryption"],
           kms_key_id: raw["kmsKeyId"],
           lock: nil
         }}
    end
  end

  def config(_raw), do: {:error, "it is an object"}

  # --- put -----------------------------------------------------------------------------------

  @impl true
  def put(cfg, key, {:file, path}) do
    case File.stat(path) do
      {:ok, %{size: size}} ->
        if size > Application.get_env(:testor, :s3_multipart_over, 64 * @chunk),
          do: multipart(cfg, key, path, size),
          else: put_file(cfg, key, path, size)

      {:error, reason} ->
        {:error, reason}
    end
  end

  def put(cfg, key, data) when is_binary(data) do
    checksum = :crypto.hash(:sha256, data)
    headers = [{"x-amz-checksum-sha256", Base.encode64(checksum)}] ++ object_headers(cfg)

    case request(cfg, :put, key, "", headers, {content_type(key), data}, SigV4.hex(checksum)) do
      {:ok, status, _, _} when status in 200..299 -> :ok
      other -> failure(other)
    end
  end

  defp put_file(cfg, key, path, size) do
    checksum = file_sha256(path, 0, size)

    headers =
      [{"content-length", Integer.to_string(size)}, {"x-amz-checksum-sha256", Base.encode64(checksum)}] ++
        object_headers(cfg)

    with_device(path, fn device ->
      case request(cfg, :put, key, "", headers, {content_type(key), stream(device, size)}, "UNSIGNED-PAYLOAD") do
        {:ok, status, _, _} when status in 200..299 -> :ok
        other -> failure(other)
      end
    end)
  end

  defp multipart(cfg, key, path, size) do
    part = Application.get_env(:testor, :s3_part_size, 16 * @chunk)
    create = [{"x-amz-checksum-algorithm", "SHA256"}] ++ object_headers(cfg)

    started = request(cfg, :post, key, "uploads=", create, {content_type(key), ""}, empty())

    with {:ok, 200, _, body} <- started,
         [_, upload] <- Regex.run(~r/<UploadId>([^<]+)<\/UploadId>/, body) do
      query = "uploadId=" <> SigV4.encode(xml_unescape(upload))
      offsets = Enum.take_every(0..(size - 1)//1, part)

      parts =
        offsets
        |> Enum.with_index(1)
        |> Enum.reduce_while({:ok, []}, fn {offset, n}, {:ok, acc} ->
          case upload_part(cfg, key, query, path, n, offset, min(part, size - offset)) do
            {:ok, etag, sum} -> {:cont, {:ok, [{n, etag, sum} | acc]}}
            error -> {:halt, error}
          end
        end)

      case parts do
        {:ok, done} ->
          complete(cfg, key, query, Enum.reverse(done))

        error ->
          request(cfg, :delete, key, query, [], nil, empty())
          error
      end
    else
      other -> failure(other)
    end
  end

  defp upload_part(cfg, key, query, path, n, offset, length) do
    sum = Base.encode64(file_sha256(path, offset, length))
    headers = [{"content-length", Integer.to_string(length)}, {"x-amz-checksum-sha256", sum}]
    q = "partNumber=#{n}&" <> query

    with_device(path, fn device ->
      {:ok, _} = :file.position(device, offset)

      case request(
             cfg,
             :put,
             key,
             q,
             headers,
             {~c"application/octet-stream", stream(device, length)},
             "UNSIGNED-PAYLOAD"
           ) do
        {:ok, 200, answer_headers, _} -> {:ok, header(answer_headers, "etag"), sum}
        other -> failure(other)
      end
    end)
  end

  defp complete(cfg, key, query, parts) do
    xml =
      "<CompleteMultipartUpload>" <>
        Enum.map_join(parts, "", fn {n, etag, sum} ->
          "<Part><PartNumber>#{n}</PartNumber><ETag>#{xml_escape(etag)}</ETag><ChecksumSHA256>#{sum}</ChecksumSHA256></Part>"
        end) <> "</CompleteMultipartUpload>"

    hash = :crypto.hash(:sha256, xml)

    case request(cfg, :post, key, query, [], {~c"application/xml", xml}, SigV4.hex(hash)) do
      # S3 can answer 200 with an error in the body once it has started.
      {:ok, 200, _, body} ->
        if body =~ "<Error>", do: {:error, "answered 200#{Aws.s3_error(body)}"}, else: :ok

      other ->
        failure(other)
    end
  end

  # --- get, head, list, delete ---------------------------------------------------------------

  @impl true
  def get(cfg, key, :binary) do
    case request(cfg, :get, key, "", [], nil, empty()) do
      {:ok, 200, _, body} -> {:ok, body}
      {:ok, 404, _, _} -> :not_found
      other -> failure(other)
    end
  end

  def get(cfg, key, {:file, to}) do
    File.mkdir_p!(Path.dirname(to))
    tmp = to <> ".tmp-" <> Integer.to_string(System.unique_integer([:positive]))

    result =
      case request(cfg, :get, key, "", [], nil, empty(), stream: String.to_charlist(tmp)) do
        {:ok, :saved_to_file} -> File.rename(tmp, to)
        {:ok, 404, _, _} -> :not_found
        other -> failure(other)
      end

    if result != :ok, do: File.rm(tmp)
    result
  end

  @impl true
  def head(cfg, key) do
    case request(cfg, :head, key, "", [{"x-amz-checksum-mode", "ENABLED"}], nil, empty()) do
      {:ok, 200, headers, _} ->
        # A whole object's SHA-256 (base64); a multipart one's is of its parts' ("...-3"): none.
        sum = header(headers, "x-amz-checksum-sha256")
        size = String.to_integer(header(headers, "content-length") || "0")
        {:ok, %{size: size, sha256: if(sum && not String.contains?(sum, "-"), do: sum)}}

      {:ok, 404, _, _} ->
        :not_found

      other ->
        failure(other)
    end
  end

  @impl true
  def list(cfg, prefix), do: list(cfg, prefix, nil, [])

  defp list(cfg, prefix, token, acc) do
    query =
      [{"list-type", "2"}, {"prefix", cfg.prefix <> prefix}] ++
        if(token, do: [{"continuation-token", token}], else: [])

    query = Enum.map_join(query, "&", fn {k, v} -> k <> "=" <> SigV4.encode(v) end)

    case request(cfg, :get, nil, query, [], nil, empty()) do
      {:ok, 200, _, body} ->
        objects =
          for [_, entry] <- Regex.scan(~r/<Contents>(.*?)<\/Contents>/s, body),
              [_, key] <- [Regex.run(~r/<Key>([^<]*)<\/Key>/, entry)],
              [_, size] <- [Regex.run(~r/<Size>(\d+)<\/Size>/, entry)],
              do: %{
                key: key |> xml_unescape() |> String.replace_prefix(cfg.prefix, ""),
                size: String.to_integer(size),
                modified: modified(entry)
              }

        acc = acc ++ objects

        case Regex.run(~r/<NextContinuationToken>([^<]+)<\/NextContinuationToken>/, body) do
          [_, next] ->
            if body =~ "<IsTruncated>true", do: list(cfg, prefix, xml_unescape(next), acc), else: done(acc)

          nil ->
            done(acc)
        end

      other ->
        failure(other)
    end
  end

  defp done(objects), do: {:ok, Enum.sort_by(objects, & &1.key)}

  # When the object was written, in Unix seconds (nil when the listing does not say).
  defp modified(entry) do
    with [_, at] <- Regex.run(~r/<LastModified>([^<]+)<\/LastModified>/, entry),
         {:ok, time, _} <- DateTime.from_iso8601(at) do
      DateTime.to_unix(time)
    else
      _ -> nil
    end
  end

  @impl true
  def delete(cfg, keys) do
    keys
    |> Enum.chunk_every(1000)
    |> Enum.reduce_while({:ok, [], []}, fn batch, {:ok, deleted, kept} ->
      case delete_batch(cfg, batch) do
        {:ok, refused} -> {:cont, {:ok, deleted ++ (batch -- refused), kept ++ refused}}
        error -> {:halt, error}
      end
    end)
  end

  defp delete_batch(cfg, keys) do
    xml =
      "<Delete><Quiet>true</Quiet>" <>
        Enum.map_join(keys, "", &"<Object><Key>#{xml_escape(cfg.prefix <> &1)}</Key></Object>") <> "</Delete>"

    hash = :crypto.hash(:sha256, xml)
    headers = [{"x-amz-checksum-sha256", Base.encode64(hash)}]

    case request(cfg, :post, nil, "delete=", headers, {~c"application/xml", xml}, SigV4.hex(hash)) do
      {:ok, 200, _, body} ->
        refused =
          for [_, error] <- Regex.scan(~r/<Error>(.*?)<\/Error>/s, body),
              [_, key] <- [Regex.run(~r/<Key>([^<]*)<\/Key>/, error)],
              do: key |> xml_unescape() |> String.replace_prefix(cfg.prefix, "")

        if refused != [],
          do: Logger.warning("s3: #{length(refused)} objects were kept (Object Lock or legal hold)")

        {:ok, refused}

      other ->
        failure(other)
    end
  end

  # --- presigned links -----------------------------------------------------------------------

  @impl true
  def presign(cfg, key, seconds, opts) do
    case Aws.credentials(cfg.region) do
      {:ok, creds} ->
        disposition = opts[:filename] && ~s(attachment; filename="#{opts[:filename]}")

        params =
          [
            disposition && {"response-content-disposition", disposition},
            opts[:type] && {"response-content-type", opts[:type]}
          ]
          |> Enum.reject(&is_nil/1)
          |> Enum.map_join("&", fn {k, v} -> k <> "=" <> SigV4.encode(v) end)

        uri = %{object_uri(cfg, cfg.public_endpoint, key) | query: if(params == "", do: nil, else: params)}
        {:ok, SigV4.presign("GET", uri, creds, cfg.region, "s3", DateTime.utc_now(), seconds)}

      {:error, _} ->
        :none
    end
  end

  # --- requests ------------------------------------------------------------------------------

  defp request(cfg, method, key, query, extra, body, payload_hash, opts \\ []) do
    uri = object_uri(cfg, cfg.endpoint, key)
    uri = %{uri | query: if(query == "", do: nil, else: query)}

    with {:ok, creds} <- Aws.credentials(cfg.region) do
      verb = method |> Atom.to_string() |> String.upcase()
      signed = SigV4.authorize(verb, uri, extra, payload_hash, creds, cfg.region, "s3", DateTime.utc_now())
      headers = for {k, v} <- signed, k != "content-type", do: {String.to_charlist(k), String.to_charlist(v)}
      url = String.to_charlist(URI.to_string(uri))

      req =
        case body do
          nil -> {url, headers}
          {type, data} -> {url, headers, type, data}
        end

      case :httpc.request(method, req, Testor.Webhooks.http_options(), [body_format: :binary] ++ opts) do
        {:ok, {{_, status, _}, answer_headers, answer}} -> {:ok, status, answer_headers, answer}
        {:ok, :saved_to_file} -> {:ok, :saved_to_file}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp failure({:ok, status, _, body}), do: {:error, "answered #{status}#{Aws.s3_error(body)}"}
  defp failure({:error, reason}) when is_binary(reason), do: {:error, reason}
  defp failure({:error, reason}), do: {:error, "failed (#{inspect(reason)})"}
  defp failure(_other), do: {:error, "unexpected answer"}

  @doc false
  def object_uri(cfg, endpoint, key) do
    base = URI.parse(endpoint)

    path =
      if key, do: "/" <> Enum.map_join(String.split(cfg.prefix <> key, "/"), "/", &SigV4.encode/1), else: "/"

    if cfg.path_style,
      do: %{base | path: "/" <> cfg.bucket <> if(key, do: path, else: "")},
      else: %{base | host: cfg.bucket <> "." <> base.host, path: path}
  end

  @doc false
  def object_headers(cfg), do: encryption_headers(cfg) ++ lock_headers(cfg)

  defp encryption_headers(%{encryption: nil}), do: []
  defp encryption_headers(%{encryption: "AES256"}), do: [{"x-amz-server-side-encryption", "AES256"}]

  defp encryption_headers(%{encryption: "aws:kms", kms_key_id: key}) do
    [{"x-amz-server-side-encryption", "aws:kms"}] ++
      if(is_binary(key), do: [{"x-amz-server-side-encryption-aws-kms-key-id", key}], else: [])
  end

  defp lock_headers(%{lock: %{"mode" => mode, "days" => days}}) do
    until =
      DateTime.utc_now() |> DateTime.add(days * 86_400) |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    [{"x-amz-object-lock-mode", mode}, {"x-amz-object-lock-retain-until-date", until}]
  end

  defp lock_headers(_cfg), do: []

  @doc false
  def content_type(key) do
    case Path.extname(key) do
      ".json" -> ~c"application/json"
      ".jsonl" -> ~c"application/x-ndjson"
      ".log" -> ~c"text/plain; charset=utf-8"
      ext -> ext |> String.trim_leading(".") |> MIME.type() |> String.to_charlist()
    end
  end

  defp empty, do: SigV4.hex(:crypto.hash(:sha256, ""))

  defp header(headers, name) do
    Enum.find_value(headers, fn {k, v} -> if String.downcase(to_string(k)) == name, do: to_string(v) end)
  end

  defp with_device(path, fun) do
    {:ok, device} = File.open(path, [:read, :binary])

    try do
      fun.(device)
    after
      File.close(device)
    end
  end

  # The request body as :httpc streams it: `length` bytes of `device` from where it is.
  defp stream(device, length) do
    {fn
       {_device, 0} ->
         :eof

       {device, left} ->
         data = IO.binread(device, min(@chunk, left))
         {:ok, data, {device, left - byte_size(data)}}
     end, {device, length}}
  end

  defp file_sha256(path, offset, length) do
    with_device(path, fn device ->
      {:ok, _} = :file.position(device, offset)
      hash_device(device, length, :crypto.hash_init(:sha256))
    end)
  end

  defp hash_device(_device, 0, state), do: :crypto.hash_final(state)

  defp hash_device(device, left, state) do
    data = IO.binread(device, min(@chunk, left))
    hash_device(device, left - byte_size(data), :crypto.hash_update(state, data))
  end

  defp xml_escape(text),
    do:
      text
      |> String.replace("&", "&amp;")
      |> String.replace("<", "&lt;")
      |> String.replace(">", "&gt;")
      |> String.replace("\"", "&quot;")

  defp xml_unescape(text) do
    text
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&apos;", "'")
    |> String.replace("&amp;", "&")
  end
end
