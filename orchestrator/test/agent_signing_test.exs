defmodule Testor.AgentSigningTest do
  @moduledoc "Agents' own signatures: keys pinned on lease, attestations checked against the files received."
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn
  import ExUnit.CaptureIO
  import Testor.Test.Helpers
  alias Testor.{AgentKeys, Config, Jobs, Remote, Store}
  alias Testor.Auth.{Guard, Password}
  alias Testor.Web.Router

  @password "correct horse battery"
  @opts Router.init([])
  @p256 {1, 2, 840, 10045, 3, 1, 7}
  @type_ "application/vnd.in-toto+json"

  setup do
    Guard.reset()
    :sys.replace_state(Jobs, fn _ -> %{} end)
    File.rm(AgentKeys.file())

    File.write!(
      Path.join(Config.data_dir(), "config.json"),
      JSON.encode!(%{"execution" => %{"enabled" => true}})
    )

    hash = Password.hash(@password, 1000)

    Application.put_env(:testor, :auth, %{
      "users" => %{
        "ada" => %{"password" => hash, "role" => "admin"},
        "bot" => %{"password" => hash, "role" => "agent"},
        "bot2" => %{"password" => hash, "role" => "agent"}
      }
    })

    on_exit(fn ->
      File.rm(Path.join(Config.data_dir(), "config.json"))
      File.rm(AgentKeys.file())
      :sys.replace_state(Jobs, fn _ -> %{} end)
      Application.delete_env(:testor, :auth)
    end)

    %{key: key(), other: key()}
  end

  # An ECDSA key pair: the private key and the public key's SPKI PEM.
  defp key(curve \\ @p256) do
    private = :public_key.generate_key({:namedCurve, curve})

    spki =
      :public_key.pem_entry_encode(
        :SubjectPublicKeyInfo,
        {{:ECPoint, elem(private, 4)}, {:namedCurve, curve}}
      )

    {private, :public_key.pem_encode([spki])}
  end

  defp as(conn, user),
    do: put_req_header(conn, "authorization", "Basic " <> Base.encode64("#{user}:#{@password}"))

  defp call(method, path, body, user) do
    conn(method, path, JSON.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> as(user)
    |> Router.call(@opts)
  end

  defp body(conn), do: JSON.decode!(conn.resp_body)

  # A job leased by `agent` (presenting `pem`), its run recorded remotely with a log and files.
  defp remote_run(agent, pem) do
    {:ok, job} = Jobs.enqueue(%{"project" => "signed-#{agent}", "kind" => "test"}, "ada")
    lease = if pem, do: %{"key" => pem}, else: %{}
    assert %{status: 200} = call(:post, "/api/v1/agent/lease", lease, agent)
    run = run_id()
    on_exit(fn -> Store.settle(run, "cancelled") && Store.delete(run) end)
    record = %{"id" => run, "status" => "running", "startedAt" => DateTime.utc_now() |> DateTime.to_iso8601()}
    {:ok, _} = Remote.record(job["id"], agent, record)
    # The store has it before the test can end: its cleanup then settles it, leaving no run going.
    wait_until(fn -> Store.get(run) end)
    {:ok, _} = Remote.append_log(job["id"], agent, 0, "ok\n")
    {:ok, _} = Remote.put_file(job["id"], agent, "screenshots", ["a.png"], "png")
    {:ok, _} = Remote.put_file(job["id"], agent, "artifacts", ["r", "index.html"], "<html>")
    {job["id"], run}
  end

  defp digest(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)

  defp subjects do
    [
      %{"name" => "log", "digest" => %{"sha256" => digest("ok\n")}},
      %{"name" => "screenshots/a.png", "digest" => %{"sha256" => digest("png")}},
      %{"name" => "artifacts/r/index.html", "digest" => %{"sha256" => digest("<html>")}}
    ]
  end

  defp statement(run, job, subjects \\ subjects(), extra \\ %{}) do
    Map.merge(
      %{
        "_type" => "https://in-toto.io/Statement/v1",
        "subject" => subjects,
        "predicateType" => Remote.agent_predicate(),
        "predicate" => %{"run" => %{"id" => run, "job" => job, "status" => "passed"}, "agent" => "bot"}
      },
      extra
    )
  end

  defp envelope(statement, {private, _pem}) do
    payload = JSON.encode!(statement)
    pae = "DSSEv1 #{byte_size(@type_)} #{@type_} #{byte_size(payload)} " <> payload
    sig = :public_key.sign(pae, :sha256, private)

    %{
      "payloadType" => @type_,
      "payload" => Base.encode64(payload),
      "signatures" => [%{"keyid" => "k", "sig" => Base.encode64(sig)}]
    }
  end

  defp attest(job, env, user \\ "bot") do
    conn(:put, "/api/v1/agent/jobs/#{job}/attestation", JSON.encode!(env))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-testor", "1")
    |> as(user)
    |> Router.call(@opts)
  end

  test "the first key an agent presents is pinned; another one is refused until forgotten", %{
    key: {_, pem},
    other: {_, other}
  } do
    assert %{status: 204} = call(:post, "/api/v1/agent/lease", %{"key" => pem}, "bot")
    assert %{"bot" => %{"publicKey" => ^pem, "keyid" => keyid}} = AgentKeys.all()
    assert byte_size(keyid) == 64
    assert %{status: 204} = call(:post, "/api/v1/agent/lease", %{"key" => pem}, "bot")
    assert %{status: 403} = mismatch = call(:post, "/api/v1/agent/lease", %{"key" => other}, "bot")
    assert body(mismatch)["error"]["code"] == "key_mismatch"
    assert %{status: 400} = call(:post, "/api/v1/agent/lease", %{"key" => "not a key"}, "bot")
    assert %{status: 400} = call(:post, "/api/v1/agent/lease", %{"key" => 5}, "bot")
    {_, p384} = key({1, 3, 132, 0, 34})
    assert AgentKeys.pin("bot2", p384) == {:error, :bad_key}

    assert %{"data" => [%{"agent" => "bot", "keyid" => ^keyid}]} =
             conn(:get, "/api/v1/agents") |> as("ada") |> Router.call(@opts) |> body()

    assert capture_io(fn -> Testor.Auth.CLI.forget_agent_key("bot") end) =~ "forgotten"
    assert capture_io(fn -> Testor.Auth.CLI.forget_agent_key("bot") end) =~ "no pinned key"
    assert %{status: 204} = call(:post, "/api/v1/agent/lease", %{"key" => other}, "bot")
  end

  test "an agent's attestation of its run is kept when it holds, and shown", %{key: {_, pem} = key} do
    {job, run} = remote_run("bot", pem)
    assert %{status: 200} = ok = attest(job, envelope(statement(run, job), key))
    assert body(ok) == %{"subjects" => 3}

    wait_until(fn -> Store.get(run) end)

    assert %{"run" => %{"agentAttested" => true}} =
             conn(:get, "/api/v1/runs/#{run}") |> as("ada") |> Router.call(@opts) |> body()

    assert %{"payloadType" => @type_} =
             conn(:get, "/api/v1/runs/#{run}/attestation?by=agent")
             |> as("ada")
             |> Router.call(@opts)
             |> body()

    assert :ok = Store.settle(run, "cancelled") && Store.delete(run)
    refute File.exists?(Remote.agent_file(run))
  end

  test "attestations that do not hold are refused", %{key: {_, pem} = key, other: other} do
    {job, run} = remote_run("bot", pem)
    good = statement(run, job)
    code = &(attest(job, &1) |> body() |> get_in(["error", "code"]))

    assert code.(envelope(good, other)) == "signature"

    tampered =
      envelope(good, key)
      |> Map.put(
        "payload",
        Base.encode64(JSON.encode!(put_in(good, ["predicate", "run", "status"], "failed")))
      )

    assert code.(tampered) == "signature"

    assert code.(%{
             envelope(good, key)
             | "signatures" => [%{"sig" => "%%%"}, %{"sig" => Base.encode64("not der")}, %{}]
           }) == "signature"

    [log, shot, art] = subjects()
    assert code.(envelope(statement(run, job, [log, shot]), key)) == "files_differ"

    assert code.(
             envelope(
               statement(run, job, [
                 log,
                 shot,
                 art,
                 %{"name" => "artifacts/x", "digest" => %{"sha256" => "00"}}
               ]),
               key
             )
           ) == "files_differ"

    assert code.(
             envelope(
               statement(run, job, [log, shot, put_in(art, ["digest", "sha256"], digest("other"))]),
               key
             )
           ) == "files_differ"

    assert code.(envelope(statement(run, job, [log, shot, art, art]), key)) == "bad_request"
    assert code.(envelope(statement(run, job, "not a list"), key)) == "bad_request"
    assert code.(envelope(statement(run_id(), job), key)) == "bad_request"

    assert code.(envelope(statement(run, job, subjects(), %{"predicateType" => "other"}), key)) ==
             "bad_request"

    assert code.(%{"payloadType" => @type_}) == "bad_request"
    assert code.(%{envelope(good, key) | "payload" => "%%%"}) == "bad_request"

    bad =
      conn(:put, "/api/v1/agent/jobs/#{job}/attestation", "{nope")
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-testor", "1")
      |> as("bot")
      |> Router.call(@opts)

    assert bad.status == 400
  end

  test "an agent without a pinned key cannot attest; a key that no longer decodes is none", %{key: key} do
    {job, run} = remote_run("bot2", nil)
    assert %{status: 409} = conn = attest(job, envelope(statement(run, job), key), "bot2")
    assert body(conn)["error"]["code"] == "no_key"

    Testor.Files.write_json(AgentKeys.file(), %{
      "bot2" => %{"publicKey" => "-----BEGIN PUBLIC KEY-----\nAAAA\n-----END PUBLIC KEY-----\n"}
    })

    assert AgentKeys.get("bot2") == nil
    assert AgentKeys.decode(nil) == {:error, :bad_key}
  end
end
