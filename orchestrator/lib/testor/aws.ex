defmodule Testor.Aws do
  @moduledoc """
  AWS credentials, as AWS SDKs take them, for every AWS API testor calls (S3: the archive and
  `Testor.Blob.S3`; SQS: `Testor.Queue.SQS`). Requests are signed by `Testor.Aws.SigV4`.

    * `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` and `AWS_SESSION_TOKEN`; or
    * `AWS_ROLE_ARN` with `AWS_WEB_IDENTITY_TOKEN_FILE` (IAM roles for service accounts, or
      testor's own job tokens), traded with STS (`AWS_STS_ENDPOINT` elsewhere than AWS) for
      short-lived ones, cached until five minutes before they expire.
  """

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

  @doc "The error code in an S3 or STS error answer, as `\": Code\"`, or \"\"."
  def s3_error(answer) do
    case Regex.run(~r/<Code>([^<]+)<\/Code>/, to_string(answer)) do
      [_, code] -> ": " <> code
      _ -> ""
    end
  end
end
