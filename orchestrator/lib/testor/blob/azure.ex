defmodule Testor.Blob.Azure do
  @moduledoc """
  `Testor.Blob` over an Azure Blob Storage container, with `:httpc` and the Blob service's REST
  API: no SDK.

  Its config (`config/1`, config.json's `storage` with `"type": "azure"`):

      "account": "acmetestor", "container": "runs",
      "prefix": "testor",                                    (optional)
      "endpoint": "http://azurite:10000/devstoreaccount1",   (not Azure's: Azurite, a private
                                                             endpoint; else
                                                             https://<account>.blob.core.windows.net)
      "publicEndpoint": "https://files.example.com"         (the URL browsers reach it by)

  Credentials, as Azure's SDKs take them:

    * **Shared Key:** `AZURE_STORAGE_KEY` (the account's key). Requests are signed with it, and
      browser links are service SAS links (read only, minutes long).
    * **Microsoft Entra workload identity** (AKS): `AZURE_FEDERATED_TOKEN_FILE`,
      `AZURE_CLIENT_ID`, `AZURE_TENANT_ID` (and `AZURE_AUTHORITY_HOST`), traded for an access
      token of `https://storage.azure.com`. testor then serves every file itself: no SAS link.

  Each blob carries its SHA-256 as metadata (`x-ms-meta-sha256`, returned by `head`) and its
  MD5 as `Content-MD5`, which the service checks; a file larger than 64 MB goes in 16 MB blocks,
  each with its own MD5, then a block list. `list` follows `NextMarker`; `delete` removes blobs
  sixteen at a time and keeps those an immutability policy or legal hold protects.
  """
  @behaviour Testor.Blob
  require Logger

  @version "2021-12-02"
  @chunk 1_048_576

  @doc "The container's config from `raw`: `{:ok, cfg}` or `{:error, why}`."
  def config(raw) when is_map(raw) do
    cond do
      not (is_binary(raw["account"]) and Regex.match?(~r/^[a-z0-9]{3,24}$/, raw["account"])) ->
        {:error, "account is a storage account name"}

      not container?(raw["container"]) ->
        {:error, "container is a container name"}

      raw["endpoint"] != nil and not Testor.Auth.OIDC.url?(raw["endpoint"]) ->
        {:error, "endpoint is an http(s) URL"}

      raw["publicEndpoint"] != nil and not Testor.Auth.OIDC.url?(raw["publicEndpoint"]) ->
        {:error, "publicEndpoint is an http(s) URL"}

      true ->
        endpoint =
          String.trim_trailing(raw["endpoint"] || "https://#{raw["account"]}.blob.core.windows.net", "/")

        {:ok,
         %{
           account: raw["account"],
           bucket: raw["container"],
           prefix: (raw["prefix"] || "") |> String.trim("/") |> then(&if(&1 == "", do: "", else: &1 <> "/")),
           endpoint: endpoint,
           public_endpoint: String.trim_trailing(raw["publicEndpoint"] || endpoint, "/")
         }}
    end
  end

  def config(_raw), do: {:error, "it is an object"}

  # 3 to 63 lower-case letters, digits and single hyphens, as Azure names containers.
  defp container?(name),
    do: is_binary(name) and Regex.match?(~r/^[a-z0-9](?:[a-z0-9]|-(?=[a-z0-9])){2,62}$/, name)

  # --- put -----------------------------------------------------------------------------------

  @impl true
  def put(cfg, key, {:file, path}) do
    case File.stat(path) do
      {:ok, %{size: size}} ->
        if size > Application.get_env(:testor, :azure_blocks_over, 64 * @chunk),
          do: blocks(cfg, key, path, size),
          else: put_file(cfg, key, path, size)

      {:error, reason} ->
        {:error, reason}
    end
  end

  def put(cfg, key, data) when is_binary(data) do
    headers = [
      {"x-ms-blob-type", "BlockBlob"},
      {"content-md5", Base.encode64(:crypto.hash(:md5, data))},
      {"x-ms-meta-sha256", Base.encode64(:crypto.hash(:sha256, data))}
    ]

    request(cfg, :put, key, "", headers, {content_type(key), data}) |> created()
  end

  defp put_file(cfg, key, path, size) do
    {md5, sha256} = hashes(path, 0, size)

    headers = [
      {"x-ms-blob-type", "BlockBlob"},
      {"content-length", Integer.to_string(size)},
      {"content-md5", Base.encode64(md5)},
      {"x-ms-meta-sha256", Base.encode64(sha256)}
    ]

    with_device(path, fn device ->
      request(cfg, :put, key, "", headers, {content_type(key), stream(device, size)}) |> created()
    end)
  end

  # Blocks of 16 MB, each with its MD5, then the list that makes them the blob.
  defp blocks(cfg, key, path, size) do
    part = Application.get_env(:testor, :azure_block_size, 16 * @chunk)
    offsets = Enum.take_every(0..(size - 1)//1, part)

    ids =
      offsets
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, []}, fn {offset, n}, {:ok, acc} ->
        length = min(part, size - offset)
        id = Base.encode64(String.pad_leading(Integer.to_string(n), 8, "0"))
        {md5, _} = hashes(path, offset, length)
        query = "comp=block&blockid=" <> URI.encode_www_form(id)
        headers = [{"content-length", Integer.to_string(length)}, {"content-md5", Base.encode64(md5)}]

        answer =
          with_device(path, fn device ->
            {:ok, _} = :file.position(device, offset)
            request(cfg, :put, key, query, headers, {~c"application/octet-stream", stream(device, length)})
          end)

        case created(answer) do
          :ok -> {:cont, {:ok, [id | acc]}}
          error -> {:halt, error}
        end
      end)

    with {:ok, ids} <- ids do
      xml =
        ~s(<?xml version="1.0" encoding="utf-8"?><BlockList>) <>
          Enum.map_join(Enum.reverse(ids), "", &"<Latest>#{&1}</Latest>") <> "</BlockList>"

      {_, sha256} = hashes(path, 0, size)

      headers = [
        {"x-ms-meta-sha256", Base.encode64(sha256)},
        {"x-ms-blob-content-type", List.to_string(content_type(key))}
      ]

      request(cfg, :put, key, "comp=blocklist", headers, {~c"application/xml", xml}) |> created()
    end
  end

  defp created({:ok, status, _, _}) when status in 200..299, do: :ok
  defp created(other), do: failure(other)

  # --- get, head, list -------------------------------------------------------------------------

  @impl true
  def get(cfg, key, :binary) do
    case request(cfg, :get, key, "", [], nil) do
      {:ok, 200, _, body} -> {:ok, body}
      {:ok, 404, _, _} -> :not_found
      other -> failure(other)
    end
  end

  def get(cfg, key, {:file, to}) do
    File.mkdir_p!(Path.dirname(to))
    tmp = to <> ".tmp-" <> Integer.to_string(System.unique_integer([:positive]))

    result =
      case request(cfg, :get, key, "", [], nil, stream: String.to_charlist(tmp)) do
        {:ok, :saved_to_file} -> File.rename(tmp, to)
        {:ok, 404, _, _} -> :not_found
        other -> failure(other)
      end

    if result != :ok, do: File.rm(tmp)
    result
  end

  @impl true
  def head(cfg, key) do
    case request(cfg, :head, key, "", [], nil) do
      {:ok, 200, headers, _} ->
        size = headers |> header("content-length") |> Kernel.||("0") |> String.to_integer()
        {:ok, %{size: size, sha256: header(headers, "x-ms-meta-sha256")}}

      {:ok, 404, _, _} ->
        :not_found

      other ->
        failure(other)
    end
  end

  @impl true
  def list(cfg, prefix), do: list(cfg, prefix, nil, [])

  defp list(cfg, prefix, marker, acc) do
    query =
      "restype=container&comp=list&prefix=" <>
        URI.encode_www_form(cfg.prefix <> prefix) <>
        if(marker, do: "&marker=" <> URI.encode_www_form(marker), else: "")

    case request(cfg, :get, nil, query, [], nil) do
      {:ok, 200, _, body} ->
        objects =
          for [_, blob] <- Regex.scan(~r/<Blob>(.*?)<\/Blob>/s, body),
              [_, name] <- [Regex.run(~r/<Name>([^<]*)<\/Name>/, blob)],
              [_, size] <- [Regex.run(~r/<Content-Length>(\d+)<\/Content-Length>/, blob)],
              do: %{
                key: name |> xml_unescape() |> String.replace_prefix(cfg.prefix, ""),
                size: String.to_integer(size),
                modified: modified(blob)
              }

        case Regex.run(~r/<NextMarker>([^<]+)<\/NextMarker>/, body) do
          [_, next] -> list(cfg, prefix, xml_unescape(next), acc ++ objects)
          _ -> {:ok, Enum.sort_by(acc ++ objects, & &1.key)}
        end

      other ->
        failure(other)
    end
  end

  defp modified(blob) do
    with [_, at] <- Regex.run(~r/<Last-Modified>([^<]+)<\/Last-Modified>/, blob),
         {:ok, time} <- rfc1123(at) do
      DateTime.to_unix(time)
    else
      _ -> nil
    end
  end

  # --- delete, presign -------------------------------------------------------------------------

  @impl true
  def delete(cfg, keys) do
    results =
      keys
      |> Task.async_stream(&{&1, request(cfg, :delete, &1, "", [], nil)},
        max_concurrency: 16,
        timeout: 120_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    case Enum.find(results, fn {_, answer} -> not match?({:ok, s, _, _} when s in [202, 404, 409], answer) end) do
      nil ->
        # 409: an immutability policy or a legal hold keeps the blob, as the account decides.
        kept = for {key, {:ok, 409, _, _}} <- results, do: key

        if kept != [],
          do: Logger.warning("azure: #{length(kept)} blobs were kept (immutability policy or legal hold)")

        {:ok, keys -- kept, kept}

      {_, answer} ->
        failure(answer)
    end
  end

  @impl true
  def presign(cfg, key, seconds, opts) do
    case credential() do
      {:key, secret} ->
        expiry =
          DateTime.utc_now() |> DateTime.add(seconds) |> DateTime.truncate(:second) |> DateTime.to_iso8601()

        disposition = (opts[:filename] && ~s(attachment; filename="#{opts[:filename]}")) || ""
        type = opts[:type] || ""
        resource = "/blob/#{cfg.account}/#{cfg.bucket}/#{cfg.prefix}#{key}"

        to_sign =
          Enum.join(
            [
              "r",
              "",
              expiry,
              resource,
              "",
              "",
              "https,http",
              @version,
              "b",
              "",
              "",
              "",
              disposition,
              "",
              "",
              type
            ],
            "\n"
          )

        sig = Base.encode64(:crypto.mac(:hmac, :sha256, Base.decode64!(secret), to_sign))

        params =
          [{"sv", @version}, {"sr", "b"}, {"sp", "r"}, {"se", expiry}, {"spr", "https,http"}]
          |> then(&if(disposition != "", do: &1 ++ [{"rscd", disposition}], else: &1))
          |> then(&if(type != "", do: &1 ++ [{"rsct", type}], else: &1))
          |> Kernel.++([{"sig", sig}])

        {:ok, blob_url(cfg, cfg.public_endpoint, key) <> "?" <> URI.encode_query(params, :rfc3986)}

      _ ->
        :none
    end
  end

  @doc "Creates the container (Azurite, a first setup): `:ok` when it is there."
  def create_container(cfg) do
    case request(cfg, :put, nil, "restype=container", [], {~c"application/octet-stream", ""}) do
      {:ok, status, _, _} when status in [201, 409] -> :ok
      other -> failure(other)
    end
  end

  # --- requests --------------------------------------------------------------------------------

  defp blob_url(cfg, endpoint, key) do
    encode = fn segment -> URI.encode(segment, &URI.char_unreserved?/1) end
    path = if key, do: "/" <> Enum.map_join(String.split(cfg.prefix <> key, "/"), "/", encode), else: ""
    endpoint <> "/" <> cfg.bucket <> path
  end

  defp request(cfg, method, key, query, extra, body, opts \\ []) do
    with {:ok, auth} <- authorization(cfg, method, key, query, extra, body) do
      url = blob_url(cfg, cfg.endpoint, key) <> if(query == "", do: "", else: "?" <> query)
      # Content-Length too: Put Blob takes no chunked body.
      headers = for {k, v} <- auth ++ extra, do: {String.to_charlist(k), String.to_charlist(v)}

      req =
        case body do
          nil -> {String.to_charlist(url), headers}
          {type, data} -> {String.to_charlist(url), headers, type, data}
        end

      case :httpc.request(method, req, Testor.Webhooks.http_options(), [body_format: :binary] ++ opts) do
        {:ok, {{_, status, _}, answer_headers, answer}} -> {:ok, status, answer_headers, answer}
        {:ok, :saved_to_file} -> {:ok, :saved_to_file}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # The x-ms-date and x-ms-version every request carries, and its Authorization.
  defp authorization(cfg, method, key, query, extra, body) do
    date = Calendar.strftime(DateTime.utc_now(), "%a, %d %b %Y %H:%M:%S GMT")
    base = [{"x-ms-date", date}, {"x-ms-version", @version}]

    case credential() do
      {:key, secret} ->
        all = base ++ extra
        get = fn name -> Enum.find_value(all, "", fn {k, v} -> if String.downcase(k) == name, do: v end) end
        length = get.("content-length")

        length =
          if length == "" and match?({_, data} when is_binary(data) and data != "", body),
            do: Integer.to_string(byte_size(elem(body, 1))),
            else: length

        canonical_headers =
          all
          |> Enum.map(fn {k, v} -> {String.downcase(k), String.trim(v)} end)
          |> Enum.filter(fn {k, _} -> String.starts_with?(k, "x-ms-") end)
          |> Enum.sort()
          |> Enum.map_join("", fn {k, v} -> "#{k}:#{v}\n" end)

        to_sign =
          Enum.join(
            [
              method |> Atom.to_string() |> String.upcase(),
              "",
              "",
              if(length == "0", do: "", else: length),
              get.("content-md5"),
              if(body, do: List.to_string(elem(body, 0)), else: ""),
              "",
              "",
              "",
              "",
              "",
              ""
            ],
            "\n"
          ) <> "\n" <> canonical_headers <> canonical_resource(cfg, key, query)

        sig = Base.encode64(:crypto.mac(:hmac, :sha256, Base.decode64!(secret), to_sign))
        {:ok, base ++ [{"authorization", "SharedKey #{cfg.account}:#{sig}"}]}

      {:token, token} ->
        {:ok, base ++ [{"authorization", "Bearer " <> token}]}

      {:error, why} ->
        {:error, why}
    end
  end

  # "/<account><path>" and each query parameter, sorted, as "\nname:value".
  defp canonical_resource(cfg, key, query) do
    path = URI.parse(blob_url(cfg, cfg.endpoint, key)).path

    params =
      query
      |> URI.decode_query()
      |> Enum.sort()
      |> Enum.map_join("", fn {k, v} -> "\n#{String.downcase(k)}:#{v}" end)

    "/#{cfg.account}#{path}" <> params
  end

  @doc false
  # The account key, or an access token from the workload identity (cached until near its end).
  def credential do
    cond do
      (key = System.get_env("AZURE_STORAGE_KEY")) not in [nil, ""] ->
        {:key, key}

      System.get_env("AZURE_FEDERATED_TOKEN_FILE") not in [nil, ""] ->
        case :persistent_term.get({__MODULE__, :token}, nil) do
          {token, until} when is_binary(token) ->
            if System.os_time(:second) < until - 300, do: {:token, token}, else: entra_token()

          _ ->
            entra_token()
        end

      true ->
        {:error,
         "no Azure credentials: AZURE_STORAGE_KEY, or a workload identity (AZURE_FEDERATED_TOKEN_FILE)"}
    end
  end

  defp entra_token do
    host =
      String.trim_trailing(System.get_env("AZURE_AUTHORITY_HOST") || "https://login.microsoftonline.com", "/")

    url = "#{host}/#{System.get_env("AZURE_TENANT_ID")}/oauth2/v2.0/token"

    with {:ok, assertion} <- File.read(System.get_env("AZURE_FEDERATED_TOKEN_FILE")),
         form =
           URI.encode_query(%{
             "grant_type" => "client_credentials",
             "client_id" => System.get_env("AZURE_CLIENT_ID") || "",
             "scope" => "https://storage.azure.com/.default",
             "client_assertion_type" => "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
             "client_assertion" => String.trim(assertion)
           }),
         {:ok, {{_, 200, _}, _, answer}} <-
           :httpc.request(
             :post,
             {String.to_charlist(url), [], ~c"application/x-www-form-urlencoded", form},
             Testor.Webhooks.http_options(),
             body_format: :binary
           ),
         {:ok, %{"access_token" => token} = doc} <- JSON.decode(answer) do
      :persistent_term.put(
        {__MODULE__, :token},
        {token, System.os_time(:second) + (doc["expires_in"] || 3600)}
      )

      {:token, token}
    else
      _ -> {:error, "Microsoft Entra did not give an access token for the workload identity"}
    end
  end

  @doc false
  def reset, do: :persistent_term.erase({__MODULE__, :token})

  defp failure({:ok, status, _, body}), do: {:error, "answered #{status}#{azure_error(body)}"}
  defp failure({:error, reason}) when is_binary(reason), do: {:error, reason}
  defp failure({:error, reason}), do: {:error, "failed (#{inspect(reason)})"}

  defp azure_error(body) do
    case Regex.run(~r/<Code>([^<]+)<\/Code>/, body || "") do
      [_, code] -> " (#{code})"
      _ -> ""
    end
  end

  # --- helpers ---------------------------------------------------------------------------------

  defp content_type(key), do: Testor.Blob.S3.content_type(key)

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

  defp stream(device, length) do
    {fn
       {_device, 0} ->
         :eof

       {device, left} ->
         data = IO.binread(device, min(@chunk, left))
         {:ok, data, {device, left - byte_size(data)}}
     end, {device, length}}
  end

  # The MD5 and SHA-256 of `length` bytes of the file from `offset`.
  defp hashes(path, offset, length) do
    with_device(path, fn device ->
      {:ok, _} = :file.position(device, offset)
      hash_device(device, length, {:crypto.hash_init(:md5), :crypto.hash_init(:sha256)})
    end)
  end

  defp hash_device(_device, 0, {md5, sha}), do: {:crypto.hash_final(md5), :crypto.hash_final(sha)}

  defp hash_device(device, left, {md5, sha}) do
    data = IO.binread(device, min(@chunk, left))

    hash_device(
      device,
      left - byte_size(data),
      {:crypto.hash_update(md5, data), :crypto.hash_update(sha, data)}
    )
  end

  defp rfc1123(text) do
    months = ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

    with [_, d, mon, y, h, mi, s] <-
           Regex.run(~r/^\w{3}, (\d{2}) (\w{3}) (\d{4}) (\d{2}):(\d{2}):(\d{2}) GMT$/, text),
         m when is_integer(m) <- Enum.find_index(months, &(&1 == mon)),
         {:ok, date} <- Date.new(String.to_integer(y), m + 1, String.to_integer(d)),
         {:ok, time} <- Time.new(String.to_integer(h), String.to_integer(mi), String.to_integer(s)) do
      DateTime.new(date, time)
    else
      _ -> :error
    end
  end

  defp xml_unescape(text) do
    text
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&apos;", "'")
    |> String.replace("&amp;", "&")
  end
end
