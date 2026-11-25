defmodule Testor.GatesTest do
  @moduledoc "Release gates: whether a commit may ship, from its runs' signed results."
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn
  import ExUnit.CaptureLog
  import Testor.Test.Helpers
  alias Testor.{Attestation, Config, Files, Gates, Store}
  alias Testor.Auth.{Guard, Password}
  alias Testor.Web.Router

  @commit "3f4e006a1b2c3d4e5f60718293a4b5c6d7e8f901"
  @password "correct horse battery"

  setup do
    Guard.reset()

    on_exit(fn ->
      File.rm(Path.join(Config.data_dir(), "config.json"))
      Application.delete_env(:testor, :auth)
    end)
  end

  defp gates(gates), do: File.write!(Path.join(Config.data_dir(), "config.json"), JSON.encode!(%{"gates" => gates}))

  # A finished run of `kind` at `commit`, signed by testor once it is in the store.
  defp signed_run(kind, status, extra \\ %{}) do
    source = Map.merge(%{"commit" => @commit, "dirty" => false}, extra["source"] || %{})
    id = record(Map.merge(%{"project" => "web", "kind" => kind, "source" => source}, Map.delete(extra, "source")))
    on_exit(fn -> Store.delete(id) end)
    capture_log(fn -> finish(id, status) end)
    wait_until(fn -> Attestation.exists?(id) end)
    id
  end

  defp gate(extra \\ %{}), do: Map.merge(%{"name" => "web-release", "project" => "web", "kinds" => ["test"]}, extra)
  defp result(gate, commit \\ @commit), do: Gates.evaluate(gate, commit) |> elem(1)

  test "passes when each kind's latest run of the commit passed and its attestation holds" do
    test_run = signed_run("test", "passed")
    e2e = signed_run("e2e", "passed")

    assert %{"pass" => true, "commit" => @commit, "checks" => [test_check, %{"kind" => "e2e", "runId" => ^e2e}]} =
             result(gate(%{"kinds" => ["test", "e2e"]}))

    assert %{"kind" => "test", "pass" => true, "runId" => ^test_run, "status" => "passed", "attestation" => "/api/v1/runs/" <> _} =
             test_check

    refute Map.has_key?(test_check, "reason")
    # A prefix of the commit is enough; another commit has no run.
    assert %{"pass" => true} = result(gate(), String.slice(@commit, 0, 10))
    assert %{"pass" => false, "checks" => [%{"reason" => "no finished run" <> _}]} = result(gate(), "abcdef0")
  end

  test "fails on the latest run: failed, from a dirty tree (not counted), too old, unsigned, tampered" do
    signed_run("test", "passed")
    failed = signed_run("test", "failed")
    assert %{"pass" => false, "checks" => [%{"runId" => ^failed, "reason" => reason}]} = result(gate())
    assert reason =~ "failed"

    # A dirty tree's run does not count: the failed run is still the latest one.
    signed_run("test", "passed", %{"source" => %{"dirty" => true}})
    assert %{"checks" => [%{"runId" => ^failed}]} = result(gate())

    passed = signed_run("test", "passed")
    assert %{"pass" => true} = result(gate())
    assert %{"checks" => [%{"reason" => "its latest run ended more than 1 hours ago"}]} =
             Gates.evaluate(gate(%{"maxAgeHours" => 1}), @commit, DateTime.add(DateTime.utc_now(), 7200)) |> elem(1)

    assert Gates.too_old?(1, "not a time", DateTime.utc_now())

    # The agent's signature, when the gate wants it.
    assert %{"checks" => [%{"reason" => "its latest run is not signed by its agent"}]} =
             result(gate(%{"requireAgentSignature" => true}))

    :ets.insert(:testor_runs, {passed, Map.put(Store.get(passed), "agentAttested", true)})
    assert %{"pass" => true} = result(gate(%{"requireAgentSignature" => true}))

    # testor's own attestation: checked again with its key, not taken from a flag.
    envelope = File.read!(Attestation.file(passed))
    File.write!(Attestation.file(passed), String.replace(envelope, "\"sig\":\"", "\"sig\":\"AA"))
    assert %{"checks" => [%{"reason" => "its attestation does not hold"}]} = result(gate())

    File.rm!(Attestation.file(passed))
    assert %{"checks" => [%{"reason" => "its latest run is not signed by testor"}]} = result(gate())

    # A signature that holds, of another commit, or of the run as failed.
    run = Store.get(passed)

    for {signed, reason} <- [
          {put_in(run, ["source", "commit"], "abcdef0123"), "does not name this commit"},
          {Map.put(run, "status", "failed"), "does not sign this run as passed"}
        ] do
      Files.write_json(Attestation.file(passed), signed |> Attestation.statement() |> Attestation.sign())
      assert %{"checks" => [%{"reason" => text}]} = result(gate())
      assert text =~ reason
    end
  end

  test "configuration, and over HTTP for the projects one sees" do
    gates(%{
      "web-release" => %{"project" => "web", "kinds" => ["test"], "maxAgeHours" => 24, "requireAgentSignature" => false},
      "secret" => %{"project" => "secret", "kinds" => ["test"]},
      "a" => %{"project" => "a b", "kinds" => ["t"]},
      "b" => %{"project" => "b", "kinds" => []},
      "c" => %{"project" => "c", "kinds" => ["t"], "requireAgentSignature" => "yes"},
      "d" => %{"project" => "d", "kinds" => ["t"], "maxAgeHours" => -1},
      "e" => "nope"
    })

    listed = Map.new(Gates.list(), &{&1["name"], &1})
    assert %{"project" => "web", "kinds" => ["test"], "maxAgeHours" => 24} = listed["web-release"]

    for {name, why} <- [{"a", "project"}, {"b", "kinds"}, {"c", "requireAgentSignature"}, {"d", "maxAgeHours"}, {"e", "an object"}] do
      assert listed[name]["error"] =~ why
      assert {:error, _} = Gates.get(name)
    end

    assert Gates.get("nope") == {:error, :not_found}
    assert {:error, "commit is" <> _} = Gates.evaluate(gate(), "main")
    assert {:error, _} = Gates.evaluate(gate(), nil)

    hash = Password.hash(@password, 1000)
    Application.put_env(:testor, :auth, %{"users" => %{"web" => %{"password" => hash, "projects" => ["web", "a"]}}})
    get = fn path -> conn(:get, path) |> put_req_header("authorization", "Basic " <> Base.encode64("web:#{@password}")) |> Router.call(Router.init([])) end

    assert %{"data" => data} = get.("/api/v1/gates").resp_body |> JSON.decode!()
    assert Enum.map(data, & &1["name"]) == ["web-release"]
    assert %{"gate" => "web-release", "pass" => false} = get.("/api/v1/gates/web-release?commit=#{@commit}").resp_body |> JSON.decode!()
    assert get.("/api/v1/gates/web-release?commit=main").status == 400
    assert get.("/api/v1/gates/secret?commit=#{@commit}").status == 404
    assert get.("/api/v1/gates/nope?commit=#{@commit}").status == 404
    assert get.("/api/v1/gates/a?commit=#{@commit}").status == 400

    File.write!(Path.join(Config.data_dir(), "config.json"), JSON.encode!(%{"gates" => ["x"]}))
    assert Gates.list() == []
  end
end
