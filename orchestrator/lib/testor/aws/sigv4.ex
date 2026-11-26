defmodule Testor.Aws.SigV4 do
  @moduledoc """
  AWS Signature Version 4 (header-signed requests), as S3 and its compatibles (MinIO, R2, GCS's
  interoperability API) take them: `authorize/8` gives the headers that sign a request.
  Without a dependency: `:crypto` only.
  """

  @doc """
  The headers to add to a request: `x-amz-date`, `x-amz-content-sha256`, the session token when
  there is one, and `authorization`. `headers` are the request's own (lower-case names) to sign
  too; `host` is signed always. `payload_hash` is the payload's hex SHA-256, or
  `"UNSIGNED-PAYLOAD"`. `content_hash: false` leaves `x-amz-content-sha256` out (services
  other than S3, and AWS's test suite).
  """
  def authorize(method, %URI{} = uri, headers, payload_hash, creds, region, service, now, opts \\ []) do
    amz_date = Calendar.strftime(now, "%Y%m%dT%H%M%SZ")
    date = String.slice(amz_date, 0, 8)
    host = if uri.port in [nil, 80, 443], do: uri.host, else: "#{uri.host}:#{uri.port}"

    signed =
      [{"host", host}, {"x-amz-date", amz_date}] ++
        if(Keyword.get(opts, :content_hash, true), do: [{"x-amz-content-sha256", payload_hash}], else: []) ++
        if(creds[:token], do: [{"x-amz-security-token", creds.token}], else: []) ++ headers

    signed =
      signed |> Enum.map(fn {k, v} -> {String.downcase(k), String.trim(to_string(v))} end) |> Enum.sort()

    names = Enum.map_join(signed, ";", &elem(&1, 0))

    canonical =
      Enum.join(
        [
          method,
          canonical_path(uri.path),
          canonical_query(uri.query),
          Enum.map_join(signed, "", fn {k, v} -> "#{k}:#{v}\n" end),
          names,
          payload_hash
        ],
        "\n"
      )

    scope = "#{date}/#{region}/#{service}/aws4_request"
    to_sign = Enum.join(["AWS4-HMAC-SHA256", amz_date, scope, hex(:crypto.hash(:sha256, canonical))], "\n")

    key =
      Enum.reduce([date, region, service, "aws4_request"], "AWS4" <> creds.secret, &hmac(&2, &1))

    signature = key |> hmac(to_sign) |> hex()

    authorization =
      "AWS4-HMAC-SHA256 Credential=#{creds.key}/#{scope}, SignedHeaders=#{names}, Signature=#{signature}"

    Enum.reject(signed, fn {k, _} -> k == "host" end) ++ [{"authorization", authorization}]
  end

  @doc """
  A presigned URL (query-string authentication): `uri` with the `X-Amz-*` parameters that let
  whoever holds it make one `method` request until `expires` seconds after `now`. Only `host`
  is signed, and the payload is not; `uri`'s own query (`response-content-disposition`...) is
  signed with them.
  """
  def presign(method, %URI{} = uri, creds, region, service, now, expires) do
    amz_date = Calendar.strftime(now, "%Y%m%dT%H%M%SZ")
    date = String.slice(amz_date, 0, 8)
    host = if uri.port in [nil, 80, 443], do: uri.host, else: "#{uri.host}:#{uri.port}"
    scope = "#{date}/#{region}/#{service}/aws4_request"

    params =
      URI.query_decoder(uri.query || "")
      |> Enum.to_list()
      |> Kernel.++([
        {"X-Amz-Algorithm", "AWS4-HMAC-SHA256"},
        {"X-Amz-Credential", "#{creds.key}/#{scope}"},
        {"X-Amz-Date", amz_date},
        {"X-Amz-Expires", Integer.to_string(expires)},
        {"X-Amz-SignedHeaders", "host"}
      ])
      |> Kernel.++(if creds[:token], do: [{"X-Amz-Security-Token", creds.token}], else: [])

    query =
      params
      |> Enum.map(fn {k, v} -> {encode(k), encode(v)} end)
      |> Enum.sort()
      |> Enum.map_join("&", fn {k, v} -> "#{k}=#{v}" end)

    canonical =
      Enum.join([method, canonical_path(uri.path), query, "host:#{host}\n", "host", "UNSIGNED-PAYLOAD"], "\n")

    to_sign = Enum.join(["AWS4-HMAC-SHA256", amz_date, scope, hex(:crypto.hash(:sha256, canonical))], "\n")
    key = Enum.reduce([date, region, service, "aws4_request"], "AWS4" <> creds.secret, &hmac(&2, &1))
    signature = key |> hmac(to_sign) |> hex()
    URI.to_string(%{uri | query: query <> "&X-Amz-Signature=" <> signature})
  end

  # Each segment URI-encoded once (S3 does not double-encode), slashes kept.
  defp canonical_path(nil), do: "/"
  defp canonical_path(""), do: "/"
  defp canonical_path(path), do: path |> String.split("/") |> Enum.map_join("/", &encode(URI.decode(&1)))

  defp canonical_query(nil), do: ""

  defp canonical_query(query) do
    query
    |> URI.query_decoder()
    |> Enum.map(fn {k, v} -> {encode(k), encode(v)} end)
    |> Enum.sort()
    |> Enum.map_join("&", fn {k, v} -> "#{k}=#{v}" end)
  end

  @doc "RFC 3986 encoding as SigV4 wants it: unreserved characters kept, the rest %XX."
  def encode(text), do: URI.encode(text, &URI.char_unreserved?(&1))

  defp hmac(key, data), do: :crypto.mac(:hmac, :sha256, key, data)
  def hex(bytes), do: Base.encode16(bytes, case: :lower)
end
