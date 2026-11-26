defmodule Testor.AccessTest do
  @moduledoc "Per-project access: users limited to projects see, stream and act on those only."
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn
  import ExUnit.CaptureIO
  import ExUnit.CaptureLog
  import Testor.Test.Helpers
  alias Testor.{Access, Auth, Config, Jobs, Store}
  alias Testor.Auth.{Guard, Password}
  alias Testor.Web.Router

  @password "correct horse battery"
  @opts Router.init([])

  setup_all do
    hash = Password.hash(@password, 1000)

    users = %{
      "ada" => %{"password" => hash, "role" => "admin"},
      "web" => %{"password" => hash, "role" => "operator", "projects" => ["web*"]},
      "webadm" => %{"password" => hash, "role" => "admin", "projects" => ["web-app"]},
      "bot" => %{"password" => hash, "role" => "agent", "projects" => ["web-app"]},
      "nobody" => %{"password" => hash, "role" => "viewer", "projects" => "web-app"},
      "every" => %{"password" => hash, "role" => "viewer", "projects" => nil}
    }

    %{users: users}
  end

  setup %{users: users} do
    Guard.reset()
    Application.put_env(:testor, :auth, %{"users" => users})
    Jobs.reset()

    File.write!(
      Path.join(Config.data_dir(), "config.json"),
      JSON.encode!(%{"execution" => %{"enabled" => true}})
    )

    web = record(%{"project" => "web-app", "status" => "passed"})
    secret = record(%{"project" => "secret-app", "status" => "passed"})

    for {id, name} <- [{web, "w.png"}, {secret, "s.png"}] do
      path = Path.join([Config.shots_dir(), id, name])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "png")
    end

    on_exit(fn ->
      Store.delete(web)
      Store.delete(secret)
      File.rm(Path.join(Config.data_dir(), "config.json"))
      Jobs.reset()
      Application.delete_env(:testor, :auth)
    end)

    %{web: web, secret: secret}
  end

  defp as(conn, user),
    do: put_req_header(conn, "authorization", "Basic " <> Base.encode64("#{user}:#{@password}"))

  defp get(path, user), do: conn(:get, path) |> as(user) |> Router.call(@opts)

  defp post(path, body, user) do
    conn(:post, path, JSON.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> as(user)
    |> Router.call(@opts)
  end

  defp body(conn), do: JSON.decode!(conn.resp_body)
  defp projects_in(list), do: list |> Enum.map(& &1["project"]) |> Enum.uniq() |> Enum.sort()

  describe "the rules" do
    test "patterns, filters and events" do
      web = %{projects: ["web*", "api"]}
      assert Access.allowed?(web, "web-app") and Access.allowed?(web, "api")
      refute Access.allowed?(web, "apis") or Access.allowed?(web, nil) or Access.allowed?(web, "my-web")
      assert Access.allowed?(%{projects: nil}, "anything") and Access.allowed?(nil, "x")
      refute Access.restricted?(Auth.anonymous())
      assert Access.filter([%{"project" => "web"}, %{"project" => "x"}], web) == [%{"project" => "web"}]

      assert Access.valid_pattern?("lib-*") and not Access.valid_pattern?("a b") and
               not Access.valid_pattern?(5)

      assert Access.event?(web, "run", %{"project" => "web-1"})
      refute Access.event?(web, "job", %{"project" => "x"})
      refute Access.event?(web, "sessions", [])
      refute Access.event?(web, "maintenance", %{})
      assert Access.event?(web, "device", %{})
      assert Access.event?(%{projects: nil}, "sessions", [])
      refute Access.event?(web, "live", %{"id" => "nope"})
      assert Access.init(a: 1) == [a: 1]
    end

    test "auth.json: a list that cannot be read fails closed; null means every project" do
      log =
        capture_log(fn ->
          settings = Auth.settings()
          assert settings.users["nobody"].projects == []
          assert settings.users["every"].projects == nil
          assert settings.users["web"].projects == ["web*"]
        end)

      assert log =~ "nobody has projects that are not names or patterns"
    end
  end

  describe "over HTTP" do
    test "lists leave out the others", %{web: web, secret: secret} do
      assert %{"data" => runs} = get("/api/v1/runs", "web") |> body()
      assert web in Enum.map(runs, & &1["id"]) and secret not in Enum.map(runs, & &1["id"])

      assert projects_in(get("/api/v1/projects", "web") |> body() |> Map.fetch!("data"))
             |> Enum.all?(&String.starts_with?(&1, "web"))

      assert get("/api/v1/screenshots", "web") |> body() |> Map.fetch!("data") |> projects_in() == ["web-app"]
      assert get("/api/screenshots", "web") |> body() |> projects_in() == ["web-app"]

      assert get("/api/v1/artifacts", "web")
             |> body()
             |> Map.fetch!("data")
             |> Enum.all?(&(&1["project"] == "web-app"))

      assert get("/api/artifacts", "web").status == 200

      state = get("/api/state", "web") |> body()
      assert state["history"] |> projects_in() |> Enum.all?(&String.starts_with?(&1, "web"))
      assert state["sessions"] == []
      refute Map.has_key?(state, "maintenance")

      # Unrestricted users see everything.
      assert %{"data" => all} = get("/api/v1/runs", "ada") |> body()
      assert secret in Enum.map(all, & &1["id"])
      assert %{"projects" => nil} = get("/api/v1/auth/me", "ada") |> body()
      assert %{"projects" => ["web*"]} = get("/api/v1/auth/me", "web") |> body()
    end

    test "another project's run, files and streams do not exist", %{web: web, secret: secret} do
      for path <- [
            "/api/v1/runs/#{secret}",
            "/api/v1/runs/#{secret}/log",
            "/api/v1/runs/#{secret}/attestation",
            "/api/runs/#{secret}",
            "/api/runs/#{secret}/log",
            "/events/runs/#{secret}",
            "/shots/#{secret}/s.png",
            "/artifacts/#{secret}/x",
            "/api/v1/projects/secret-app/flaky"
          ] do
        assert get(path, "web").status == 404, path
      end

      assert get("/api/v1/runs/#{web}", "web").status == 200
      assert get("/shots/#{web}/w.png", "web").status == 200
      # Something that does not exist is the route's own 404.
      assert get("/api/v1/runs/nope", "web").status == 404
      assert post("/api/runs/#{secret}/cancel", %{}, "web").status == 404
    end

    test "what spans every project needs access to every project" do
      for {path, user} <- [
            {"/metrics", "web"},
            {"/api/maintenance", "webadm"},
            {"/api/v1/maintenance", "webadm"},
            {"/api/v1/audit", "webadm"},
            {"/api/v1/agents", "web"},
            {"/api/v1/sessions", "web"}
          ] do
        conn = get(path, user)
        assert conn.status == 403, path
        error = body(conn)["error"]

        assert (is_map(error) and error["code"] == "every_project") or
                 (is_binary(error) and error =~ "every project"),
               path
      end

      assert post("/api/cleanup", %{}, "webadm").status == 403
      assert get("/metrics", "ada").status == 200
    end

    test "jobs: queued, listed, cancelled and taken within one's projects" do
      assert %{status: 403} = post("/api/v1/jobs", %{"project" => "secret-app", "kind" => "test"}, "webadm")

      assert %{status: 201} =
               mine = post("/api/v1/jobs", %{"project" => "web-app", "kind" => "test"}, "webadm")

      {:ok, theirs} = Jobs.enqueue(%{"project" => "secret-app", "kind" => "test"}, "ada")

      assert get("/api/v1/jobs", "webadm") |> body() |> Map.fetch!("data") |> projects_in() == ["web-app"]
      assert get("/api/v1/jobs/#{theirs["id"]}", "webadm").status == 404
      assert post("/api/v1/jobs/#{theirs["id"]}/cancel", %{}, "webadm").status == 404

      # An agent limited to web-app never takes secret-app's job, though it is older.
      assert %{status: 200} = leased = post("/api/v1/agent/lease", %{}, "bot")
      assert body(leased)["id"] == body(mine)["id"]
      assert post("/api/v1/agent/lease", %{}, "bot").status == 204
    end

    test "a user whose projects cannot be read sees no runs" do
      capture_log(fn -> assert %{"data" => []} = get("/api/v1/runs", "nobody") |> body() end)
    end
  end

  test "the live stream leaves out the others' events", %{web: _} do
    socket = stream("/events", [{"authorization", "Basic " <> Base.encode64("web:#{@password}")}])
    [{"snapshot", snapshot} | _] = events(socket, "snapshot")
    assert snapshot["history"] |> projects_in() |> Enum.all?(&String.starts_with?(&1, "web"))

    hidden = record(%{"project" => "secret-app"})
    shown = record(%{"project" => "web-app"})
    on_exit(fn -> for id <- [hidden, shown], do: Store.settle(id, "cancelled") && Store.delete(id) end)

    received = events(socket, "run")
    close(socket)
    ids = for {"run", run} <- received, do: run["id"]
    assert shown in ids
    refute hidden in ids
  end

  test "MCP's tools see the principal's projects only", %{web: web, secret: secret} do
    principal = %{sub: "web", scopes: ["read", "operate"], via: :bearer, projects: ["web*"]}
    call = fn name, args -> Testor.MCP.Tools.call(name, args, principal, "http://x") |> elem(1) end

    assert %{"isError" => true, "content" => [%{"text" => "no run " <> _}]} =
             call.("get_run", %{"id" => secret})

    assert %{"isError" => true} = call.("get_run_log", %{"id" => secret})
    assert %{"isError" => true} = call.("cancel_run", %{"id" => secret})
    assert %{"isError" => false} = call.("get_run", %{"id" => web})
    assert %{"structuredContent" => %{"runs" => runs}} = call.("list_runs", %{})
    refute secret in Enum.map(runs, & &1["id"])
    assert %{"structuredContent" => %{"projects" => projects, "sessions" => []}} = call.("get_status", %{})
    assert projects |> projects_in() |> Enum.all?(&String.starts_with?(&1, "web"))
    assert %{"structuredContent" => %{"projects" => listed}} = call.("list_projects", %{})
    refute "secret-app" in projects_in(listed)

    assert %{"structuredContent" => %{"flaky" => []}} =
             call.("find_flaky_specs", %{"project" => "secret-app"})
  end

  test "the CLI sets a user's projects" do
    Application.delete_env(:testor, :auth)
    System.put_env("TESTOR_PASSWORD", @password)

    on_exit(fn ->
      System.delete_env("TESTOR_PASSWORD")
      File.rm(Auth.auth_file())
      :persistent_term.erase({Auth, :settings})
    end)

    capture_io(fn -> Testor.Auth.CLI.user("cleo", "viewer") end)
    assert capture_io(fn -> Testor.Auth.CLI.projects("cleo", "web lib-*") end) =~ "cleo sees web, lib-*"
    assert Auth.read_raw()["users"]["cleo"]["projects"] == ["web", "lib-*"]
    assert capture_io(fn -> Testor.Auth.CLI.projects("cleo", "all") end) =~ "every project"
    refute Map.has_key?(Auth.read_raw()["users"]["cleo"], "projects")
    assert_raise Testor.Auth.CLI.Error, fn -> Testor.Auth.CLI.projects("cleo", "a b!") end
    assert_raise Testor.Auth.CLI.Error, fn -> Testor.Auth.CLI.projects("cleo", " ") end
    assert_raise Testor.Auth.CLI.Error, fn -> Testor.Auth.CLI.projects("ghost", "web") end
  end
end
