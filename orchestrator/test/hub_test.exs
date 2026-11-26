defmodule Testor.HubTest.Remote do
  @moduledoc "Other testors for the hub's tests: how each answers depends on the path's first segment."
  use Plug.Router
  plug(:match)
  plug(:dispatch)

  get "/:kind/api/v1/health" do
    send(Application.fetch_env!(:testor, :hub_test), {:asked, kind, get_req_header(conn, "authorization")})
    if kind == "slow", do: Process.sleep(400)
    send_resp(conn, 200, ~s({"ok": true, "version": "0.11.0"}))
  end

  get "/:kind/api/v1/projects" do
    case kind do
      "ok" ->
        body =
          ~s({"data": [{"project": "web", "kind": "test", "latest": {"id": "20261126-1 x", "status": "passed", "endedAt": "2026-11-26T01:00:00Z"}, "recent": ["passed"]},
                            {"project": "secret", "kind": "test", "latest": {"id": "r2", "status": "failed"}, "recent": []},
                            {"project": "fresh", "kind": "lint"}]})

        send_resp(conn, 200, body)

      "broken" ->
        send_resp(conn, 500, "")

      "html" ->
        send_resp(conn, 200, "<html>")

      "shape" ->
        send_resp(conn, 200, ~s({"data": "nope"}))

      # Each answer within its own time, both together not.
      "slow" ->
        Process.sleep(400) && send_resp(conn, 200, ~s({"data": []}))
    end
  end
end

defmodule Testor.HubTest do
  @moduledoc "The hub: the board of other testors."
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  import Plug.Test
  import Plug.Conn
  alias Testor.{Config, Hub}
  alias Testor.Auth.{Guard, Password}
  alias Testor.Web.Router

  @password "correct horse battery"

  setup do
    pid = start_supervised!({Bandit, plug: Testor.HubTest.Remote, ip: :loopback, port: 0, startup_log: false})
    {:ok, {_, port}} = ThousandIsland.listener_info(pid)
    Application.put_env(:testor, :hub_test, self())
    # Each request has 600 ms, a testor 700 ms for both: the slow one (400 ms each) misses the
    # second, with room for slow CI machines either way.
    Application.put_env(:testor, :hub_timeout_ms, 600)
    Guard.reset()

    on_exit(fn ->
      File.rm(Hub.file())
      System.delete_env("LAB_TOKEN")
      Application.delete_env(:testor, :hub_test)
      Application.delete_env(:testor, :hub_timeout_ms)
      Application.delete_env(:testor, :auth)
      Hub.refresh()
    end)

    %{base: "http://127.0.0.1:#{port}"}
  end

  defp hub(testors, extra \\ %{}),
    do: File.write!(Hub.file(), JSON.encode!(Map.put(extra, "testors", testors)))

  test "each testor's latest results, with links back; one that fails says why", %{base: base} do
    System.put_env("LAB_TOKEN", "lab-token")

    hub([
      %{"name" => "farm", "url" => base <> "/ok/", "token" => "farm-token", "labels" => ["windows", 5]},
      %{"name" => "lab", "url" => base <> "/broken", "tokenEnv" => "LAB_TOKEN", "labels" => ["linux"]},
      %{"name" => "html", "url" => base <> "/html", "token" => "t"},
      %{"name" => "shape", "url" => base <> "/shape", "token" => "t", "labels" => "x"},
      %{"name" => "slow", "url" => base <> "/slow", "token" => "t"},
      %{"name" => "gone", "url" => "https://hub-test.invalid", "token" => "t"}
    ])

    :ok = Hub.refresh()
    assert_received {:asked, "ok", ["Bearer farm-token"]}
    assert_received {:asked, "broken", ["Bearer lab-token"]}

    [farm, lab, html, shape, slow, gone] = Hub.board()

    assert %{"ok" => true, "version" => "0.11.0", "labels" => ["windows"], "projects" => [web, _, fresh]} =
             farm

    assert %{"project" => "web", "status" => "passed", "recent" => ["passed"]} = web
    assert web["link"] == base <> "/ok/#/run/20261126-1+x"
    assert %{"status" => nil, "link" => nil, "recent" => []} = fresh

    assert %{"ok" => false, "error" => "/api/v1/projects answered 500", "projects" => []} = lab
    assert html["error"] =~ "did not answer JSON"
    assert shape["error"] =~ "not a list" and shape["labels"] == []
    assert slow["error"] =~ "in time"
    assert gone["error"] =~ "cannot be reached"

    assert [%{"name" => "farm"}] = Hub.board("windows")
    assert length(Hub.board("")) == 6
  end

  test "testors that cannot be used are left out; no hub.json, no hub", %{base: base} do
    log =
      capture_log(fn ->
        hub(
          [
            %{"name" => "bad name", "url" => base, "token" => "t"},
            %{"name" => "plain", "url" => "http://lab.example.com", "token" => "t"},
            %{"name" => "allowed", "url" => "http://lab.example.com", "token" => "t", "allowHttp" => true},
            %{"name" => "notoken", "url" => base},
            %{"url" => base}
          ],
          %{"intervalSeconds" => 1}
        )

        assert %{interval: 5, testors: [%{name: "allowed"}]} = Hub.config()
      end)

    assert log =~ "bad name is left out" and log =~ "notoken is left out" and log =~ "has a name and a url"
    File.write!(Hub.file(), ~s({"testors": []}))
    assert Hub.config() == nil
    File.rm!(Hub.file())
    :ok = Hub.refresh()
    assert Hub.board() == nil

    send(Hub, :poll)
    send(Hub, :unexpected)
    assert Hub.board() == nil
  end

  test "over HTTP: the projects one may see; 404 without a hub", %{base: base} do
    hash = Password.hash(@password, 1000)
    Application.put_env(:testor, :auth, %{"users" => %{"ci" => %{"password" => hash, "projects" => ["web"]}}})

    get = fn path ->
      conn(:get, path)
      |> put_req_header("authorization", "Basic " <> Base.encode64("ci:#{@password}"))
      |> Router.call(Router.init([]))
    end

    :ok = Hub.refresh()
    assert get.("/api/v1/hub").status == 404

    hub([%{"name" => "farm", "url" => base <> "/ok", "token" => "t", "labels" => ["windows"]}])
    :ok = Hub.refresh()

    assert %{"data" => [%{"projects" => [%{"project" => "web"}]}]} =
             get.("/api/v1/hub?label=windows").resp_body |> JSON.decode!()

    assert %{"data" => []} = get.("/api/v1/hub?label=mac").resp_body |> JSON.decode!()
  end
end
