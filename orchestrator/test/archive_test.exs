defmodule Testor.ArchiveTest.S3 do
  @moduledoc "An S3 API (and STS) for the tests: keeps what is put, hands each request to the test."
  use Plug.Router
  plug(:match)
  plug(:dispatch)

  put _ do
    {:ok, body, conn} = read_all(conn, "")
    send(Application.fetch_env!(:testor, :s3_test), {:put, conn.request_path, conn.req_headers, body})

    case Application.get_env(:testor, :s3_status, 200) do
      200 -> send_resp(conn, 200, "")
      status -> send_resp(conn, status, "<Error><Code>SlowDown</Code></Error>")
    end
  end

  get "/sts" do
    conn = fetch_query_params(conn)
    send(Application.fetch_env!(:testor, :s3_test), {:sts, conn.query_params})

    send_resp(conn, 200, """
    <AssumeRoleWithWebIdentityResponse><AssumeRoleWithWebIdentityResult><Credentials>
    <AccessKeyId>ASIAWEB</AccessKeyId><SecretAccessKey>websecret</SecretAccessKey>
    <SessionToken>websession</SessionToken><Expiration>2099-01-01T00:00:00Z</Expiration>
    </Credentials></AssumeRoleWithWebIdentityResult></AssumeRoleWithWebIdentityResponse>
    """)
  end

  get "/sts-empty" do
    send_resp(conn, 200, "<Nothing/>")
  end

  match _ do
    send_resp(conn, 404, "")
  end

  defp read_all(conn, acc) do
    case read_body(conn) do
      {:ok, data, conn} -> {:ok, acc <> data, conn}
      {:more, data, conn} -> read_all(conn, acc <> data)
    end
  end
end

