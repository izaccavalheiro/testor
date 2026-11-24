defmodule Testor.Auth.JWT do
  @moduledoc """
  JSON Web Tokens (RFC 7519) signed with HMAC-SHA256 (`HS256`), the only algorithm accepted:
  a token naming any other (`none`, `RS256`, ...) is refused before its signature is looked at,
  which closes the algorithm-confusion attacks. The signature is compared in constant time.

  `verify/3` checks the registered claims testor issues: `iss` and `aud` are `"testor"`, `exp`
  is required, `nbf` and `iat` must not be in the future; 30 seconds of clock skew are allowed.
  """

  @issuer "testor"
  @leeway 30
  @header Base.url_encode64(~s({"alg":"HS256","typ":"JWT"}), padding: false)

  def issuer, do: @issuer

  @doc "A compact, signed token holding `claims`."
  def sign(claims, key) when is_map(claims) and is_binary(key) do
    input = @header <> "." <> b64(JSON.encode!(claims))
    input <> "." <> b64(mac(key, input))
  end

  @doc "The claims of a valid token, or why it is not valid."
  def verify(token, key, now \\ System.system_time(:second))

  def verify(token, key, now) when is_binary(token) and is_binary(key) do
    with [header, payload, signature] <- String.split(token, "."),
         {:ok, %{} = head} <- decode_json(header),
         :ok <- check_header(head),
         {:ok, signature} <- Base.url_decode64(signature, padding: false),
         true <-
           Plug.Crypto.secure_compare(mac(key, header <> "." <> payload), signature) || {:error, :signature},
         {:ok, %{} = claims} <- decode_json(payload),
         :ok <- check_claims(claims, now) do
      {:ok, claims}
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :malformed}
    end
  end

  def verify(_token, _key, _now), do: {:error, :malformed}

  defp check_header(%{"alg" => "HS256"} = head) do
    # A critical extension testor does not know must be refused (RFC 7515, 4.1.11).
    if Map.has_key?(head, "crit"), do: {:error, :malformed}, else: :ok
  end

  defp check_header(_), do: {:error, :algorithm}

  defp check_claims(claims, now) do
    cond do
      claims["iss"] != @issuer -> {:error, :issuer}
      not audience?(claims["aud"]) -> {:error, :audience}
      not is_integer(claims["exp"]) -> {:error, :malformed}
      now >= claims["exp"] + @leeway -> {:error, :expired}
      is_integer(claims["nbf"]) and claims["nbf"] > now + @leeway -> {:error, :not_yet_valid}
      not is_integer(claims["iat"]) or claims["iat"] > now + @leeway -> {:error, :malformed}
      not is_binary(claims["sub"]) -> {:error, :malformed}
      true -> :ok
    end
  end

  defp audience?(@issuer), do: true
  defp audience?(list) when is_list(list), do: @issuer in list
  defp audience?(_), do: false

  defp decode_json(part) do
    with {:ok, json} <- Base.url_decode64(part, padding: false) do
      case JSON.decode(json) do
        {:ok, value} -> {:ok, value}
        _ -> {:error, :malformed}
      end
    else
      _ -> {:error, :malformed}
    end
  end

  defp mac(key, data), do: :crypto.mac(:hmac, :sha256, key, data)
  defp b64(bytes), do: Base.url_encode64(bytes, padding: false)
end
