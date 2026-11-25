defmodule Testor.Auth.JWT do
  @moduledoc """
  JSON Web Tokens (RFC 7519), signed with Ed25519 (`EdDSA`, RFC 8037; the key named by `kid`,
  see `Testor.Auth.TokenKeys`) or HMAC-SHA256 (`HS256`, the shared secret). Each algorithm is
  checked with its own kind of key only, and a token naming any other (`none`, `RS256`, ...)
  is refused before its signature is looked at, which closes the algorithm-confusion attacks.
  An HMAC is compared in constant time.

  `verify/3` checks the registered claims testor issues: `iss` and `aud` are `"testor"`, `exp`
  is required, `nbf` and `iat` must not be in the future; 30 seconds of clock skew are allowed.
  """

  @issuer "testor"
  @leeway 30
  @hs256 Base.url_encode64(~s({"alg":"HS256","typ":"JWT"}), padding: false)

  def issuer, do: @issuer

  @doc """
  A compact, signed token holding `claims`: `HS256` with a binary `key`, `EdDSA` with a
  signing key `%{kid, seed}`.
  """
  def sign(claims, key) when is_map(claims) and is_binary(key) do
    input = @hs256 <> "." <> b64(JSON.encode!(claims))
    input <> "." <> b64(mac(key, input))
  end

  def sign(claims, %{kid: kid, seed: seed}) when is_map(claims) do
    header = JSON.encode!(%{"alg" => "EdDSA", "typ" => "JWT", "kid" => kid})
    input = b64(header) <> "." <> b64(JSON.encode!(claims))
    input <> "." <> b64(:crypto.sign(:eddsa, :none, input, [seed, :ed25519]))
  end

  @doc """
  The claims of a valid token, or why it is not valid. `keys` is `%{hs256: secret | nil,
  eddsa: %{kid => %{public, retired}}}`, or a binary secret alone (`HS256` only). A token of a
  retired key must have been issued before it was retired.
  """
  def verify(token, keys, now \\ System.system_time(:second))

  def verify(token, key, now) when is_binary(key), do: verify(token, %{hs256: key, eddsa: %{}}, now)

  def verify(token, %{} = keys, now) when is_binary(token) do
    with [header, payload, signature] <- String.split(token, "."),
         {:ok, %{} = head} <- decode_json(header),
         {:ok, check} <- checker(head, keys),
         {:ok, signature} <- Base.url_decode64(signature, padding: false),
         true <- check.(header <> "." <> payload, signature) || {:error, :signature},
         {:ok, %{} = claims} <- decode_json(payload),
         :ok <- check_claims(claims, now),
         :ok <- check_retired(head, keys, claims) do
      {:ok, claims}
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :malformed}
    end
  end

  def verify(_token, _keys, _now), do: {:error, :malformed}

  # A critical extension testor does not know must be refused (RFC 7515, 4.1.11).
  defp checker(%{"crit" => _}, _keys), do: {:error, :malformed}

  defp checker(%{"alg" => "HS256"}, %{hs256: key}) when is_binary(key),
    do: {:ok, &Plug.Crypto.secure_compare(mac(key, &1), &2)}

  defp checker(%{"alg" => "EdDSA", "kid" => kid}, %{eddsa: %{} = ring}) when is_binary(kid) do
    case ring do
      %{^kid => %{public: public}} -> {:ok, &:crypto.verify(:eddsa, :none, &1, &2, [public, :ed25519])}
      _ -> {:error, :unknown_key}
    end
  end

  defp checker(_head, _keys), do: {:error, :algorithm}

  # check_claims/2 made sure iat is an integer.
  defp check_retired(%{"alg" => "EdDSA", "kid" => kid}, %{eddsa: ring}, %{"iat" => issued}) do
    case ring[kid] do
      %{retired: retired} when is_integer(retired) and issued > retired -> {:error, :retired_key}
      _ -> :ok
    end
  end

  defp check_retired(_head, _keys, _claims), do: :ok

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
