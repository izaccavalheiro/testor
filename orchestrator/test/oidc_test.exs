defmodule Testor.OIDCTest do
  @moduledoc "Sign-in to the dashboard with an OpenID Connect provider, end to end against a fake one."
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  import Plug.Test
  import Plug.Conn
  import Testor.Test.Helpers
  alias Testor.Auth
  alias Testor.Auth.{Guard, JWT, OIDC, Password}
  alias Testor.Test.FakeIdP
  alias Testor.Web.Router

  @opts Router.init([])
  @password "correct horse battery"
  @redirect "https://testor.example.com/auth/callback"

  setup do
    Guard.reset()
    OIDC.reset_cache()
    issuer = FakeIdP.start()

    on_exit(fn ->
      OIDC.reset_cache()
      Application.delete_env(:testor, :auth)
      System.delete_env("TESTOR_OIDC_CLIENT_SECRET")
    end)

    configure(issuer)
    %{issuer: issuer}
  end

  defp oidc(issuer, extra \\ %{}) do
    Map.merge(
      %{
        "issuer" => issuer,
        "clientId" => "testor",
        "clientSecret" => "s3cret&=",
        "redirectUri" => @redirect,
        "roles" => %{"admin" => ["platform"], "operator" => ["qa"], "viewer" => ["staff"]},
        "projects" => %{"qa" => ["web*"], "platform" => ["*"]}
      },
      extra
    )
  end

  defp configure(issuer, extra \\ %{}) do
    users = %{"ada" => %{"password" => Password.hash(@password, 1000), "role" => "admin"}}
    Application.put_env(:testor, :auth, %{"users" => users, "oidc" => oidc(issuer, extra)})
  end

  defp claims(issuer, nonce, extra \\ %{}) do
    now = System.system_time(:second)

    Map.merge(
      %{
        "iss" => issuer,
        "aud" => "testor",
        "sub" => "u-1",
        "email" => "grace@example.com",
        "email_verified" => true,
        "groups" => ["qa"],
        "iat" => now,
        "exp" => now + 300,
        "nonce" => nonce
      },
      extra
    )
  end

  # /auth/login, then the provider's answer to /auth/callback with the claims `extra` changes.
  defp sign_in(issuer, extra \\ %{}, opts \\ []) do
    login = conn(:get, "/auth/login?return=/runs") |> Router.call(@opts)
    assert login.status == 302
    [location] = get_resp_header(login, "location")
    query = location |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    cookie = login.resp_cookies["testor_oidc"]
    claims = claims(issuer, query["nonce"], extra)
    FakeIdP.code("code-1", claims, query["code_challenge"], opts[:alg] || "RS256", opts[:header] || %{})
    state = Keyword.get(opts, :state, query["state"])

    callback =
      conn(:get, "/auth/callback?" <> URI.encode_query(%{"code" => "code-1", "state" => state}))
      |> put_req_cookie("testor_oidc", cookie.value)
      |> Router.call(@opts)

    %{login: login, location: location, query: query, cookie: cookie, callback: callback}
  end

  defp session_of(%{callback: callback}), do: callback.resp_cookies["testor_session"].value

  defp with_session(conn, session), do: put_req_cookie(conn, "testor_session", session)

  defp refused(issuer, extra, opts \\ []) do
    Guard.reset()

    capture_log(fn ->
      %{callback: callback} = sign_in(issuer, extra, opts)
      assert callback.status == 403
      send(self(), {:body, callback.resp_body})
    end)

    assert_received {:body, body}
    body
  end

  describe "configuration" do
    test "checked, with defaults" do
      assert OIDC.config(nil) == nil
      base = oidc("https://idp.example.com")

      assert %{
               scopes: ["openid", "email", "profile", "groups"],
               username_claim: "email",
               groups_claim: "groups",
               session_ttl: 28_800,
               secure: true,
               valid_after: 0
             } = OIDC.config(Map.put(base, "scopes", ["groups"]))

      assert %{session_ttl: 604_800, valid_after: 5, username_claim: "upn", secure: false} =
               OIDC.config(
                 Map.merge(base, %{
                   "sessionHours" => 1000,
                   "sessionsValidAfter" => 5,
                   "usernameClaim" => "upn",
                   "redirectUri" => "http://testor.lan:6767/auth/callback"
                 })
               )

      System.put_env("TESTOR_OIDC_CLIENT_SECRET", "from-env")
      assert %{client_secret: "from-env"} = OIDC.config(base)
      System.put_env("TESTOR_OIDC_CLIENT_SECRET", "")
      assert %{client_secret: "s3cret&="} = OIDC.config(base)
      assert %{client_secret: nil} = OIDC.config(Map.delete(base, "clientSecret"))

      log =
        capture_log(fn ->
          for bad <- [
                %{"issuer" => "http://idp.example.com"},
                %{"issuer" => "ftp://idp"},
                %{"issuer" => nil},
                %{"clientId" => ""},
                %{"clientSecret" => 5},
                %{"redirectUri" => "https://testor.example.com/elsewhere"},
                %{"redirectUri" => "/auth/callback"},
                %{"roles" => %{"owner" => ["x"]}},
                %{"roles" => %{}},
                %{"roles" => nil},
                %{"projects" => %{"qa" => ["a b"]}},
                %{"projects" => ["web"]},
                %{"scopes" => "groups"}
              ] do
            assert OIDC.config(Map.merge(base, bad)) == nil, inspect(bad)
          end

          assert OIDC.config("on") == nil
        end)

      assert log =~ "issuer must be an https URL"
      assert log =~ "oidc is not an object"
      assert OIDC.secure_url?("http://localhost:1/x") and OIDC.secure_url?("http://[::1]:1/x")
    end

    test "an oidc section turns authentication on", %{issuer: issuer} do
      Application.put_env(:testor, :auth, %{"oidc" => oidc(issuer)})
      assert Auth.settings().enabled
      assert %{"keys" => [_]} = conn(:get, "/.well-known/jwks.json") |> Router.call(@opts) |> body()
    end
  end

  defp body(conn), do: JSON.decode!(conn.resp_body)

  describe "signing in" do
    test "code flow with PKCE, a session cookie, the dashboard and signing out", %{issuer: issuer} do
      flow = sign_in(issuer)

      # To the provider, with everything it needs.
      assert String.starts_with?(flow.location, issuer <> "/authorize?")

      assert %{
               "response_type" => "code",
               "client_id" => "testor",
               "redirect_uri" => @redirect,
               "scope" => "openid email profile",
               "code_challenge_method" => "S256"
             } = flow.query

      assert %{http_only: true, same_site: "Lax", secure: true, path: "/auth", max_age: 600} = flow.cookie

      # Back with a session; the code was exchanged with the verifier and the client's secret.
      callback = flow.callback
      assert callback.status == 302
      assert get_resp_header(callback, "location") == ["/runs"]

      assert %{http_only: true, same_site: "Lax", secure: true, path: "/", max_age: 28_800} =
               callback.resp_cookies["testor_session"]

      assert %{max_age: 0} = callback.resp_cookies["testor_oidc"]
      [request] = FakeIdP.state().requests
      assert request.form["grant_type"] == "authorization_code" and request.form["code_verifier"] != nil
      refute Map.has_key?(request.form, "client_secret")
      assert request.authorization == "Basic " <> Base.encode64("testor:s3cret%26%3D")

      session = session_of(flow)

      me = conn(:get, "/api/v1/auth/me") |> with_session(session) |> Router.call(@opts) |> body()

      assert %{"user" => "grace@example.com", "via" => "session", "scopes" => ["read", "operate"], "projects" => ["web*"]} =
               me

      assert (conn(:get, "/") |> with_session(session) |> Router.call(@opts)).status == 200

      # The session is not a Bearer token, and a token is not a session.
      bearer = conn(:get, "/api/v1/auth/me") |> put_req_header("authorization", "Bearer " <> session)
      capture_log(fn -> assert (bearer |> Router.call(@opts)).status == 401 end)

      %{"access_token" => token} = Auth.mint("ada", ["read"], 600, Auth.settings())
      assert (conn(:get, "/api/v1/runs") |> with_session(token) |> Router.call(@opts)).status == 401

      # Signing out.
      out =
        conn(:post, "/auth/logout")
        |> put_req_header("x-testor", "1")
        |> with_session(session)
        |> Router.call(@opts)

      assert out.status == 200
      assert %{max_age: 0} = out.resp_cookies["testor_session"]
      assert (conn(:get, "/auth/signed-out") |> Router.call(@opts)).resp_body =~ "/auth/login"
    end

    test "ES256 and EdDSA, the secret in the form, a public client", %{issuer: issuer} do
      FakeIdP.meta(%{"token_endpoint_auth_methods_supported" => ["client_secret_post"]})
      assert %{callback: %{status: 302}} = sign_in(issuer, %{"groups" => "platform"}, alg: "ES256")
      [request | _] = FakeIdP.state().requests
      assert request.form["client_secret"] == "s3cret&=" and request.authorization == nil

      configure(issuer, %{"clientSecret" => nil})
      flow = sign_in(issuer, %{"groups" => ["staff", 7]}, alg: "EdDSA")
      assert flow.callback.status == 302
      [request | _] = FakeIdP.state().requests
      refute Map.has_key?(request.form, "client_secret")
      assert request.authorization == nil

      me = conn(:get, "/api/v1/auth/me") |> with_session(session_of(flow)) |> Router.call(@opts) |> body()
      assert %{"scopes" => ["read"], "projects" => []} = me
    end

    test "everyone, every project", %{issuer: issuer} do
      configure(issuer, %{"roles" => %{"viewer" => ["*"]}, "projects" => %{"*" => ["web"], "platform" => ["*"]}})
      flow = sign_in(issuer, %{"groups" => nil})
      me = conn(:get, "/api/v1/auth/me") |> with_session(session_of(flow)) |> Router.call(@opts) |> body()
      assert %{"scopes" => ["read"], "projects" => ["web"]} = me

      flow = sign_in(issuer, %{"groups" => ["platform"], "aud" => ["testor", "other"], "azp" => "testor"})
      me = conn(:get, "/api/v1/auth/me") |> with_session(session_of(flow)) |> Router.call(@opts) |> body()
      assert me["projects"] == nil

      configure(issuer, %{"projects" => nil})
      flow = sign_in(issuer)
      me = conn(:get, "/api/v1/auth/me") |> with_session(session_of(flow)) |> Router.call(@opts) |> body()
      assert me["projects"] == nil
    end

    test "the provider's key rolled: fetched again, at most once a minute", %{issuer: issuer} do
      assert %{callback: %{status: 302}} = sign_in(issuer)
      FakeIdP.roll("RS256")
      assert refused(issuer, %{}) =~ "key is not in the provider"

      # A minute later the set is fetched again.
      cache = :persistent_term.get({OIDC, :cache})
      old = Map.new(cache, fn {url, {_at, doc}} -> {url, {System.monotonic_time(:millisecond) - 61_000, doc}} end)
      :persistent_term.put({OIDC, :cache}, old)
      assert %{callback: %{status: 302}} = sign_in(issuer)
    end

    test "a key without a kid, when it is the only one", %{issuer: issuer} do
      FakeIdP.publish(["EdDSA"])
      FakeIdP.update(fn s -> update_in(s.keys["EdDSA"], fn {_kid, priv, jwk} -> {nil, priv, jwk} end) end)
      assert %{callback: %{status: 302}} = sign_in(issuer, %{}, alg: "EdDSA", header: %{"kid" => nil})

      # None of the right type.
      FakeIdP.publish(["ES256"])
      OIDC.reset_cache()
      assert refused(issuer, %{}, alg: "EdDSA", header: %{"kid" => nil}) =~ "key is not in"
    end
  end

  describe "refused" do
    test "what the provider sends that does not hold", %{issuer: issuer} do
      now = System.system_time(:second)

      for {extra, message} <- [
            {%{"iss" => "https://elsewhere"}, "another issuer"},
            {%{"aud" => "other"}, "another client"},
            {%{"aud" => ["testor", "other"]}, "another client"},
            {%{"exp" => now - 120}, "expired"},
            {%{"iat" => now + 600}, "is not valid"},
            {%{"nonce" => "replayed"}, "nonce does not match"},
            {%{"groups" => ["nobody"]}, "no group that has a role"},
            {%{"email_verified" => false}, "not verified"},
            {%{"email" => "not a name"}, "no usable email"}
          ] do
        assert refused(issuer, extra) =~ message
      end

      assert refused(issuer, %{}, alg: "ES256", header: %{"alg" => "HS256"}) =~ "ID token is not valid"
      assert refused(issuer, %{}, header: %{"kid" => "unknown"}) =~ "key is not in"
      assert refused(issuer, %{}, state: "forged") =~ "state does not match"

      # A signature of the wrong key, and an ES256 signature of the wrong size.
      FakeIdP.update(fn s -> put_in(s.keys["RS256"], put_elem(FakeIdP.key("RS256"), 0, elem(s.keys["RS256"], 0))) end)
      assert refused(issuer, %{}) =~ "signature does not hold"
    end

    test "the token endpoint's answers", %{issuer: issuer} do
      FakeIdP.token_response({400, ~s({"error":"invalid_grant"})})
      assert refused(issuer, %{}) =~ "answered 400: invalid_grant"
      FakeIdP.token_response({500, "oops"})
      assert refused(issuer, %{}) =~ "answered 500"
      FakeIdP.token_response({200, "[1]"})
      assert refused(issuer, %{}) =~ "did not answer a JSON object"
      FakeIdP.token_response({200, ~s({"access_token":"x"})})
      assert refused(issuer, %{}) =~ "sent no ID token"
    end

    test "answers that are not the provider's", %{issuer: issuer} do
      capture_log(fn ->
        error = conn(:get, "/auth/callback?error=access_denied&error_description=no") |> Router.call(@opts)
        assert error.status == 403 and error.resp_body =~ "access_denied no"

        assert (conn(:get, "/auth/callback?code=x&state=y") |> Router.call(@opts)).resp_body =~ "expired"

        forged =
          conn(:get, "/auth/callback?code=x&state=y") |> put_req_cookie("testor_oidc", "forged") |> Router.call(@opts)

        assert forged.resp_body =~ "expired"

        %{cookie: cookie, query: query} = sign_in(issuer)

        no_code =
          conn(:get, "/auth/callback?state=#{query["state"]}")
          |> put_req_cookie("testor_oidc", cookie.value)
          |> Router.call(@opts)

        assert no_code.resp_body =~ "no code"
      end)

      # Ten refusals and the address waits.
      for _ <- 1..10, do: Guard.failed("127.0.0.1")
      :sys.get_state(Guard)
      blocked = conn(:get, "/auth/callback?code=x") |> Router.call(@opts)
      assert blocked.status == 429 and get_resp_header(blocked, "retry-after") != []
    end

    test "a provider that cannot be used", %{issuer: issuer} do
      capture_log(fn ->
        for meta <- [%{"issuer" => "https://other"}, %{"token_endpoint" => "http://idp.example.com/token"}] do
          OIDC.reset_cache()
          FakeIdP.meta(meta)
          assert (conn(:get, "/auth/login") |> Router.call(@opts)).status == 502
        end

        configure("http://127.0.0.1:1")
        assert (conn(:get, "/auth/login") |> Router.call(@opts)).status == 502

        configure(issuer <> "/missing")
        assert (conn(:get, "/auth/login") |> Router.call(@opts)).status == 502
      end)

      FakeIdP.meta(%{"authorization_endpoint" => issuer <> "/authorize?tenant=a"})
      OIDC.reset_cache()
      configure(issuer)
      [location] = conn(:get, "/auth/login") |> Router.call(@opts) |> get_resp_header("location")
      assert location =~ "/authorize?tenant=a&"
    end
  end

  describe "the dashboard and the API with a provider" do
    test "a visitor goes to the provider; only /?basic asks for a password" do
      assert %{status: 302} = visitor = conn(:get, "/") |> Router.call(@opts)
      assert get_resp_header(visitor, "location") == ["/auth/login"]

      api = conn(:get, "/api/v1/runs") |> Router.call(@opts)
      assert api.status == 401
      refute Enum.any?(get_resp_header(api, "www-authenticate"), &String.starts_with?(&1, "Basic"))

      basic = conn(:get, "/?basic") |> Router.call(@opts)
      assert basic.status == 401
      assert Enum.any?(get_resp_header(basic, "www-authenticate"), &String.starts_with?(&1, "Basic"))

      ok =
        conn(:get, "/?basic")
        |> put_req_header("authorization", "Basic " <> Base.encode64("ada:#{@password}"))
        |> Router.call(@opts)

      assert ok.status == 200

      nope =
        conn(:get, "/auth/nope")
        |> put_req_header("authorization", "Basic " <> Base.encode64("ada:#{@password}"))
        |> Router.call(@opts)

      assert nope.status == 404
    end

    test "sessions end: expired, ended by sessionsValidAfter, of an unknown role", %{issuer: issuer} do
      flow = sign_in(issuer)
      session = session_of(flow)
      settings = Auth.settings()
      assert {:ok, %{via: :session}} = OIDC.session(settings, session)
      assert {:error, :expired} = OIDC.session(settings, session, System.system_time(:second) + 30_000)

      configure(issuer, %{"sessionsValidAfter" => System.system_time(:second) + 10})
      assert {:error, :revoked} = OIDC.session(Auth.settings(), session)
      assert (conn(:get, "/") |> with_session(session) |> Router.call(@opts)).status == 302

      configure(issuer)
      settings = Auth.settings()
      now = System.system_time(:second)

      forged =
        JWT.sign(
          %{"iss" => "testor", "aud" => "testor-session", "sub" => "x", "iat" => now, "exp" => now + 60, "role" => "root"},
          settings.token_keys.signing
        )

      assert {:error, :malformed} = OIDC.session(settings, forged)
      assert {:error, :none} = OIDC.session(%{oidc: nil}, session)
    end

    test "a session limited to projects sees those only", %{issuer: issuer} do
      web = record(%{"project" => "web-app"})
      other = record(%{"project" => "secret-app"})
      on_exit(fn -> Enum.each([web, other], &Testor.Store.delete/1) end)

      session = issuer |> sign_in() |> session_of()
      %{"data" => runs} = conn(:get, "/api/v1/runs") |> with_session(session) |> Router.call(@opts) |> body()
      ids = Enum.map(runs, & &1["id"])
      assert web in ids and other not in ids
    end
  end

  test "without a provider" do
    Application.put_env(:testor, :auth, %{"users" => %{"ada" => %{"password" => Password.hash(@password, 1000)}}})
    assert (conn(:get, "/auth/login") |> Router.call(@opts)).status == 404
    capture_log(fn -> assert (conn(:get, "/auth/callback") |> Router.call(@opts)).status == 404 end)
    assert (conn(:get, "/auth/signed-out") |> Router.call(@opts)).resp_body =~ ~s(href="/")
    visitor = conn(:get, "/") |> Router.call(@opts)
    assert visitor.status == 401
    assert Enum.any?(get_resp_header(visitor, "www-authenticate"), &String.starts_with?(&1, "Basic"))
  end

  describe "pieces" do
    test "keys from JWKs, and return paths" do
      assert OIDC.decode_key("RS256", %{"kty" => "RSA", "n" => "!", "e" => "AQAB"}) == nil
      assert OIDC.decode_key("ES256", %{"kty" => "EC", "crv" => "P-256", "x" => "AA", "y" => "AA"}) == nil
      assert OIDC.decode_key("EdDSA", %{"kty" => "OKP", "crv" => "Ed25519", "x" => "AA"}) == nil
      assert OIDC.decode_key("ES256", %{"kty" => "RSA"}) == nil

      for {return, expected} <- [
            {"/runs?x=1", "/runs?x=1"},
            {"//evil.example", "/"},
            {"/\\evil.example", "/"},
            {"https://evil.example", "/"},
            {"/a\r\nb", "/"}
          ] do
        login = conn(:get, "/auth/login?" <> URI.encode_query(%{"return" => return})) |> Router.call(@opts)
        cookie = login.resp_cookies["testor_oidc"].value
        {:ok, decoded} = Plug.Crypto.decrypt(Auth.settings().key, "testor_oidc", cookie)
        assert decoded["return"] == expected, return
      end
    end

    test "ID tokens that cannot be read, key sets without keys", %{issuer: issuer} do
      oidc = OIDC.config(oidc(issuer))
      {:ok, meta} = OIDC.metadata(oidc)
      now = System.system_time(:second)
      assert {:error, "the ID token is not valid"} = OIDC.verify_id_token("a.b", oidc, meta, "n", now)

      FakeIdP.publish([])
      OIDC.reset_cache()
      token = FakeIdP.sign(claims(issuer, "n"), "ES256")
      assert {:error, "the ID token's key" <> _} = OIDC.verify_id_token(token, oidc, meta, "n", now)

      # An ES256 signature of the wrong size.
      FakeIdP.publish(["ES256"])
      OIDC.reset_cache()
      [h, p, _] = String.split(token, ".")
      short = Enum.join([h, p, Base.url_encode64("short", padding: false)], ".")
      assert {:error, "the ID token's signature does not hold"} = OIDC.verify_id_token(short, oidc, meta, "n", now)

      # A set that is not a set.
      :persistent_term.put({OIDC, :cache}, %{meta["jwks_uri"] => {System.monotonic_time(:millisecond), %{"no" => 1}}})
      assert {:error, _} = OIDC.verify_id_token(token, oidc, meta, "n", now)

      # A set that cannot be fetched, at first or again.
      gone = Map.put(meta, "jwks_uri", issuer <> "/gone")
      assert {:error, "http" <> _} = OIDC.verify_id_token(token, oidc, gone, "n", now)
      stale = System.monotonic_time(:millisecond) - 61_000
      :persistent_term.put({OIDC, :cache}, %{gone["jwks_uri"] => {stale, %{"keys" => []}}})
      assert {:error, "http" <> rest} = OIDC.verify_id_token(token, oidc, gone, "n", now)
      assert rest =~ "answered 404"
    end
  end
end
