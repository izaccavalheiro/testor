defmodule Testor.ApprovalsTest do
  @moduledoc "What an AI agent asks to do waits for a person's approval."
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn
  import Testor.Test.Helpers
  alias Testor.{Access, Approvals, Config, Store}
  alias Testor.Auth.{Guard, Password}
  alias Testor.MCP.Tools
  alias Testor.Web.Router

  @password "correct horse battery"
  @agent %{sub: "ai-agent", scopes: ["read", "operate"], via: :bearer}

  setup do
    Guard.reset()
    Approvals.reset()
    config(%{"tools" => ["delete_run", "cancel_run"], "ttlMinutes" => 10})
    hash = Password.hash(@password, 1000)

    Application.put_env(:testor, :auth, %{
      "users" => %{
        "ada" => %{"password" => hash, "role" => "operator"},
        "ai-agent" => %{"password" => hash, "role" => "operator"},
        "vic" => %{"password" => hash, "role" => "viewer"},
        "other" => %{"password" => hash, "role" => "operator", "projects" => ["other"]}
      }
    })

    id = record(%{"project" => "web", "status" => "passed"})

    on_exit(fn ->
      Store.delete(id)
      File.rm(Path.join(Config.data_dir(), "config.json"))
      Approvals.reset()
      Application.delete_env(:testor, :auth)
    end)

    %{run: id}
  end

  defp config(approvals),
    do: File.write!(Path.join(Config.data_dir(), "config.json"), JSON.encode!(%{"approvals" => approvals}))

  defp call(name, args, principal \\ @agent), do: Tools.call(name, args, principal, "http://x") |> elem(1)
  defp ask(id), do: call("delete_run", %{"id" => id})["structuredContent"]["approval"]

  defp as(conn, user),
    do: put_req_header(conn, "authorization", "Basic " <> Base.encode64("#{user}:#{@password}"))

  defp request(method, path, user) do
    conn(method, path) |> put_req_header("x-testor", "1") |> as(user) |> Router.call(Router.init([]))
  end

  test "asked, nothing done; another person approves; testor then does it as the agent", %{run: run} do
    result = call("delete_run", %{"id" => run})

    assert %{"isError" => false, "structuredContent" => %{"approval" => approval, "message" => message}} =
             result

    assert message =~ "needs a person's approval: nothing was done yet"

    assert %{"status" => "pending", "tool" => "delete_run", "project" => "web", "requestedBy" => "ai-agent"} =
             approval

    assert Store.get(run)

    # Not by the one who asked, nor by someone without the tool's scope.
    assert Approvals.decide(approval["id"], @agent, :approve) == {:error, :own}

    assert Approvals.decide(approval["id"], %{sub: "vic", scopes: ["read"]}, :approve) ==
             {:error, {:forbidden, "operate"}}

    assert {:ok, %{"status" => "done", "decidedBy" => "ada", "result" => %{"deleted" => _}}} =
             Approvals.decide(approval["id"], %{sub: "ada", scopes: ["read", "operate"]}, :approve)

    refute Store.get(run)
    assert Approvals.decide(approval["id"], %{sub: "ada", scopes: ["operate"]}, :deny) == {:error, :decided}

    assert Approvals.decide("approval-nope", %{sub: "ada", scopes: ["operate"]}, :deny) ==
             {:error, :not_found}

    # The agent reads the result.
    assert %{"structuredContent" => %{"status" => "done"}} = call("get_approval", %{"id" => approval["id"]})
  end

  test "denied, expired, failed", %{run: run} do
    denied = ask(run)

    assert {:ok, %{"status" => "denied"}} =
             Approvals.decide(denied["id"], %{sub: "ada", scopes: ["operate"]}, :deny)

    assert Store.get(run)

    expired = ask(run)
    Approvals.expire(expired["id"])
    assert [%{"status" => "expired"} | _] = Approvals.list("expired")
    assert Approvals.decide(expired["id"], %{sub: "ada", scopes: ["operate"]}, :approve) == {:error, :decided}

    # Approved, the tool can still fail (cancelling a run that has ended), and says so.
    late = call("cancel_run", %{"id" => run})["structuredContent"]["approval"]

    assert {:ok, %{"status" => "failed"}} =
             Approvals.decide(late["id"], %{sub: "ada", scopes: ["operate"]}, :approve)

    assert Approvals.get("approval-nope") == nil

    # Another testor sharing the queue decided first: it claimed the decision.
    raced = ask(run)
    assert Testor.Cluster.claim("approval", raced["id"])
    assert Approvals.decide(raced["id"], %{sub: "ada", scopes: ["operate"]}, :approve) == {:error, :decided}

    # An agent with a role per project: approved, it acts with its roles again.
    roles = [%{pattern: "web", role: "operator", scopes: ["read", "operate"]}]
    agent = Map.merge(@agent, %{projects: ["web"], project_roles: roles})
    with_roles = call("cancel_run", %{"id" => run}, agent)["structuredContent"]["approval"]

    assert {:ok, %{"status" => "failed"}} =
             Approvals.decide(with_roles["id"], %{sub: "ada", scopes: ["operate"]}, :approve)
  end

  test "who may see an approval; tools that need none; the default time", %{run: run} do
    approval = ask(run)
    other = %{sub: "other", scopes: ["read"], via: :bearer, projects: ["other"]}
    assert %{"isError" => true} = call("get_approval", %{"id" => approval["id"]}, other)
    assert %{"isError" => true} = call("get_approval", %{"id" => "approval-nope"})
    assert %{"isError" => true} = call("get_approval", %{})
    refute Access.event?(other, "approval", approval)

    # Access is checked before asking: another project's run does not exist for it.
    assert %{"isError" => true, "content" => [%{"text" => "no run " <> _}]} =
             call("delete_run", %{"id" => run}, other |> Map.put(:scopes, ["read", "operate"]))

    # A run that does not exist has no project: the tool will say so once approved.
    assert %{"project" => nil} = ask("20991231-000000-abcdef")

    config(%{"tools" => "all"})
    assert Approvals.tools() == []
    assert %{"structuredContent" => %{"deleted" => _}} = call("delete_run", %{"id" => run})

    config(%{"tools" => ["cancel_run"]})
    id = record(%{"project" => "web", "status" => "passed"})
    on_exit(fn -> Store.delete(id) end)

    assert %{"structuredContent" => %{"approval" => %{"expiresAt" => expires, "createdAt" => created}}} =
             call("cancel_run", %{"id" => id})

    {:ok, e, _} = DateTime.from_iso8601(expires)
    {:ok, c, _} = DateTime.from_iso8601(created)
    assert DateTime.diff(e, c) == 1800
  end

  test "over HTTP", %{run: run} do
    approval = ask(run)
    denied = ask(run)

    assert %{"data" => [_, _]} =
             request(:get, "/api/v1/approvals?status=pending", "ada").resp_body |> JSON.decode!()

    assert %{"data" => []} = request(:get, "/api/v1/approvals", "other").resp_body |> JSON.decode!()
    assert request(:get, "/api/v1/approvals/#{approval["id"]}", "ada").status == 200
    assert request(:get, "/api/v1/approvals/#{approval["id"]}", "other").status == 404
    assert request(:get, "/api/v1/approvals/approval-nope", "ada").status == 404

    assert request(:post, "/api/v1/approvals/#{approval["id"]}/approve", "ai-agent").status == 403
    assert request(:post, "/api/v1/approvals/#{approval["id"]}/approve", "other").status == 403

    assert %{"status" => "done"} =
             request(:post, "/api/v1/approvals/#{approval["id"]}/approve", "ada").resp_body |> JSON.decode!()

    assert request(:post, "/api/v1/approvals/#{approval["id"]}/deny", "ada").status == 409
    assert request(:post, "/api/v1/approvals/approval-nope/deny", "ada").status == 404

    assert %{"status" => "denied"} =
             request(:post, "/api/v1/approvals/#{denied["id"]}/deny", "ada").resp_body |> JSON.decode!()
  end
end
