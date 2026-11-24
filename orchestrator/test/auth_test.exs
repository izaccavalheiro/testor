defmodule Testor.AuthTest do
  use ExUnit.Case, async: true
  alias Testor.Auth
  alias Testor.Auth.{JWT, Password}

  @key String.duplicate("s", 32)

  defp settings(users \\ %{}) do
    %{enabled: true, users: users, key: @key, default_ttl: 3600, max_ttl: 86_400}
  end

  defp user(role, valid_after \\ 0) do
    %{
      hash: Password.hash("correct horse battery", 1000),
      role: role,
      scopes: Auth.role_scopes(role),
      valid_after: valid_after
    }
  end

  defp claims(now, extra \\ %{}) do
    Map.merge(%{"iss" => "testor", "aud" => "testor", "sub" => "ada", "iat" => now, "exp" => now + 60}, extra)
  end

  describe "Password" do
    test "verifies the password it hashed, and only that one" do
      hash = Password.hash("correct horse battery", 1000)
      assert Password.valid?(hash)
      assert "$pbkdf2-sha256$1000$" <> _ = hash
      assert Password.verify("correct horse battery", hash)
      refute Password.verify("correct horse batterY", hash)
    end

    test "salts every hash" do
      refute Password.hash("same password", 1000) == Password.hash("same password", 1000)
    end

    test "refuses malformed hashes" do
      refute Password.verify("x", "plain")
      refute Password.verify("x", "$pbkdf2-sha256$abc$salt$hash")
      refute Password.verify("x", "$pbkdf2-sha256$1000$!!$!!")
      refute Password.valid?("$2b$12$bcrypt")
    end
  end

  describe "JWT" do
    test "verifies what it signed" do
      now = System.system_time(:second)
      token = JWT.sign(claims(now), @key)
      assert {:ok, %{"sub" => "ada"}} = JWT.verify(token, @key, now)
    end

    test "refuses another key, a changed payload and an expired token" do
      now = System.system_time(:second)
      token = JWT.sign(claims(now), @key)
      assert JWT.verify(token, String.duplicate("t", 32), now) == {:error, :signature}

      [h, _p, s] = String.split(token, ".")
      forged = Base.url_encode64(JSON.encode!(claims(now, %{"sub" => "eve"})), padding: false)
      assert JWT.verify(Enum.join([h, forged, s], "."), @key, now) == {:error, :signature}

      assert JWT.verify(token, @key, now + 120) == {:error, :expired}
    end

    test "refuses the none algorithm and any other than HS256" do
      now = System.system_time(:second)
      payload = Base.url_encode64(JSON.encode!(claims(now)), padding: false)

      for alg <- ["none", "HS512", "RS256"] do
        header = Base.url_encode64(JSON.encode!(%{"alg" => alg, "typ" => "JWT"}), padding: false)
        assert JWT.verify("#{header}.#{payload}.", @key, now) == {:error, :algorithm}
      end
    end

    test "checks issuer, audience and not-before" do
      now = System.system_time(:second)
      assert JWT.verify(JWT.sign(claims(now, %{"iss" => "x"}), @key), @key, now) == {:error, :issuer}
      assert JWT.verify(JWT.sign(claims(now, %{"aud" => "x"}), @key), @key, now) == {:error, :audience}
      assert {:ok, _} = JWT.verify(JWT.sign(claims(now, %{"aud" => ["x", "testor"]}), @key), @key, now)

      assert JWT.verify(JWT.sign(claims(now, %{"nbf" => now + 600}), @key), @key, now) ==
               {:error, :not_yet_valid}

      assert JWT.verify("a.b", @key, now) == {:error, :malformed}
    end
  end

  describe "tokens" do
    test "a Basic principal gets a token with a subset of its scopes" do
      s = settings(%{"ada" => user("operator")})
      basic = %{sub: "ada", scopes: ["read", "operate"], via: :basic}

      assert {:ok,
              %{"access_token" => token, "token_type" => "Bearer", "scope" => "read", "expires_in" => 600}} =
               Auth.issue_token(basic, %{"scope" => "read", "expires_in" => 600}, s)

      assert {:ok, %{sub: "ada", scopes: ["read"], via: :bearer}} = Auth.bearer(s, token, "test")
      assert Auth.issue_token(basic, %{"scope" => "maintain"}, s) == {:error, :invalid_scope}
      assert Auth.issue_token(basic, %{"expires_in" => 5}, s) == {:error, :invalid_request}
      assert {:ok, %{"expires_in" => 86_400}} = Auth.issue_token(basic, %{"expires_in" => "999999"}, s)
    end

    test "a token cannot obtain another token" do
      assert Auth.issue_token(%{sub: "ada", scopes: ["read"], via: :bearer}, %{}, settings()) ==
               {:error, :invalid_client}
    end

    test "a token follows its user: removed, demoted or revoked" do
      s = settings(%{"ada" => user("admin")})
      %{"access_token" => token} = Auth.mint("ada", ["read", "operate"], 600, s)

      assert {:ok, %{scopes: ["read", "operate"]}} = Auth.bearer(s, token, "test")
      assert {:ok, %{scopes: ["read"]}} = Auth.bearer(settings(%{"ada" => user("viewer")}), token, "test")
      assert Auth.bearer(settings(), token, "test") == {:error, :revoked}

      later = System.system_time(:second) + 10
      assert Auth.bearer(settings(%{"ada" => user("admin", later)}), token, "test") == {:error, :revoked}
    end
  end

  describe "signed file links" do
    test "are bound to a run and expire" do
      s = settings()
      now = 1_800_000_000
      "/s/" <> cap = Auth.file_prefix("run-1", s, now)

      assert Auth.file_cap_valid?(cap, "run-1", s, now)
      assert Auth.file_cap_valid?(cap, "run-1", s, now + 86_400)
      refute Auth.file_cap_valid?(cap, "run-2", s, now)
      refute Auth.file_cap_valid?(cap, "run-1", s, now + 3 * 86_400)
      refute Auth.file_cap_valid?(cap, "run-1", %{s | key: String.duplicate("t", 32)}, now)
      refute Auth.file_cap_valid?("garbage", "run-1", s, now)
    end

    test "are not used while authentication is off" do
      assert Auth.file_prefix("run-1", %{settings() | enabled: false}) == ""
    end
  end
end
