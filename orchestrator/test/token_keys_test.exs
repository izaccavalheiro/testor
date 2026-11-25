defmodule Testor.TokenKeysTest do
  @moduledoc "Tokens signed with Ed25519, their keys published as a JWKS, rolled and reset."
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  import ExUnit.CaptureLog
  import Plug.Test
  import Plug.Conn
  alias Testor.Auth
  alias Testor.Auth.{CLI, JWT, Password, TokenKeys}
  alias Testor.Web.Router

  @password "correct horse battery"
  @opts Router.init([])
  @secret String.duplicate("s", 32)

  # RFC 8037, appendix A: the Ed25519 key and its JWK thumbprint.
  @rfc_seed "nWGxne_9WmC6hEr0kuwsxERJxWl7MmkZcDusAxyuf2A"
  @rfc_x "11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo"
  @rfc_kid "kPrK_qmxVWaYVA9wwBF6Iuo3vVzz7TxHCTwXBygrS4k"

  setup do
    on_exit(fn ->
      File.rm(TokenKeys.file())
      File.rm(TokenKeys.file() <> ".tmp")
      File.rm(Auth.key_file())
      File.rm(Auth.auth_file())
      System.delete_env(TokenKeys.env())
      System.delete_env("TESTOR_PASSWORD")
      Application.delete_env(:testor, :auth)
      Application.delete_env(:testor, :auth_token_keys)
      :persistent_term.erase({Auth, :settings})
    end)
  end

  defp claims(now, extra \\ %{}) do
    Map.merge(%{"iss" => "testor", "aud" => "testor", "sub" => "ada", "iat" => now, "exp" => now + 60}, extra)
  end

  defp ring(seeds \\ [String.duplicate("a", 32)]), do: TokenKeys.from_seeds(seeds)
  defp keys(ring, hs256 \\ nil), do: %{hs256: hs256, eddsa: ring.verify}
  defp b64(data), do: Base.url_encode64(data, padding: false)

  defp head(token),
    do: token |> String.split(".") |> hd() |> Base.url_decode64!(padding: false) |> JSON.decode!()

  describe "JWT with EdDSA" do
    test "verifies what it signed, with the key its kid names" do
      now = System.system_time(:second)
      ring = ring()
      token = JWT.sign(claims(now), ring.signing)

      assert %{"alg" => "EdDSA", "typ" => "JWT", "kid" => kid} = head(token)
      assert kid == ring.signing.kid
      assert {:ok, %{"sub" => "ada"}} = JWT.verify(token, keys(ring), now)

      other = ring([String.duplicate("b", 32)])
      assert JWT.verify(token, keys(other), now) == {:error, :unknown_key}
      assert JWT.verify(token, @secret, now) == {:error, :unknown_key}

      [h, _p, s] = String.split(token, ".")
      forged = b64(JSON.encode!(claims(now, %{"sub" => "eve"})))
      assert JWT.verify(Enum.join([h, forged, s], "."), keys(ring), now) == {:error, :signature}
    end

    test "each algorithm with its own kind of key only" do
      now = System.system_time(:second)
      ring = ring()
      payload = b64(JSON.encode!(claims(now)))

      # An HS256 token whose secret is the public key: no use, the HMAC secret is another.
      [%{public: public}] = Map.values(ring.verify)
      confused = JWT.sign(claims(now), public)
      assert JWT.verify(confused, keys(ring, @secret), now) == {:error, :signature}
      # And without a secret, HS256 is not accepted at all.
      assert JWT.verify(confused, keys(ring), now) == {:error, :algorithm}
      assert {:ok, _} = JWT.verify(JWT.sign(claims(now), @secret), keys(ring, @secret), now)

      # EdDSA without a kid, an unknown critical extension, none.
      for header <- [
            %{"alg" => "EdDSA"},
            %{"alg" => "none"},
            %{"alg" => "EdDSA", "kid" => ring.signing.kid, "crit" => ["exp"]}
          ] do
        token = "#{b64(JSON.encode!(header))}.#{payload}.#{b64("sig")}"
        assert JWT.verify(token, keys(ring), now) in [{:error, :algorithm}, {:error, :malformed}]
      end
    end

    test "a retired key verifies what it signed before it was retired only" do
      now = System.system_time(:second)
      ring = ring()
      [kid] = Map.keys(ring.verify)
      retired = put_in(ring.verify[kid].retired, now - 10)

      before = JWT.sign(claims(now, %{"iat" => now - 20}), ring.signing)
      later = JWT.sign(claims(now), ring.signing)
      assert {:ok, _} = JWT.verify(before, keys(retired), now)
      assert JWT.verify(later, keys(retired), now) == {:error, :retired_key}
    end
  end

  describe "the key ring" do
    test "a key's id is its JWK thumbprint (RFC 8037)" do
      ring = TokenKeys.from_seeds([Base.url_decode64!(@rfc_seed, padding: false)])
      assert ring.signing.kid == @rfc_kid

      assert TokenKeys.jwks(ring) == %{
               "keys" => [
                 %{
                   "kty" => "OKP",
                   "crv" => "Ed25519",
                   "x" => @rfc_x,
                   "kid" => @rfc_kid,
                   "alg" => "EdDSA",
                   "use" => "sig"
                 }
               ]
             }

      assert TokenKeys.jwks(nil) == %{"keys" => []}
    end

    test "created on first use, rolled and reset" do
      capture_log(fn -> TokenKeys.load!() end)
      first = TokenKeys.load!().signing.kid

      if match?({:unix, _}, :os.type()) do
        assert File.stat!(TokenKeys.file()).mode |> Bitwise.band(0o777) == 0o600
      end

      assert TokenKeys.load!().signing.kid == first

      second = TokenKeys.roll!(86_400)
      ring = TokenKeys.load!()
      assert ring.signing.kid == second and second != first
      assert %{retired: retired} = ring.verify[first]
      assert is_integer(retired) and ring.verify[second].retired == nil
      # The signing key comes first in the set.
      assert [%{"kid" => ^second}, %{"kid" => ^first}] = TokenKeys.jwks(ring)["keys"]

      # Once every token of a retired key has expired, the key goes.
      %{"keys" => [newer, older]} = TokenKeys.file() |> File.read!() |> JSON.decode!()
      long_ago = Map.put(older, "retired", System.system_time(:second) - 100_000)
      File.write!(TokenKeys.file(), JSON.encode!(%{"keys" => [newer, long_ago]}))
      third = TokenKeys.roll!(86_400)
      assert Map.keys(TokenKeys.load!().verify) |> Enum.sort() == Enum.sort([third, second])
      assert TokenKeys.roll!(0) |> then(&(Map.keys(TokenKeys.load!().verify) == [&1]))

      fourth = TokenKeys.reset!()
      assert Map.keys(TokenKeys.load!().verify) == [fourth]
    end

    test "a file or variable that cannot be read raises" do
      for text <- ["nope", ~s({"keys": []}), ~s({"keys": [1]}), ~s({"keys": [{"seed": "c2hvcnQ="}]})] do
        File.write!(TokenKeys.file(), text)
        assert_raise RuntimeError, fn -> TokenKeys.load!() end
      end

      File.rm!(TokenKeys.file())
      File.mkdir_p!(TokenKeys.file())
      assert_raise RuntimeError, ~r/cannot read/, fn -> TokenKeys.load!() end
      File.rmdir!(TokenKeys.file())

      System.put_env(TokenKeys.env(), "short")
      assert_raise RuntimeError, ~r/TESTOR_TOKEN_KEY/, fn -> TokenKeys.load!() end

      seed = :crypto.strong_rand_bytes(32)
      System.put_env(TokenKeys.env(), Base.encode64(seed))
      assert TokenKeys.load!().signing.kid == TokenKeys.from_seeds([seed]).signing.kid
      refute File.exists?(TokenKeys.file())

      System.put_env(TokenKeys.env(), "")
      capture_log(fn -> TokenKeys.load!() end)
      assert File.exists?(TokenKeys.file())
    end
  end

  describe "testor's tokens" do
    setup do
      hash = Password.hash(@password, 1000)
      users = %{"ada" => %{"password" => hash, "role" => "admin"}}
      Testor.Auth.Guard.reset()
      %{users: users}
    end

    defp token_for(users, tokens) do
      Application.put_env(:testor, :auth, %{"users" => users, "tokens" => tokens})
      s = Auth.settings()
      {s, Auth.mint("ada", ["read"], 600, s)["access_token"]}
    end

    test "EdDSA by default; HS256 accepted until refused", %{users: users} do
      {s, token} = token_for(users, %{})
      assert s.algorithm == "EdDSA" and s.accept_hs256
      assert %{"alg" => "EdDSA"} = head(token)
      assert {:ok, %{sub: "ada"}} = Auth.bearer(s, token, "test")

      {s, legacy} = token_for(users, %{"algorithm" => "HS256", "acceptHs256" => false})
      assert %{"alg" => "HS256"} = head(legacy)
      assert s.accept_hs256
      assert {:ok, _} = Auth.bearer(s, legacy, "test")
      assert {:ok, _} = Auth.bearer(s, token, "test")

      Application.put_env(:testor, :auth, %{"users" => users, "tokens" => %{"acceptHs256" => false}})

      capture_log(fn ->
        assert Auth.bearer(Auth.settings(), legacy, "test") == {:error, :invalid_token}
      end)

      log =
        capture_log(fn -> assert {%{algorithm: "EdDSA"}, _} = token_for(users, %{"algorithm" => "RS256"}) end)

      assert log =~ "tokens.algorithm \"RS256\""
    end

    test "verified by anyone with the published keys", %{users: users} do
      Application.put_env(:testor, :auth, %{"users" => users})

      conn =
        conn(:post, "/api/v1/auth/token", JSON.encode!(%{"scope" => "read"}))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Basic " <> Base.encode64("ada:#{@password}"))
        |> Router.call(@opts)

      %{"access_token" => token} = JSON.decode!(conn.resp_body)

      jwks = conn(:get, "/.well-known/jwks.json") |> Router.call(@opts)
      assert jwks.status == 200
      assert get_resp_header(jwks, "content-type") |> hd() =~ "application/jwk-set+json"
      assert get_resp_header(jwks, "cache-control") == ["public, max-age=300"]
      %{"keys" => [%{"kid" => kid, "x" => x}]} = JSON.decode!(jwks.resp_body)

      # What a verifier elsewhere does: the kid picks the key, the key checks the signature.
      [h, p, s] = String.split(token, ".")
      assert head(token)["kid"] == kid
      public = Base.url_decode64!(x, padding: false)

      assert :crypto.verify(:eddsa, :none, h <> "." <> p, Base.url_decode64!(s, padding: false), [
               public,
               :ed25519
             ])

      # While authentication is off there are no tokens, and no keys.
      Application.put_env(:testor, :auth, %{"users" => users, "enabled" => false})

      assert %{"keys" => []} =
               conn(:get, "/.well-known/jwks.json")
               |> Router.call(@opts)
               |> Map.get(:resp_body)
               |> JSON.decode!()
    end
  end

  test "the CLI rolls the token key and rotates every key" do
    System.put_env("TESTOR_PASSWORD", @password)
    capture_io(fn -> capture_log(fn -> CLI.user("ada", "admin") end) end)
    assert File.exists?(TokenKeys.file())
    first = TokenKeys.load!().signing.kid

    token = capture_io(fn -> CLI.token("ada", 1) end) |> String.trim()
    assert head(token)["kid"] == first

    assert capture_io(fn -> CLI.roll_token_key() end) =~ "new token signing key"
    assert {:ok, %{sub: "ada"}} = Auth.bearer(Auth.load_settings(), token, "test")

    assert capture_io(fn -> capture_log(fn -> CLI.rotate_key() end) end) =~ "every token is revoked"
    assert Map.keys(TokenKeys.load!().verify) |> length() == 1

    capture_log(fn ->
      assert Auth.bearer(Auth.load_settings(), token, "test") == {:error, :invalid_token}
    end)

    System.put_env(TokenKeys.env(), Base.encode64(:crypto.strong_rand_bytes(32)))
    assert_raise CLI.Error, ~r/secret store/, fn -> CLI.roll_token_key() end
    assert_raise CLI.Error, ~r/secret store/, fn -> CLI.rotate_key() end
  end
end
