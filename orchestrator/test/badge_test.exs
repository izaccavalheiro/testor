defmodule Testor.BadgeTest do
  @moduledoc "Status badges, private or public per project."
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn
  import Testor.Test.Helpers
  alias Testor.{Badge, Config, Store}
  alias Testor.Auth.{Guard, Password}
  alias Testor.Web.Router

  @password "correct horse battery"

  setup do
    Guard.reset()

    on_exit(fn ->
      File.rm(Path.join(Config.data_dir(), "config.json"))
      Application.delete_env(:testor, :auth)
    end)
  end

  defp run(project, kind, status) do
    id = record(%{"project" => project, "kind" => kind, "status" => status})
    on_exit(fn -> Store.delete(id) end)
    wait_until(fn -> Store.get(id) end)
  end

  test "the latest result, of a task or of the project" do
    run("badged", "test", "failed")
    run("badged", "lint", "passed")

    assert Badge.svg("badged", "test") =~ ~r/>test<\/text><text[^>]*>failed</
    assert Badge.svg("badged", "test") =~ "#c62828"
    assert Badge.svg("badged", nil) =~ ">tests</text>"
    assert Badge.svg("unknown", "e2e") =~ ">no runs<"

    svg = Badge.render("<x>", "a & b", "#000")
    assert svg =~ "&lt;x&gt;" and svg =~ "a &amp; b"
    refute svg =~ "<x>"
    assert Badge.render(String.duplicate("l", 100), "m", "#000") =~ ~s(width="447")
  end

  test "private, unless config.json lists the project in publicBadges" do
    run("web", "test", "passed")
    hash = Password.hash(@password, 1000)

    Application.put_env(:testor, :auth, %{
      "users" => %{"ci" => %{"password" => hash, "projects" => ["other"]}}
    })

    get = fn path, headers ->
      Enum.reduce(headers, conn(:get, path), fn {k, v}, c -> put_req_header(c, k, v) end)
      |> Router.call(Router.init([]))
    end

    assert get.("/api/v1/projects/web/badge.svg", []).status == 401
    # A user who may not see the project gets nothing either.
    basic = [{"authorization", "Basic " <> Base.encode64("ci:#{@password}")}]
    assert get.("/api/v1/projects/web/badge.svg", basic).status == 404

    File.write!(Path.join(Config.data_dir(), "config.json"), JSON.encode!(%{"publicBadges" => ["web"]}))
    public = get.("/api/v1/projects/web/badge.svg?kind=test", [])
    assert public.status == 200
    assert get_resp_header(public, "content-type") |> hd() =~ "image/svg+xml"
    assert get_resp_header(public, "cache-control") == ["no-cache, max-age=0"]
    assert public.resp_body =~ "passed"
    assert get.("/api/v1/projects/docs/badge.svg", []).status == 401

    File.write!(Path.join(Config.data_dir(), "config.json"), JSON.encode!(%{"publicBadges" => "web"}))
    refute Badge.public?("web")
  end
end
