defmodule Testor.ProjectRolesTest do
  @moduledoc "A role per project: what a user may do depends on the project a request touches."
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

  setup do
    Guard.reset()
    Jobs.reset()

    File.write!(
      Path.join(Config.data_dir(), "config.json"),
      JSON.encode!(%{"execution" => %{"enabled" => true}})
    )

    hash = Password.hash(@password, 1000)

    users = %{
      "mixed" => %{
        "password" => hash,
        "role" => "admin",
        "projects" => %{
          "web*" => "operator",
          "docs" => "viewer",
          "lib" => "agent",
          "bad pattern" => "viewer",
          "x" => "owner"
        }
      },
      "lead" => %{"password" => hash, "projects" => %{"web*" => "admin", "docs" => "viewer"}}
    }

    capture_log(fn -> Application.put_env(:testor, :auth, %{"users" => users}) end)

    runs =
      for project <- ["web-app", "docs", "lib", "secret-app"], into: %{} do
        {project, record(%{"project" => project, "status" => "passed"})}
      end

    on_exit(fn ->
      Enum.each(Map.values(runs), &Store.delete/1)
      File.rm(Path.join(Config.data_dir(), "config.json"))
      Jobs.reset()
      Application.delete_env(:testor, :auth)
    end)

    %{runs: runs}
  end

  defp as(conn, user),
    do: put_req_header(conn, "authorization", "Basic " <> Base.encode64("#{user}:#{@password}"))

  defp request(method, path, user, body \\ nil) do
    conn(method, path, body && JSON.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> as(user)
    |> Router.call(@opts)
  end

  defp body(conn), do: JSON.decode!(conn.resp_body)

  test "auth.json: a role per pattern; entries that are not valid are left out" do
    log =
      capture_log(fn ->
        user = Auth.settings().users["mixed"]

        assert Enum.map(user.project_roles, &{&1.pattern, &1.role}) == [
                 {"docs", "viewer"},
                 {"lib", "agent"},
                 {"web*", "operator"}
               ]

        assert Enum.sort(user.scopes) == ["agent", "operate", "read"]
        assert user.projects == ["docs", "lib", "web*"]
      end)

    assert log =~ "project roles that are not valid"

    assert %{"projectRoles" => %{"web*" => "operator", "docs" => "viewer"}} =
             request(:get, "/api/v1/auth/me", "mixed") |> body()
  end

  test "lists show what a role may read", %{runs: runs} do
    %{"data" => listed} = request(:get, "/api/v1/runs", "mixed") |> body()
    ids = Enum.map(listed, & &1["id"])
    assert runs["web-app"] in ids and runs["docs"] in ids
    # An agent role reads nothing; another project is not there at all.
    refute runs["lib"] in ids or runs["secret-app"] in ids
    assert request(:get, "/api/v1/runs/#{runs["lib"]}", "mixed").status == 404
  end

  test "acting on a run needs the scope on its project", %{runs: runs} do
    conn = request(:delete, "/api/v1/runs/#{runs["docs"]}", "mixed")
    assert conn.status == 403
    assert body(conn)["error"]["message"] =~ "lacks the operate scope on that project"
    assert request(:get, "/api/v1/runs/#{runs["docs"]}", "mixed").status == 200
    assert request(:delete, "/api/v1/runs/#{runs["web-app"]}", "mixed").status in 200..299
  end

  test "jobs: queued where the role executes, taken where it is an agent" do
    assert request(:post, "/api/v1/jobs", "lead", %{"project" => "web-app", "kind" => "test"}).status == 201
    assert request(:post, "/api/v1/jobs", "lead", %{"project" => "docs", "kind" => "test"}).status == 403

    {:ok, web} = Jobs.enqueue(%{"project" => "web-app", "kind" => "test"}, "ada")
    {:ok, lib} = Jobs.enqueue(%{"project" => "lib", "kind" => "test"}, "ada")
    leased = request(:post, "/api/v1/agent/lease", "mixed", %{})
    assert body(leased)["id"] == lib["id"]
    assert request(:post, "/api/v1/agent/lease", "mixed", %{}).status == 204
    assert Jobs.get(web["id"])["status"] == "queued"
  end

  test "MCP's tools", %{runs: runs} do
    principal = %{sub: "mixed", scopes: ["read", "operate"], via: :bearer, projects: ["docs", "web*"]}

    principal =
      Map.put(principal, :project_roles, [
        %{pattern: "docs", role: "viewer", scopes: ["read"]},
        %{pattern: "web*", role: "operator", scopes: ["read", "operate"]}
      ])

    call = fn name, args -> Testor.MCP.Tools.call(name, args, principal, "http://x") |> elem(1) end
    assert %{"isError" => false} = call.("get_run", %{"id" => runs["docs"]})

    assert %{"isError" => true, "content" => [%{"text" => text}]} =
             call.("cancel_run", %{"id" => runs["docs"]})

    assert text =~ "lacks the operate scope on docs"
  end

  test "permits? without roles per project" do
    assert Access.permits?(%{scopes: ["read"]}, "any", "read")
    refute Access.permits?(%{scopes: ["read"]}, "any", "operate")
    refute Access.permits?(%{scopes: ["read"], projects: ["web"]}, "docs", "read")

    refute Access.permits?(
             %{scopes: ["read"], project_roles: [%{pattern: "web", scopes: ["read"]}]},
             nil,
             "read"
           )
  end

  test "the CLI sets a role per project" do
    Application.delete_env(:testor, :auth)
    System.put_env("TESTOR_PASSWORD", @password)

    on_exit(fn ->
      System.delete_env("TESTOR_PASSWORD")
      File.rm(Auth.auth_file())
      :persistent_term.erase({Auth, :settings})
    end)

    capture_io(fn -> Testor.Auth.CLI.user("cleo", "viewer") end)

    assert capture_io(fn -> Testor.Auth.CLI.projects("cleo", "web*=operator docs=viewer") end) =~
             "cleo is viewer on docs, operator on web*"

    assert Auth.read_raw()["users"]["cleo"]["projects"] == %{"web*" => "operator", "docs" => "viewer"}

    assert_raise Testor.Auth.CLI.Error, ~r/pattern=role/, fn ->
      Testor.Auth.CLI.projects("cleo", "web=owner")
    end

    assert_raise Testor.Auth.CLI.Error, ~r/pattern=role/, fn ->
      Testor.Auth.CLI.projects("cleo", "a b=viewer")
    end
  end
end
