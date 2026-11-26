defmodule Testor.WebTest do
  # Changes the application env (:auth) and owns the store's tables: not async.
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn
  alias Testor.Auth.{Guard, Password}
  alias Testor.Web.Router

  @password "correct horse battery"
  @opts Router.init([])

  setup_all do
    # Runs recorded as run.ps1 records them, which the store picks up.
    Testor.Test.Helpers.log(
      "20261124-120000-cccccc",
      "running 3 tests\ntest a ... ok\ntest b ... FAILED\nassertion failed: left == right\ntest c ... ok\n"
    )

    for {id, project, kind, command, status} <- [
          {"20261124-100000-aaaaaa", "webt-app", "test", "npm test", "passed"},
          {"20261124-110000-bbbbbb", "webt-app", "lint", "npm run lint", "failed"},
          {"20261124-120000-cccccc", "webt-lib", "test", "cargo test", "failed"}
        ] do
      Testor.Test.Helpers.record(%{
        "id" => id,
        "project" => project,
        "kind" => kind,
        "command" => command,
        "status" => status
      })
    end

    hash = Password.hash(@password, 1000)

    Application.put_env(:testor, :auth, %{
      "users" => %{
        "ada" => %{"password" => hash, "role" => "admin"},
        "val" => %{"password" => hash, "role" => "viewer"}
      }
    })

    on_exit(fn -> Application.delete_env(:testor, :auth) end)
    :ok
  end

  setup do
    Guard.reset()
    :ok
  end

  defp call(conn), do: Router.call(conn, @opts)

  defp basic(conn, user, password \\ @password),
    do: put_req_header(conn, "authorization", "Basic " <> Base.encode64("#{user}:#{password}"))

  defp bearer(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)
  defp body(conn), do: JSON.decode!(conn.resp_body)

  defp token(user, extra) do
    conn =
      conn(:post, "/api/v1/auth/token", JSON.encode!(extra))
      |> put_req_header("content-type", "application/json")
      |> basic(user)
      |> call()

    assert conn.status == 200, conn.resp_body
    body(conn)["access_token"]
  end

  describe "authentication" do
    test "the health check is public and says less without credentials" do
      conn = conn(:get, "/api/health") |> call()
      assert conn.status == 200
      assert %{"ok" => true, "auth" => true} = body(conn)
      refute Map.has_key?(body(conn), "home")

      assert Map.has_key?(conn(:get, "/api/v1/health") |> basic("val") |> call() |> body(), "home")
    end

    test "everything else asks for credentials, Basic first" do
      for path <- ["/", "/api/state", "/events", "/api/v1/runs", "/shots/x/a.png"] do
        conn = conn(:get, path) |> call()
        assert conn.status == 401, path

        assert [~s(Basic realm="testor", charset="UTF-8"), ~s(Bearer realm="testor")] =
                 get_resp_header(conn, "www-authenticate")
      end

      assert %{"error" => %{"code" => "unauthorized"}} = conn(:get, "/api/v1/runs") |> call() |> body()
      # The dashboard's routes keep a plain message.
      assert %{"error" => "authentication required" <> _} = conn(:get, "/api/state") |> call() |> body()
    end

    test "Basic credentials" do
      assert %{"user" => "ada", "via" => "basic", "scopes" => ["read", "operate", "maintain", "execute"]} =
               conn(:get, "/api/v1/auth/me") |> basic("ada") |> call() |> body()

      assert conn(:get, "/api/v1/auth/me") |> basic("ada", "wrong") |> call() |> Map.get(:status) == 401
      assert conn(:get, "/api/v1/auth/me") |> basic("nobody") |> call() |> Map.get(:status) == 401
    end

    test "an address is refused after 10 failures" do
      for _ <- 1..10,
          do: assert(conn(:get, "/api/v1/runs") |> basic("ada", "wrong") |> call() |> Map.get(:status) == 401)

      conn = conn(:get, "/api/v1/runs") |> basic("ada") |> call()
      assert conn.status == 429
      assert [_] = get_resp_header(conn, "retry-after")
    end

    test "a Bearer token from the token endpoint, with the scopes asked for" do
      token = token("ada", %{"scope" => "read", "expires_in" => 300})
      me = conn(:get, "/api/v1/auth/me") |> bearer(token) |> call() |> body()
      assert %{"user" => "ada", "via" => "bearer", "scopes" => ["read"], "expiresAt" => exp} = me
      assert exp > System.system_time(:second)

      # A read token cannot cancel, and cannot mint another token.
      assert conn(:post, "/api/v1/runs/x/cancel") |> bearer(token) |> call() |> Map.get(:status) == 403

      assert %{"error" => "invalid_client"} =
               conn(:post, "/api/v1/auth/token") |> bearer(token) |> call() |> body()
    end

    test "the token endpoint speaks OAuth 2.0 (client credentials, form body)" do
      conn =
        conn(:post, "/api/v1/auth/token", "grant_type=client_credentials&scope=read+operate")
        |> put_req_header("content-type", "application/x-www-form-urlencoded")
        |> basic("ada")
        |> call()

      assert %{"token_type" => "Bearer", "scope" => "read operate"} = body(conn)

      conn =
        conn(:post, "/api/v1/auth/token", "grant_type=password")
        |> put_req_header("content-type", "application/x-www-form-urlencoded")
        |> basic("ada")
        |> call()

      assert %{"error" => "unsupported_grant_type"} = body(conn)

      assert %{"error" => "invalid_scope"} =
               conn(:post, "/api/v1/auth/token", ~s({"scope":"operate"})) |> basic("val") |> call() |> body()
    end

    test "a forged or garbled token is refused" do
      for value <- ["Bearer abc.def.ghi", "Bearer x", "Token abc", "Basic !!!"] do
        conn = conn(:get, "/api/v1/runs") |> put_req_header("authorization", value) |> call()
        assert conn.status == 401, value
      end
    end
  end

  describe "authorization and CSRF" do
    test "scopes: a viewer reads but cannot change anything" do
      assert conn(:get, "/api/v1/runs") |> basic("val") |> call() |> Map.get(:status) == 200

      conn = conn(:post, "/api/v1/cleanup") |> put_req_header("x-testor", "1") |> basic("val") |> call()
      assert conn.status == 403
      assert %{"error" => %{"code" => "forbidden"}} = body(conn)
    end

    test "Basic-authenticated changes need X-Testor or a JSON body, from this origin" do
      conn = conn(:delete, "/api/runs/20261124-100000-aaaaaa") |> basic("ada") |> call()
      assert conn.status == 403
      assert %{"error" => "missing X-Testor header"} = body(conn)

      conn =
        conn(:post, "/api/v1/runs/20261124-100000-aaaaaa/cancel")
        |> basic("ada")
        |> put_req_header("x-testor", "1")
        |> put_req_header("origin", "https://evil.example")
        |> call()

      assert %{"error" => %{"code" => "cross_origin"}} = body(conn)

      for origin <- ["null", "http://www.example.com:6767"] do
        conn =
          conn(:post, "/api/runs/x/cancel")
          |> basic("ada")
          |> put_req_header("x-testor", "1")
          |> put_req_header("origin", origin)
          |> call()

        assert conn.status == 403, origin
      end
    end

    test "a same-origin request passes the CSRF guard" do
      conn =
        conn(:post, "/api/maintenance/clean", ~s({}))
        |> basic("ada")
        |> put_req_header("origin", "http://www.example.com")
        |> put_req_header("content-type", "application/json")
        |> call()

      # Past the guards: the route itself refuses the empty body.
      assert conn.status == 400
    end
  end

  describe "signed file links" do
    test "are bound to the viewer: no credentials or the viewer open them, someone else gets 403" do
      id = "20261124-100000-aaaaaa"
      dir = Path.join(Testor.Config.shots_dir(), id)
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "a.png"), <<137, 80, 78, 71>>)
      on_exit(fn -> File.rm_rf!(dir) end)

      %{"screenshots" => [%{"url" => url}]} =
        conn(:get, "/api/runs/#{id}") |> basic("val") |> call() |> body()

      assert "/s/v2." <> _ = url

      assert conn(:get, url) |> basic("val") |> call() |> Map.get(:status) == 200
      assert conn(:get, url) |> call() |> Map.get(:status) == 200

      conn = conn(:get, url) |> basic("ada") |> call()
      assert conn.status == 403
      assert %{"error" => "this link was made for someone else"} = body(conn)

      arts = Path.join(Testor.Config.artifacts_dir(), id)
      File.mkdir_p!(arts)
      File.write!(Path.join(arts, "out.txt"), "hello")
      on_exit(fn -> File.rm_rf!(arts) end)

      %{"artifacts" => [%{"url" => art}]} = conn(:get, "/api/runs/#{id}") |> basic("val") |> call() |> body()
      assert conn(:get, art) |> basic("val") |> call() |> Map.get(:resp_body) == "hello"

      assert conn(:get, "/s/123.abc/shots/#{id}/a.png") |> call() |> Map.get(:status) == 404
      assert conn(:get, "/s/~/shots/#{id}/a.png") |> call() |> Map.get(:status) == 404
    end

    test "the dashboard's state says how long they last" do
      assert %{"linkTtl" => 900} = conn(:get, "/api/state") |> basic("val") |> call() |> body()
    end
  end

  describe "API v1" do
    test "runs are filtered and paged" do
      assert %{
               "data" => [%{"id" => "20261124-120000-cccccc"}, %{"id" => "20261124-110000-bbbbbb"}],
               "next" => "20261124-110000-bbbbbb"
             } =
               conn(:get, "/api/v1/runs?limit=2&q=webt-") |> basic("val") |> call() |> body()

      assert %{"data" => [%{"id" => "20261124-100000-aaaaaa"}], "next" => nil} =
               conn(:get, "/api/v1/runs?before=20261124-110000-bbbbbb&q=webt-")
               |> basic("val")
               |> call()
               |> body()

      assert %{"data" => [%{"kind" => "lint"}]} =
               conn(:get, "/api/v1/runs?status=failed&project=webt-app") |> basic("val") |> call() |> body()

      assert %{"data" => [%{"project" => "webt-lib"}]} =
               conn(:get, "/api/v1/runs?q=CARGO") |> basic("val") |> call() |> body()

      assert conn(:get, "/api/v1/runs?status=bogus") |> basic("val") |> call() |> Map.get(:status) == 400
    end

    test "a run omits process details" do
      %{"run" => run} = conn(:get, "/api/v1/runs/20261124-120000-cccccc") |> basic("val") |> call() |> body()
      refute Map.has_key?(run, "pid")
      assert conn(:get, "/api/v1/runs/nope") |> basic("val") |> call() |> Map.get(:status) == 404
      assert conn(:get, "/api/v1/runs/a%20b") |> basic("val") |> call() |> Map.get(:status) == 400
    end

    test "a run's log, filtered" do
      conn = conn(:get, "/api/v1/runs/20261124-120000-cccccc/log?grep=failed") |> basic("val") |> call()
      assert conn.resp_body == "3: test b ... FAILED\n4: assertion failed: left == right"
      assert get_resp_header(conn, "x-log-matches") == ["2"]
    end

    test "projects: the latest run of each project and task" do
      %{"data" => projects} = conn(:get, "/api/v1/projects") |> basic("val") |> call() |> body()

      mine = for p <- projects, String.starts_with?(p["project"], "webt-"), do: {p["project"], p["kind"]}
      assert [{"webt-app", "lint"}, {"webt-app", "test"}, {"webt-lib", "test"}] == mine
    end

    test "the OpenAPI document is public" do
      assert %{"openapi" => "3.1.0", "paths" => %{"/runs" => _}} =
               conn(:get, "/api/v1/openapi.json") |> call() |> body()
    end

    test "unknown endpoints" do
      assert %{"error" => %{"code" => "not_found"}} =
               conn(:get, "/api/v1/nope") |> basic("val") |> call() |> body()
    end
  end

  describe "MCP" do
    defp mcp(user, payload, headers \\ []) do
      conn =
        conn(:post, "/mcp", JSON.encode!(payload))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("accept", "application/json, text/event-stream")

      headers |> Enum.reduce(conn, fn {k, v}, c -> put_req_header(c, k, v) end) |> basic(user) |> call()
    end

    defp request(method, params \\ %{}),
      do: %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params}

    test "initialize negotiates the protocol version" do
      %{"result" => result} =
        mcp("val", request("initialize", %{"protocolVersion" => "2025-06-18"})) |> body()

      assert %{
               "protocolVersion" => "2025-06-18",
               "capabilities" => %{"tools" => _},
               "serverInfo" => %{"name" => "testor"}
             } = result

      %{"result" => %{"protocolVersion" => latest}} =
        mcp("val", request("initialize", %{"protocolVersion" => "1999-01-01"})) |> body()

      assert latest in Testor.Web.MCP.versions()
    end

    test "notifications are accepted with 202" do
      conn = mcp("val", %{"jsonrpc" => "2.0", "method" => "notifications/initialized"})
      assert conn.status == 202
      assert conn.resp_body == ""
    end

    test "tools/list shows the tools the caller's scopes allow" do
      names = fn user ->
        mcp(user, request("tools/list")) |> body() |> get_in(["result", "tools"]) |> Enum.map(& &1["name"])
      end

      assert "get_run_log" in names.("val")
      refute "cancel_run" in names.("val")
      assert "cancel_run" in names.("ada")
    end

    test "tools/call" do
      %{"result" => %{"isError" => false, "structuredContent" => %{"runs" => runs}}} =
        mcp("val", request("tools/call", %{"name" => "list_runs", "arguments" => %{"status" => "failed"}}))
        |> body()

      # Other tests may leave failed runs: count this module's.
      assert runs |> Enum.filter(&String.starts_with?(&1["project"], "webt-")) |> length() == 2

      %{"result" => %{"content" => [%{"text" => text}]}} =
        mcp(
          "val",
          request("tools/call", %{
            "name" => "get_run_log",
            "arguments" => %{"id" => "20261124-120000-cccccc", "grep" => "FAILED", "context" => 0}
          })
        )
        |> body()

      assert text =~ "3: test b ... FAILED"

      %{
        "result" => %{
          "structuredContent" => %{"failedSpecs" => _, "run" => %{"id" => "20261124-120000-cccccc"}}
        }
      } =
        mcp(
          "val",
          request("tools/call", %{"name" => "get_run", "arguments" => %{"id" => "20261124-120000-cccccc"}})
        )
        |> body()

      %{"result" => %{"isError" => true}} =
        mcp("val", request("tools/call", %{"name" => "get_run", "arguments" => %{"id" => "nope"}})) |> body()
    end

    test "a tool beyond the caller's scopes fails" do
      %{"result" => %{"isError" => true, "content" => [%{"text" => text}]}} =
        mcp(
          "val",
          request("tools/call", %{"name" => "cancel_run", "arguments" => %{"id" => "20261124-100000-aaaaaa"}})
        )
        |> body()

      assert text =~ "operate"
    end

    test "protocol errors" do
      assert %{"error" => %{"code" => -32601}} = mcp("val", request("nope/nope")) |> body()

      assert %{"error" => %{"code" => -32602}} =
               mcp("val", request("tools/call", %{"name" => "nope"})) |> body()

      assert %{"error" => %{"code" => -32600}} = mcp("val", %{"id" => 1}) |> body()

      conn =
        conn(:post, "/mcp", "{nope")
        |> put_req_header("content-type", "application/json")
        |> basic("val")
        |> call()

      assert %{"error" => %{"code" => -32700}} = body(conn)
    end

    test "the transport: POST JSON only, known versions, this origin" do
      assert conn(:get, "/mcp") |> basic("val") |> call() |> Map.get(:status) == 405

      assert conn(:post, "/mcp", "{}")
             |> basic("val")
             |> put_req_header("x-testor", "1")
             |> call()
             |> Map.get(:status) == 415

      assert mcp("val", request("ping"), [{"mcp-protocol-version", "1999-01-01"}]).status == 400
      assert mcp("val", request("ping"), [{"origin", "https://evil.example"}]).status == 403

      assert conn(:post, "/mcp", "{}")
             |> put_req_header("content-type", "application/json")
             |> call()
             |> Map.get(:status) == 401
    end

    test "a batch" do
      conn = mcp("val", [request("ping"), %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}])
      assert [%{"id" => 1, "result" => %{}}] = body(conn)
    end
  end

  describe "with authentication off" do
    setup do
      saved = Application.get_env(:testor, :auth)
      Application.put_env(:testor, :auth, %{})
      on_exit(fn -> Application.put_env(:testor, :auth, saved) end)
    end

    test "anyone reads, as before" do
      assert %{"via" => "none", "authEnabled" => false} = conn(:get, "/api/v1/auth/me") |> call() |> body()
      assert %{"data" => [_, _, _]} = conn(:get, "/api/v1/runs?q=webt-") |> call() |> body()
      assert Testor.Auth.file_prefix("x") == ""
      assert %{"linkTtl" => nil} = conn(:get, "/api/state") |> call() |> body()
    end

    test "the CSRF guard still applies" do
      assert conn(:post, "/api/cleanup") |> call() |> Map.get(:status) == 403
    end

    test "there are no tokens" do
      assert %{"error" => "invalid_request"} = conn(:post, "/api/v1/auth/token") |> call() |> body()
    end
  end

  describe "edges" do
    test "credentials that cannot be read" do
      expired = Testor.Auth.mint("ada", ["read"], -120, Testor.Auth.settings())["access_token"]
      conn = conn(:get, "/api/v1/runs") |> bearer(expired) |> call()
      assert conn.status == 401
      assert Enum.any?(get_resp_header(conn, "www-authenticate"), &(&1 =~ "invalid_token"))

      assert conn(:get, "/api/v1/runs")
             |> put_req_header("authorization", "Basic")
             |> call()
             |> Map.get(:status) == 401

      two = %{
        conn(:get, "/api/v1/runs")
        | req_headers: [{"authorization", "Bearer a"}, {"authorization", "Bearer b"}]
      }

      assert call(two).status == 401
    end

    test "reading the audit trail needs the maintain scope" do
      token = token("ada", %{"scope" => "read operate"})
      assert conn(:get, "/api/v1/audit") |> bearer(token) |> call() |> Map.get(:status) == 403
    end

    test "cleaning maintenance targets needs the maintain scope" do
      token = token("ada", %{"scope" => "read operate"})

      assert conn(:post, "/api/v1/maintenance/clean", "{}") |> bearer(token) |> call() |> Map.get(:status) ==
               403
    end

    test "token requests that are not valid" do
      assert %{"error" => "invalid_request"} =
               conn(:post, "/api/v1/auth/token", ~s({"expires_in": 5})) |> basic("ada") |> call() |> body()

      conn =
        conn(:post, "/api/v1/auth/token", "{nope")
        |> put_req_header("content-type", "application/json")
        |> basic("ada")
        |> call()

      assert conn.status == 400
    end

    test "MCP messages that are not requests" do
      notification = %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}
      assert mcp("val", [notification, notification]).status == 202
      assert mcp("val", %{"jsonrpc" => "2.0", "id" => 7, "result" => %{}}).status == 202
      assert %{"error" => %{"code" => -32600}} = mcp("val", 5) |> body()

      assert %{"error" => %{"code" => -32602}} =
               mcp("val", %{"jsonrpc" => "2.0", "id" => 1, "method" => "ping", "params" => 5}) |> body()

      assert %{"error" => %{"code" => -32602}} =
               mcp("val", request("tools/call", %{"name" => "get_status", "arguments" => 5})) |> body()

      assert %{"error" => %{"code" => -32602}} = mcp("val", request("tools/call", %{})) |> body()

      too_big = String.duplicate(" ", 70_000)

      conn =
        conn(:post, "/api/v1/maintenance/clean", too_big)
        |> put_req_header("content-type", "application/json")
        |> basic("ada")
        |> call()

      assert conn.status == 413

      big = String.duplicate(" ", 1_100_000)

      conn =
        conn(:post, "/mcp", big)
        |> put_req_header("content-type", "application/json")
        |> basic("val")
        |> call()

      assert conn.status == 413
    end
  end
end
