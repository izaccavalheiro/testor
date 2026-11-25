defmodule Testor.CommitStatusTest.Provider do
  @moduledoc "A GitHub or GitLab API for the tests: hands each status to the test that asked."
  use Plug.Router
  plug(:match)
  plug(:dispatch)

  post _ do
    {:ok, body, conn} = read_body(conn)

    send(
      Application.fetch_env!(:testor, :provider_test),
      {:status, conn.request_path, conn.req_headers, JSON.decode!(body)}
    )

    send_resp(conn, Application.get_env(:testor, :provider_status, 201), "{}")
  end
end

defmodule Testor.CommitStatusTest do
  @moduledoc "Commit statuses on GitHub and GitLab for runs of a commit."
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  import Testor.Test.Helpers
  alias Testor.{CommitStatus, Store}

  @commit "3f4e006a1b2c3d4e5f60718293a4b5c6d7e8f901"

  setup do
    pid =
      start_supervised!(
        {Bandit, plug: Testor.CommitStatusTest.Provider, ip: :loopback, port: 0, startup_log: false}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(pid)
    Application.put_env(:testor, :provider_test, self())
    Application.put_env(:testor, :status_backoff, [10])

    on_exit(fn ->
      File.rm(CommitStatus.file())
      System.delete_env("GITLAB_TOKEN")
      Application.delete_env(:testor, :provider_test)
      Application.delete_env(:testor, :provider_status)
      Application.delete_env(:testor, :status_backoff)
    end)

    %{api: "http://127.0.0.1:#{port}"}
  end

  defp configure(config), do: File.write!(CommitStatus.file(), JSON.encode!(config))

  defp providers(api) do
    %{
      "github" => %{"type" => "github", "api" => api <> "/", "token" => "ghp_test"},
      "gitlab" => %{"type" => "gitlab", "api" => api, "tokenEnv" => "GITLAB_TOKEN"}
    }
  end

  defp run(project, extra \\ %{}) do
    id =
      record(Map.merge(%{"project" => project, "source" => %{"commit" => @commit, "dirty" => false}}, extra))

    # A running run cannot be deleted, and would hold up other tests: end it (with no statuses
    # sent) first.
    on_exit(fn ->
      File.rm(CommitStatus.file())
      Store.settle(id, "cancelled")
      Store.delete(id)
    end)

    id
  end

  test "GitHub: pending while it runs, then success or failure, linked to the run", %{api: api} do
    configure(%{
      "baseUrl" => "https://testor.example.com/",
      "providers" => providers(api),
      "projects" => %{"web" => %{"provider" => "github", "repository" => "acme/web"}}
    })

    id = run("web")
    assert_receive {:status, path, headers, pending}, 5_000
    assert path == "/repos/acme/web/statuses/#{@commit}"
    assert {"authorization", "Bearer ghp_test"} in headers
    assert {"x-github-api-version", "2022-11-28"} in headers

    assert %{"state" => "pending", "context" => "testor/test", "description" => "running on testor"} = pending
    assert pending["target_url"] == "https://testor.example.com/#/run/#{id}"

    capture_log(fn -> finish(id, "failed") end)
    assert_receive {:status, _, _, %{"state" => "failure", "description" => "failed" <> _}}, 5_000
  end

  test "GitLab: running, then success; its token from the environment; no link without baseUrl", %{api: api} do
    System.put_env("GITLAB_TOKEN", "glpat-test")

    configure(%{
      "providers" => providers(api),
      "projects" => %{"lib" => %{"provider" => "gitlab", "repository" => "acme/lib"}}
    })

    id = run("lib")
    assert_receive {:status, path, headers, running}, 5_000
    assert path == "/projects/acme%2Flib/statuses/#{@commit}"
    assert {"private-token", "glpat-test"} in headers
    assert %{"state" => "running", "name" => "testor/test"} = running
    refute Map.has_key?(running, "target_url")

    capture_log(fn -> finish(id, "passed") end)
    assert_receive {:status, _, _, %{"state" => "success"}}, 5_000
  end

  test "no status: a dirty tree, no commit, a project without a provider, no usable config", %{api: api} do
    configure(%{
      "providers" => providers(api),
      "projects" => %{"web" => %{"provider" => "github", "repository" => "acme/web"}}
    })

    run("web", %{"source" => %{"commit" => @commit, "dirty" => true}})
    run("web", %{"source" => nil})
    run("other")
    refute_receive {:status, _, _, _}, 500

    for config <- [
          %{
            "providers" => %{"x" => %{"type" => "bitbucket", "token" => "t"}},
            "projects" => %{"web" => %{"provider" => "x", "repository" => "a/b"}}
          },
          %{
            "providers" => providers(api),
            "projects" => %{"web" => %{"provider" => "gitlab", "repository" => "a/b"}}
          },
          %{"projects" => %{"web" => %{"provider" => "github"}}}
        ] do
      configure(config)
      assert CommitStatus.target("web") == :none
    end

    File.write!(CommitStatus.file(), "[")
    assert CommitStatus.target("web") == :none
    File.rm!(CommitStatus.file())
    assert CommitStatus.target("web") == :none
    assert CommitStatus.notify("no-such-run") == :ok
  end

  test "states and descriptions" do
    github = %{type: "github", api: "https://api.github.com", token: "t", repository: "a/b", base: nil}
    gitlab = %{github | type: "gitlab"}

    state = fn target, status ->
      target
      |> CommitStatus.request(@commit, %{"id" => "r", "kind" => "test", "status" => status})
      |> elem(2)
      |> Map.fetch!("state")
    end

    assert Enum.map(~w(passed cancelled aborted), &state.(github, &1)) == ["success", "error", "error"]
    assert Enum.map(~w(cancelled aborted failed), &state.(gitlab, &1)) == ["canceled", "failed", "failed"]

    {_, _, body} =
      CommitStatus.request(github, @commit, %{
        "id" => "r",
        "kind" => "e2e",
        "status" => "failed",
        "summary" => %{"passed" => 2, "failed" => 1, "skipped" => 0}
      })

    assert body["description"] == "failed: 2 passed, 1 failed"

    # The public APIs unless a provider names its own.
    configure(%{
      "providers" => %{
        "gh" => %{"type" => "github", "token" => "t"},
        "gl" => %{"type" => "gitlab", "token" => "t"}
      },
      "projects" => %{
        "a" => %{"provider" => "gh", "repository" => "a/a"},
        "b" => %{"provider" => "gl", "repository" => "b/b"}
      }
    })

    assert {:ok, %{api: "https://api.github.com"}} = CommitStatus.target("a")
    assert {:ok, %{api: "https://gitlab.com/api/v4"}} = CommitStatus.target("b")
  end

  test "a provider that refuses or cannot be reached is tried again, then logged", %{api: api} do
    Application.put_env(:testor, :provider_status, 500)

    configure(%{
      "providers" => providers(api),
      "projects" => %{"web" => %{"provider" => "github", "repository" => "acme/web"}}
    })

    log =
      capture_log(fn ->
        run("web")
        assert_receive {:status, _, _, _}, 5_000
        assert_receive {:status, _, _, _}, 5_000
        wait_until(fn -> Task.Supervisor.children(Testor.TaskSupervisor) == [] end)
      end)

    assert log =~ "answered 500"

    configure(%{
      "providers" => %{"github" => %{"type" => "github", "api" => "http://127.0.0.1:1", "token" => "t"}},
      "projects" => %{"web" => %{"provider" => "github", "repository" => "acme/web"}}
    })

    log =
      capture_log(fn ->
        run("web")
        wait_until(fn -> Task.Supervisor.children(Testor.TaskSupervisor) == [] end)
      end)

    assert log =~ "failed ("
  end
end
