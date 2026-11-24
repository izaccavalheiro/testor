defmodule Testor.Auth.Password do
  @moduledoc """
  Password hashes: PBKDF2-HMAC-SHA256 from OTP's `:crypto`, so the release needs no native
  dependency on any platform. A hash is self-describing,

      $pbkdf2-sha256$<iterations>$<salt, base64>$<key, base64>

  so the iteration count can be raised later without invalidating older hashes. The default
  follows OWASP's recommendation for PBKDF2-SHA256 (600,000).
  """

  @iterations 600_000
  @max_iterations 10_000_000
  @prefix "$pbkdf2-sha256$"

  @doc "A new hash of `password` with a random 16-byte salt."
  def hash(password, iterations \\ @iterations) when is_binary(password) and iterations > 0 do
    salt = :crypto.strong_rand_bytes(16)
    key = :crypto.pbkdf2_hmac(:sha256, password, salt, iterations, 32)
    @prefix <> "#{iterations}$" <> b64(salt) <> "$" <> b64(key)
  end

  @doc "Whether `password` matches `hash`, in constant time. False for a malformed hash."
  def verify(password, @prefix <> rest) when is_binary(password) do
    with [count, salt, expected] <- String.split(rest, "$"),
         {iterations, ""} when iterations in 1..@max_iterations <- Integer.parse(count),
         {:ok, salt} <- Base.decode64(salt, padding: false),
         {:ok, expected} when byte_size(expected) >= 16 <- Base.decode64(expected, padding: false) do
      :sha256
      |> :crypto.pbkdf2_hmac(password, salt, iterations, byte_size(expected))
      |> Plug.Crypto.secure_compare(expected)
    else
      _ -> false
    end
  end

  def verify(_password, _hash), do: false

  @doc "Spends the time a verification takes, so an unknown user answers as slowly as a known one."
  def dummy_verify do
    :crypto.pbkdf2_hmac(:sha256, "testor", "testor-dummy-salt", @iterations, 32)
    false
  end

  @doc "Whether `hash` has the format `verify/2` reads."
  def valid?(hash),
    do: is_binary(hash) and String.starts_with?(hash, @prefix) and length(String.split(hash, "$")) == 5

  defp b64(bytes), do: Base.encode64(bytes, padding: false)
end
