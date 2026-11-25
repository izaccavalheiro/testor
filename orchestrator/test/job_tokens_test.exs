defmodule Testor.JobTokensTest do
  @moduledoc "Identity tokens for jobs: testor as an OpenID Connect issuer clouds and Vault trust."
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn
  import ExUnit.CaptureIO
  import ExUnit.CaptureLog
  alias Testor.{Config, Jobs}
  alias Testor.Auth
  alias Testor.Auth.{CLI, Guard, JobTokens, Password}
  alias Testor.Web.Router

  @password "correct horse battery"
  @opts Router.init([])
  @issuer "https://testor.example.com"

  setup_all do
    # One RSA key for the whole module: making one takes a moment.
    File.rm(JobTokens.file())
    capture_log(fn -> JobTokens.load!() end)
    ring = JobTokens.load!()
    File.rm(JobTokens.file())
    %{ring: ring}
  end

  setup %{ring: ring} do
    Guard.reset()
    :sys.replace_state(Jobs, fn _ -> %{} end)

    File.write!(
      Path.join(Config.data_dir(), "config.json"),
      JSON.encode!(%{"execution" => %{"enabled" => true}})
    )

    Application.put_env(:testor, :auth_job_token_keys, ring)
    configure(%{"issuer" => @issuer <> "/", "audiences" => ["sts.amazonaws.com", "vault"]})

    on_exit(fn ->
      File.rm(Path.join(Config.data_dir(), "config.json"))
      File.rm(JobTokens.file())
      File.rm(Auth.auth_file())
      File.rm(Auth.key_file())
      File.rm(Testor.Auth.TokenKeys.file())
      :sys.replace_state(Jobs, fn _ -> %{} end)
      Application.delete_env(:testor, :auth)
      Application.delete_env(:testor, :auth_job_token_keys)
      :persistent_term.erase({Auth, :settings})
    end)
  end

  defp configure(job_tokens) do
    hash = Password.hash(@password, 1000)

    users = %{
      "ada" => %{"password" => hash, "role" => "admin"},
      "runner-1" => %{"password" => hash, "role" => "agent"},
      "runner-2" => %{"password" => hash, "role" => "agent"}
    }

    Application.put_env(:testor, :auth, %{"users" => users, "jobTokens" => job_tokens})
  end

  defp post(path, body, user) do
    conn(:post, path, JSON.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Basic " <> Base.encode64("#{user}:#{@password}"))
    |> Router.call(@opts)
  end

  defp body(conn), do: JSON.decode!(conn.resp_body)
  defp part(token, i), do: token |> String.split(".") |> Enum.at(i) |> Base.url_decode64!(padding: false)

  defp leased_job do
    {:ok, job} = Jobs.enqueue(%{"project" => "web", "kind" => "deploy", "ref" => "main"}, "ada")
    assert %{status: 200} = post("/api/v1/agent/lease", %{}, "runner-1")
    job
  end

  test "configuration" do
    assert JobTokens.config(nil) == nil
    assert %{issuer: @issuer, ttl: 900} = JobTokens.config(%{"issuer" => @issuer, "audiences" => ["a"]})
    assert %{ttl: 3600} = JobTokens.config(%{"issuer" => @issuer, "audiences" => ["a"], "ttlMinutes" => 600})
    assert %{ttl: 120} = JobTokens.config(%{"issuer" => @issuer, "audiences" => ["a"], "ttlMinutes" => 2})

    log =
      capture_log(fn ->
        for bad <- [
              %{"issuer" => "http://testor.example.com", "audiences" => ["a"]},
              %{"issuer" => @issuer <> "?x=1", "audiences" => ["a"]},
              %{"issuer" => 5, "audiences" => ["a"]},
              %{"issuer" => @issuer, "audiences" => [""]},
              %{"issuer" => @issuer, "audiences" => []},
              "on"
            ] do
          assert JobTokens.config(bad) == nil, inspect(bad)
        end
      end)

    assert log =~ "jobs get no identity tokens"
  end

  test "an agent holding a job gets its token, signed with a published RS256 key" do
    job = leased_job()
    conn = post("/api/v1/agent/jobs/#{job["id"]}/token", %{"audience" => "sts.amazonaws.com"}, "runner-1")
    assert %{"token" => token, "expires_in" => 900} = body(conn)

    header = token |> part(0) |> JSON.decode!()
    claims = token |> part(1) |> JSON.decode!()
    assert %{"alg" => "RS256", "kid" => kid} = header

    assert %{
             "iss" => @issuer,
             "aud" => "sts.amazonaws.com",
             "sub" => "project:web:kind:deploy",
             "project" => "web",
             "kind" => "deploy",
             "ref" => "main",
             "agent" => "runner-1",
             "requested_by" => "ada"
           } = claims

    assert claims["job_id"] == job["id"] and claims["exp"] - claims["iat"] == 900

    # A cloud verifies it the way it would: discovery, then the key the kid names.
    discovery = conn(:get, "/.well-known/openid-configuration") |> Router.call(@opts)
    assert %{"issuer" => @issuer, "jwks_uri" => @issuer <> "/.well-known/jwks.json"} = body(discovery)
    assert %{"id_token_signing_alg_values_supported" => ["RS256"]} = body(discovery)

    %{"keys" => keys} = conn(:get, "/.well-known/jwks.json") |> Router.call(@opts) |> body()
    assert %{"kty" => "RSA", "n" => n, "e" => e, "alg" => "RS256"} = Enum.find(keys, &(&1["kid"] == kid))
    # The token keys are there too.
    assert Enum.any?(keys, &(&1["kty"] == "OKP"))

    public = {:RSAPublicKey, decode_int(n), decode_int(e)}
    [h, p, s] = String.split(token, ".")
    assert :public_key.verify(h <> "." <> p, :sha256, Base.url_decode64!(s, padding: false), public)

    # A job without a ref has no ref claim.
    {:ok, other} = Jobs.enqueue(%{"project" => "api", "kind" => "test"}, "ada")
    assert %{status: 200} = post("/api/v1/agent/lease", %{}, "runner-2")

    %{"token" => token} =
      post("/api/v1/agent/jobs/#{other["id"]}/token", %{"audience" => "vault"}, "runner-2") |> body()

    refute token |> part(1) |> JSON.decode!() |> Map.has_key?("ref")
  end

  defp decode_int(b64), do: b64 |> Base.url_decode64!(padding: false) |> :binary.decode_unsigned()

  test "refused: another agent's job, an audience not listed, a bad body, tokens off" do
    job = leased_job()
    path = "/api/v1/agent/jobs/#{job["id"]}/token"
    assert post(path, %{"audience" => "vault"}, "runner-2").status == 409
    assert post(path, %{"audience" => "evil"}, "runner-1").status == 400
    assert post(path, %{"audience" => "vault"}, "ada").status == 403
    assert post("/api/v1/agent/jobs/job-nope/token", %{"audience" => "vault"}, "runner-1").status == 404

    bad =
      conn(:post, path, "[1]")
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Basic " <> Base.encode64("runner-1:#{@password}"))
      |> Router.call(@opts)

    assert bad.status == 400

    capture_log(fn -> configure(nil) end)
    assert post(path, %{"audience" => "vault"}, "runner-1").status == 404
    assert (conn(:get, "/.well-known/openid-configuration") |> Router.call(@opts)).status == 404
    assert JobTokens.issue(%{job_tokens: nil}, job, "runner-1", "vault") == {:error, :off}
    assert JobTokens.jwks(nil) == []
  end

  test "keys: made on first use, rolled, refused when they cannot be read" do
    Application.delete_env(:testor, :auth)
    Application.delete_env(:testor, :auth_job_token_keys)

    File.write!(
      Auth.auth_file(),
      JSON.encode!(%{
        "users" => %{},
        "enabled" => true,
        "jobTokens" => %{"issuer" => @issuer, "audiences" => ["a"]}
      })
    )

    # Loading the settings makes the key, once job tokens are on.
    capture_log(fn -> assert %{job_token_keys: %{signing: %{kid: first}}} = Auth.load_settings() end)

    if match?({:unix, _}, :os.type()) do
      assert File.stat!(JobTokens.file()).mode |> Bitwise.band(0o777) == 0o600
    end

    first = JobTokens.load!().signing.kid
    assert capture_io(fn -> CLI.roll_job_token_key() end) =~ "new job token key"
    ring = JobTokens.load!()
    assert ring.signing.kid != first
    assert Enum.map(ring.public, & &1.kid) |> Enum.sort() == Enum.sort([first, ring.signing.kid])

    # Keys retired over an hour ago go at the next roll.
    %{"keys" => [newer, older]} = JobTokens.file() |> File.read!() |> JSON.decode!()
    old = Map.put(older, "retired", System.system_time(:second) - 4000)
    File.write!(JobTokens.file(), JSON.encode!(%{"keys" => [newer, old]}))
    third = JobTokens.roll!()

    assert JobTokens.load!().public |> Enum.map(& &1.kid) |> Enum.sort() ==
             Enum.sort([third, ring.signing.kid])

    for text <- ["nope", ~s({"keys":[]}), ~s({"keys":[{"pem":"x"}]}), ~s({"keys":[5]})] do
      File.write!(JobTokens.file(), text)
      assert_raise RuntimeError, fn -> JobTokens.load!() end
    end

    # An EC key is not an RSA key.
    ec = :public_key.generate_key({:namedCurve, {1, 2, 840, 10045, 3, 1, 7}})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:ECPrivateKey, ec)])
    File.write!(JobTokens.file(), JSON.encode!(%{"keys" => [%{"pem" => pem}]}))
    assert_raise RuntimeError, ~r/not an RSA/, fn -> JobTokens.load!() end

    File.rm!(JobTokens.file())
    File.mkdir_p!(JobTokens.file())
    assert_raise RuntimeError, ~r/cannot read/, fn -> JobTokens.load!() end
    File.rmdir!(JobTokens.file())

    # Rolling with no file yet makes one.
    capture_log(fn -> assert is_binary(JobTokens.roll!()) end)
    # Off: no key is made.
    File.rm!(JobTokens.file())
    File.write!(Auth.auth_file(), JSON.encode!(%{"users" => %{}, "enabled" => true}))
    assert %{job_token_keys: nil} = Auth.load_settings()
    refute File.exists?(JobTokens.file())
  end
end