defmodule Testor.ArchiveTest do
  @moduledoc "Finished runs archived to S3-compatible storage, signed and encrypted there."
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  import Testor.Test.Helpers
  alias Testor.{Archive, Config, Store}
  alias Testor.Archive.SigV4

  setup do
    pid = start_supervised!({Bandit, plug: Testor.ArchiveTest.S3, ip: :loopback, port: 0, startup_log: false})
    {:ok, {_, port}} = ThousandIsland.listener_info(pid)
    Application.put_env(:testor, :s3_test, self())
    Application.put_env(:testor, :archive_backoff, [10])
    System.put_env("AWS_ACCESS_KEY_ID", "AKIDTEST")
    System.put_env("AWS_SECRET_ACCESS_KEY", "secret")
    System.put_env("AWS_SESSION_TOKEN", "")

    on_exit(fn ->
      File.rm(Path.join(Config.data_dir(), "config.json"))

      for var <-
            ~w(AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_ROLE_ARN AWS_WEB_IDENTITY_TOKEN_FILE AWS_STS_ENDPOINT),
          do: System.delete_env(var)

      Archive.reset()
      Application.delete_env(:testor, :s3_test)
      Application.delete_env(:testor, :s3_status)
      Application.delete_env(:testor, :archive_backoff)
    end)

    %{endpoint: "http://127.0.0.1:#{port}"}
  end

  defp received_puts(acc) do
    receive do
      {:put, path, headers, body} -> received_puts([{path, headers, body} | acc])
    after
      200 -> acc
    end
  end

  defp archive(config),
    do: File.write!(Path.join(Config.data_dir(), "config.json"), JSON.encode!(%{"archive" => config}))

  test "SigV4 signs as AWS's own test suite says (get-vanilla)" do
    headers =
      SigV4.authorize(
        "GET",
        URI.parse("https://example.amazonaws.com/"),
        [],
        SigV4.hex(:crypto.hash(:sha256, "")),
        %{key: "AKIDEXAMPLE", secret: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"},
        "us-east-1",
        "service",
        ~U[2015-08-30 12:36:00Z],
        content_hash: false
      )

    assert {"authorization",
            "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, " <>
              "SignedHeaders=host;x-amz-date, " <>
              "Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31"} in headers

    assert SigV4.encode("a b/c~d") == "a%20b%2Fc~d"

    # A query is signed sorted and encoded; no path is "/"; a session token is signed too.
    creds = %{key: "AKID", secret: "s", token: "session"}
    now = ~U[2015-08-30 12:36:00Z]

    a =
      SigV4.authorize(
        "GET",
        URI.parse("https://h.example?b=2&a=1"),
        [],
        "UNSIGNED-PAYLOAD",
        creds,
        "r",
        "s3",
        now
      )

    b =
      SigV4.authorize(
        "GET",
        %URI{scheme: "https", host: "h.example", path: "", query: "a=1&b=2"},
        [],
        "UNSIGNED-PAYLOAD",
        creds,
        "r",
        "s3",
        now
      )

    assert List.keyfind(a, "authorization", 0) == List.keyfind(b, "authorization", 0)
    assert {"x-amz-security-token", "session"} in a
  end

  test "a finished run goes to the bucket: every file, its checksum, encrypted and locked", %{
    endpoint: endpoint
  } do
    archive(%{
      "bucket" => "evidence",
      "region" => "eu-west-1",
      "endpoint" => endpoint,
      "pathStyle" => true,
      "prefix" => "/runner-1/",
      "encryption" => "aws:kms",
      "kmsKeyId" => "arn:aws:kms:eu-west-1:1:key/k",
      "objectLock" => %{"mode" => "COMPLIANCE", "days" => 30}
    })

    # Running until its files are there: a run is archived once it ends and is signed.
    id = record(%{"project" => "archived"})
    log(id, "hello archive\n")
    shot = Path.join([Config.shots_dir(), id, "a b.png"])
    File.mkdir_p!(Path.dirname(shot))
    File.write!(shot, "PNG")
    on_exit(fn -> Store.delete(id) end)
    capture_log(fn -> finish(id, "passed") end)

    # Once archived, every object it put has arrived (a run may be archived twice: once is
    # enough, the same objects again).
    wait_until(fn -> Archive.archived?(id) end)
    puts = received_puts([])
    by_path = Map.new(puts, fn {path, headers, body} -> {path, {Map.new(headers), body}} end)

    assert Map.has_key?(by_path, "/evidence/runner-1/runs/#{id}.json")
    assert {log_headers, "hello archive\n"} = by_path["/evidence/runner-1/logs/#{id}.log"]
    assert Map.has_key?(by_path, "/evidence/runner-1/attestations/#{id}.dsse.json")
    assert {shot_headers, "PNG"} = by_path["/evidence/runner-1/screenshots/#{id}/a%20b.png"]

    assert log_headers["x-amz-checksum-sha256"] == Base.encode64(:crypto.hash(:sha256, "hello archive\n"))
    assert log_headers["x-amz-server-side-encryption"] == "aws:kms"
    assert log_headers["x-amz-server-side-encryption-aws-kms-key-id"] == "arn:aws:kms:eu-west-1:1:key/k"
    assert log_headers["x-amz-object-lock-mode"] == "COMPLIANCE"
    assert log_headers["x-amz-content-sha256"] == "UNSIGNED-PAYLOAD"
    assert log_headers["authorization"] =~ "AWS4-HMAC-SHA256 Credential=AKIDTEST/"
    refute Map.has_key?(log_headers, "x-amz-security-token")
    assert log_headers["content-type"] =~ "text/plain"
    assert shot_headers["content-type"] == "image/png"

    assert %{"bucket" => "evidence", "keys" => keys} = JSON.decode!(File.read!(Archive.manifest(id)))
    assert length(keys) == 4
    assert Testor.Views.run_snapshot(id)["run"]["archived"]
    assert Testor.Query.compact(Testor.Views.run_snapshot(id)["run"])["archived"]
  end

  test "virtual-hosted style, SSE-S3, credentials from a web identity", %{endpoint: endpoint} do
    token = Path.join(Config.data_dir(), "web-identity")
    File.write!(token, "eyJ.web.identity\n")
    System.delete_env("AWS_ACCESS_KEY_ID")
    System.put_env("AWS_ROLE_ARN", "arn:aws:iam::1:role/testor")
    System.put_env("AWS_WEB_IDENTITY_TOKEN_FILE", token)
    System.put_env("AWS_STS_ENDPOINT", endpoint <> "/sts")

    config = %{
      bucket: "b",
      region: "r",
      prefix: "",
      endpoint: endpoint,
      path_style: false,
      encryption: "AES256",
      kms_key_id: nil,
      lock: nil
    }

    file = Path.join(Config.data_dir(), "archive-me.txt")
    File.write!(file, "x")
    {:ok, creds} = Archive.credentials("r")

    assert_receive {:sts,
                    %{"RoleArn" => "arn:aws:iam::1:role/testor", "WebIdentityToken" => "eyJ.web.identity"}}

    assert %{key: "ASIAWEB", token: "websession"} = creds

    # A host of its own for the bucket: 127.0.0.1 has none, so the request fails, signed as such.
    assert {:error, "failed" <> _} = Archive.put(config, creds, "k", file)
    # Cached: STS is not asked again.
    assert {:ok, ^creds} = Archive.credentials("r")
    refute_receive {:sts, _}, 100
  end

  test "refusals and failures are tried again, then logged", %{endpoint: endpoint} do
    archive(%{
      "bucket" => "evidence",
      "region" => "r",
      "endpoint" => endpoint,
      "pathStyle" => true
    })

    Application.put_env(:testor, :s3_status, 503)
    System.put_env("AWS_SESSION_TOKEN", "a-session")
    id = record(%{"project" => "archived"})

    on_exit(fn ->
      # No archive is set up any more when it ends.
      File.rm(Path.join(Config.data_dir(), "config.json"))
      Store.settle(id, "cancelled")
      Store.delete(id)
    end)

    log =
      capture_log(fn ->
        assert {:error, why} = Archive.maybe(id)
        assert why =~ "answered 503: SlowDown"
      end)

    assert log =~ "could not be archived"
    refute Archive.archived?(id)

    System.delete_env("AWS_ACCESS_KEY_ID")
    capture_log(fn -> assert {:error, "no credentials" <> _} = Archive.maybe(id) end)

    System.put_env("AWS_ROLE_ARN", "arn")
    System.put_env("AWS_WEB_IDENTITY_TOKEN_FILE", "/nonexistent/token")
    capture_log(fn -> assert {:error, "cannot read" <> _} = Archive.maybe(id) end)
  end

  test "STS that refuses, answers nothing useful, or cannot be reached", %{endpoint: endpoint} do
    token = Path.join(Config.data_dir(), "web-identity")
    File.write!(token, "t")
    System.delete_env("AWS_ACCESS_KEY_ID")
    System.put_env("AWS_ROLE_ARN", "arn")
    System.put_env("AWS_WEB_IDENTITY_TOKEN_FILE", token)

    System.put_env("AWS_STS_ENDPOINT", endpoint <> "/nope")
    assert {:error, "STS answered 404"} = Archive.credentials("r")
    System.put_env("AWS_STS_ENDPOINT", "http://127.0.0.1:1")
    assert {:error, "STS cannot be reached" <> _} = Archive.credentials("r")
    System.put_env("AWS_STS_ENDPOINT", endpoint <> "/sts-empty")
    assert {:error, "STS's answer holds no credentials"} = Archive.credentials("r")
  end

  test "configuration" do
    assert Archive.config() == nil
    assert Archive.maybe("x") == :off

    log =
      capture_log(fn ->
        for bad <- [
              %{"bucket" => "No_Caps", "region" => "r"},
              %{"bucket" => "ok-bucket"},
              %{"bucket" => "ok-bucket", "region" => "r", "endpoint" => "ftp://x"},
              %{"bucket" => "ok-bucket", "region" => "r", "encryption" => "rot13"},
              %{
                "bucket" => "ok-bucket",
                "region" => "r",
                "objectLock" => %{"mode" => "FOREVER", "days" => 1}
              },
              "yes"
            ] do
          archive(bad)
          assert Archive.config() == nil, inspect(bad)
        end
      end)

    assert log =~ "runs are not archived"
    archive(%{"bucket" => "ok-bucket", "region" => "eu-north-1"})

    assert %{endpoint: "https://s3.eu-north-1.amazonaws.com", prefix: "", path_style: false} =
             Archive.config()
  end
end
