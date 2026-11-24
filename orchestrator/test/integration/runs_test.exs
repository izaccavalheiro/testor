defmodule Testor.Integration.RunsTest do
  @moduledoc """
  End to end through the running server: runs recorded on disk as run.ps1 records them, the
  store and the trackers following them, and the dashboard's HTTP API and event streams
  serving them, over real sockets. Authentication is off (no auth.json), as on a fresh install.
  """
  use ExUnit.Case, async: false
  import Testor.Test.Helpers
  alias Testor.{Config, Events, OS, RunTracker, Store}

  @x [{"x-testor", "1"}]

  defp shot(id, rel, bytes \\ "PNG") do
    path = Path.join([Config.shots_dir(), id, rel])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)
  end

  defp artifact(id, rel, bytes) do
    path = Path.join([Config.artifacts_dir(), id, rel])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)
  end

  test "a run is followed live and ends with its specs, screenshots and artifacts" do
    {_port, pid} = sleeper()
    id = run_id()
    log(id, "")
    Events.subscribe({"run", id})
    Events.subscribe("global")
    record(%{"id" => id, "project" => "live", "pid" => pid})
    assert_receive {:event, "run", %{"id" => ^id, "status" => "running"}}, 5000

    sse = stream("/events/runs/#{id}")
    assert [{"snapshot", %{"run" => %{"id" => ^id}, "logBytes" => 0}} | _] = events(sse, "snapshot")

    log(
      id,
      " \e[32m✓\e[0m tests/a.test.ts (2 tests) 5ms\n ❯ tests/b.test.ts (3 tests | 1 failed) 9ms\npartial"
    )

    assert_receive {:event, "log", %{"text" => text, "from" => 0}}, 5000
    assert text =~ "tests/a.test.ts"
    refute text =~ "partial"
    assert_receive {:event, "specs", [_, _]}, 5000
    assert_receive {:event, "live", %{"id" => ^id, "currentSpec" => "tests/b.test.ts"}}, 5000
    assert Enum.any?(events(sse, "specs"), &match?({"specs", [_, _]}, &1))

    # The dashboard's snapshot of a running run comes from its tracker.
    %{"run" => run, "specs" => [_, _], "log" => snapshot_log} = http(:get, "/api/runs/#{id}") |> json()
    assert run["currentSpec"] == "tests/b.test.ts"
    assert snapshot_log =~ "tests/a.test.ts"
    assert %{"running" => running} = http(:get, "/api/state") |> json()
    assert Enum.any?(running, &(&1["id"] == id))

    # A long line without its end is passed on once it is too long to wait for.
    log(id, String.duplicate("x", 70_000))
    assert_receive {:event, "log", %{"text" => long}}, 5000
    assert byte_size(long) > 65_536

    shot(id, "tests/a/shot.png")
    artifact(id, "coverage/index.html", "<html>report</html>")
    artifact(id, "coverage/data.json", "{}")
    artifact(id, "junit.xml", "<testsuite/>")
    artifact(id, "video.webm", String.duplicate("v", 100))
    artifact(id, "blob.bin", "bin")
    finish(id, "failed", %{"screenshots" => 1, "artifacts" => 5})
    OS.kill_tree(pid)

    assert_receive {:event, "run", %{"id" => ^id, "status" => "failed"}}, 5000
    assert_receive {:event, "screenshots", [%{"url" => shot_url}]}, 5000
    assert_receive {:event, "artifacts", artifacts}, 5000
    assert Enum.any?(events(sse, "artifacts"), &match?({"artifacts", _}, &1))
    close(sse)

    # The record is finalized with the summary of the whole log.
    assert %{"summary" => %{"specs" => 2, "failed" => 1}} = Store.get(id)

    # Screenshots and artifacts are served.
    assert %{status: 200} = png = http(:get, shot_url)
    assert header(png, "content-type") == "image/png"

    by_kind = Map.new(artifacts, &{&1["kind"], &1})
    blob = Enum.find(artifacts, &(&1["path"] == "blob.bin"))
    assert %{status: 200, body: "<html>report</html>"} = page = http(:get, by_kind["report"]["url"])
    assert header(page, "content-security-policy") =~ "sandbox"
    assert http(:get, String.replace(by_kind["report"]["url"], "index.html", "data.json")).body == "{}"

    video = by_kind["video"]["url"]
    assert %{status: 206, body: "vvvvvvvvvv"} = part = http(:get, video, headers: [{"range", "bytes=10-19"}])
    assert header(part, "content-range") == "bytes 10-19/100"
    assert %{status: 416} = http(:get, video, headers: [{"range", "bytes=500-600"}])
    assert header(http(:get, blob["url"]), "content-disposition") =~ "attachment"

    # Nothing outside the folders, nothing that is not there.
    assert %{status: 404} = http(:get, "/artifacts/#{id}/..%2F..%2Fruns%2F#{id}.json")
    assert %{status: 404} = http(:get, "/artifacts/#{id}/nope.txt")
    assert %{status: 404} = http(:get, "/shots/#{id}/nope.png")
    assert %{status: 404} = http(:get, "/shots/#{id}/..%2F..%2Fconfig.json")

    # The galleries.
    assert Enum.any?(http(:get, "/api/screenshots") |> json(), &(&1["runId"] == id))
    assert Enum.any?(http(:get, "/api/artifacts") |> json(), &(&1["runId"] == id))
    assert %{"data" => [_ | _]} = http(:get, "/api/v1/screenshots") |> json()
    assert %{"data" => [_ | _]} = http(:get, "/api/v1/artifacts") |> json()

    # The finished run's snapshot reads the log from disk.
    %{"specs" => [_, _], "log" => text, "truncated" => false} = http(:get, "/api/runs/#{id}") |> json()
    assert text =~ "partial"

    log = http(:get, "/api/runs/#{id}/log?tail=7")
    assert header(log, "x-log-truncated") == "true"
    assert http(:get, "/api/runs/#{id}/log?tail=bogus").body =~ "tests/a.test.ts"
  end

  test "a run whose PowerShell is gone is settled as aborted" do
    {_port, pid} = sleeper()
    OS.kill_tree(pid)
    wait_until(fn -> not OS.alive?(pid) end)
    id = run_id()
    log(id, "started\n")
    Events.subscribe("global")
    record(%{"id" => id, "pid" => pid, "project" => "aborted"})
    assert_receive {:event, "run", %{"id" => ^id, "status" => "aborted"}}, 15_000
    assert %{"status" => "aborted", "durationMs" => ms} = Store.get(id)
    assert is_integer(ms)
  end

  test "cancel and delete, from the dashboard's routes" do
    {_port, pid} = sleeper()
    id = record(%{"pid" => pid, "project" => "cancel"})

    assert %{status: 409} = http(:delete, "/api/runs/#{id}", headers: @x)
    assert %{status: 403} = http(:post, "/api/runs/#{id}/cancel", body: "", type: "text/plain")
    assert %{status: 200} = cancelled = http(:post, "/api/runs/#{id}/cancel", headers: @x, body: "")
    assert %{"status" => "cancelled"} = json(cancelled)
    wait_until(fn -> not OS.alive?(pid) end)

    assert %{status: 409} = http(:post, "/api/runs/#{id}/cancel", headers: @x, body: "")
    assert %{status: 404} = http(:post, "/api/runs/nope/cancel", headers: @x, body: "")
    assert %{status: 400} = http(:post, "/api/runs/a%20b/cancel", headers: @x, body: "")

    shot(id, "a.png")
    assert %{status: 200} = http(:delete, "/api/runs/#{id}", headers: @x)
    refute File.exists?(Config.run_file(id))
    refute File.exists?(Path.join(Config.shots_dir(), id))
    assert Store.get(id) == nil
    assert %{status: 404} = http(:get, "/api/runs/#{id}")
  end

  test "cancel and delete through the versioned API and MCP" do
    {_port, pid} = sleeper()
    id = record(%{"pid" => pid, "project" => "cancel-v1"})

    assert %{status: 409, body: body} = http(:delete, "/api/v1/runs/#{id}", headers: @x)
    assert %{"error" => %{"code" => "running"}} = JSON.decode!(body)
    assert %{status: 200} = http(:post, "/api/v1/runs/#{id}/cancel", body: "{}")
    assert %{status: 409} = http(:post, "/api/v1/runs/#{id}/cancel", body: "{}")
    assert %{status: 200} = http(:delete, "/api/v1/runs/#{id}", body: "{}")

    {_port, pid} = sleeper()
    id = record(%{"pid" => pid, "project" => "cancel-mcp"})
    assert %{"isError" => true} = tool("delete_run", %{"id" => id})

    assert %{"isError" => false, "structuredContent" => %{"run" => %{"status" => "cancelled"}}} =
             tool("cancel_run", %{"id" => id})

    assert %{"isError" => true} = tool("cancel_run", %{"id" => id})

    assert %{"isError" => false, "structuredContent" => %{"deleted" => ^id}} =
             tool("delete_run", %{"id" => id})
  end

  test "two runs of one project at once are flagged" do
    {_p1, pid1} = sleeper()
    {_p2, pid2} = sleeper()
    first = record(%{"pid" => pid1, "project" => "overlap"})
    second = record(%{"pid" => pid2, "project" => "overlap"})
    assert %{"warning" => warning} = Store.get(second)
    assert warning =~ first

    # A running record rewritten keeps the warning and is published again.
    Events.subscribe("global")
    {:ok, run} = Testor.Files.read_json(Config.run_file(second))
    Testor.Files.write_json(Config.run_file(second), Map.put(run, "command", "npm test -- again"))
    assert_receive {:event, "run", %{"id" => ^second, "command" => "npm test -- again", "warning" => _}}, 5000

    Store.cancel(first)
    Store.cancel(second)
  end

  test "the store reads half-written records later and forgets removed ones" do
    id = run_id()
    File.write!(Config.run_file(id), "{\"id\":")
    Process.sleep(700)
    assert Store.get(id) == nil

    Events.subscribe("global")
    record(%{"id" => id, "status" => "passed", "project" => "half"})
    File.rm!(Config.run_file(id))
    assert_receive {:event, "run_removed", %{"id" => ^id}}, 5000
  end

  test "a tracker stops when its run's record goes away" do
    {_port, pid} = sleeper()
    id = record(%{"pid" => pid, "project" => "vanish"})

    [{tracker, _}] =
      wait_until(fn -> Registry.lookup(Testor.TrackerRegistry, id) |> then(&(&1 != [] && &1)) end)

    ref = Process.monitor(tracker)
    File.rm!(Config.run_file(id))
    assert_receive {:DOWN, ^ref, :process, _, :normal}, 5000
    assert RunTracker.snapshot(id) == nil
    OS.kill_tree(pid)
  end

  test "the store survives a record it cannot handle" do
    id = run_id()
    # A project that is not text breaks the start's log line: the scan fails once and goes on.
    record(%{"id" => id, "project" => %{"not" => "text"}})
    File.rm!(Config.run_file(id))
    wait_until(fn -> Store.get(id) == nil end)
    assert %{status: 200} = http(:get, "/api/health")
  end

  test "the global event stream and the dashboard page" do
    sse = stream("/events")

    assert [{"snapshot", %{"host" => _, "running" => _, "history" => _, "config" => _}} | _] =
             events(sse, "snapshot")

    id = record(%{"status" => "passed", "project" => "global-sse"})
    assert Enum.any?(events(sse, "run"), &match?({"run", %{"id" => ^id}}, &1))
    close(sse)

    sse = stream("/api/v1/events")
    assert [{"snapshot", _} | _] = events(sse, "snapshot")
    close(sse)

    assert [{"status", %{"status" => 404}}] = stream("/events/runs/nope") |> events("snapshot")
    assert [{"status", %{"status" => 400}}] = stream("/events/runs/a%20b") |> events("snapshot")
    assert [{"snapshot", _} | _] = stream("/api/v1/runs/#{id}/events") |> events("snapshot")

    page = http(:get, "/")
    assert page.status == 200
    assert header(page, "x-frame-options") == "DENY"
    assert page.body =~ "<html"
  end

  test "the JSON endpoints" do
    id = record(%{"status" => "passed", "project" => "json"})
    assert %{"ok" => true, "home" => _, "auth" => false} = http(:get, "/api/health") |> json()
    assert %{"ok" => true, "home" => _} = http(:get, "/api/v1/health") |> json()
    assert %{"static" => _, "sample" => _} = http(:get, "/api/device") |> json()
    assert %{"static" => _} = http(:get, "/api/v1/device") |> json()
    assert %{"disk" => _} = http(:get, "/api/v1/stats") |> json()
    assert %{"data" => _} = http(:get, "/api/v1/sessions") |> json()
    assert %{"data" => [_ | _]} = http(:get, "/api/v1/projects") |> json()
    assert %{"run" => %{"id" => ^id}} = http(:get, "/api/v1/runs/#{id}") |> json()
    assert %{status: 400} = http(:get, "/api/v1/runs/a%20b")
    assert %{status: 400} = http(:get, "/api/v1/runs?before=a%20b")
    assert %{"data" => [_ | _]} = http(:get, "/api/v1/runs?q=&limit=x") |> json()
    assert %{status: 404} = http(:get, "/nope")
    assert %{"authEnabled" => false, "via" => "none"} = http(:get, "/api/v1/auth/me") |> json()
    assert %{"error" => "invalid_request"} = http(:post, "/api/v1/auth/token", body: "{}") |> json()

    assert %{"error" => %{"code" => "bad_request"}} =
             http(:post, "/api/v1/maintenance/clean", body: "[1]") |> json()
  end

  defp tool(name, args) do
    %{"result" => result} =
      http(:post, "/mcp",
        body:
          JSON.encode!(%{
            "jsonrpc" => "2.0",
            "id" => 1,
            "method" => "tools/call",
            "params" => %{"name" => name, "arguments" => args}
          })
      )
      |> json()

    result
  end

  test "MCP tools over HTTP" do
    {_port, pid} = sleeper()
    id = record(%{"pid" => pid, "project" => "mcp-tools", "command" => "npm run e2e"})
    log(id, "line one\nERROR here\nline three\n")
    shot(id, "x.png")
    artifact(id, "junit.xml", "<testsuite/>")

    assert %{"structuredContent" => %{"running" => running, "projects" => _, "stats" => _}} =
             tool("get_status", %{})

    assert Enum.any?(running, &(&1["id"] == id))
    assert %{"structuredContent" => %{"projects" => [_ | _]}} = tool("list_projects", %{})
    assert %{"structuredContent" => %{"static" => _}} = tool("get_device", %{})

    assert %{"structuredContent" => %{"runs" => [%{"id" => ^id}]}} =
             tool("list_runs", %{"project" => "mcp-tools", "kind" => "test", "query" => "", "limit" => 5})

    assert %{"isError" => true} = tool("list_runs", %{"status" => "bogus"})
    assert %{"isError" => true} = tool("list_runs", %{"before" => "a b"})

    %{"content" => [%{"text" => text}]} =
      wait_until(fn ->
        result = tool("get_run_log", %{"id" => id, "grep" => "error", "context" => 1})
        String.contains?(hd(result["content"])["text"], "ERROR") && result
      end)

    assert text =~ "1 matching lines"
    assert text =~ "1: line one"
    assert %{"content" => [%{"text" => tail}]} = tool("get_run_log", %{"id" => id, "tail_bytes" => 10})
    assert tail =~ "the last 10 of"
    assert %{"content" => [%{"text" => "line one" <> _}]} = tool("get_run_log", %{"id" => id})
    assert %{"isError" => true} = tool("get_run_log", %{"id" => "nope"})
    assert %{"isError" => true} = tool("get_run_log", %{})
    assert %{"isError" => true} = tool("get_run_log", %{"id" => "a b"})

    log(id, " ❯ tests/b.test.ts (3 tests | 1 failed) 9ms\n")

    %{"structuredContent" => detail} =
      wait_until(fn ->
        d = tool("get_run", %{"id" => id})
        d["structuredContent"]["failedSpecs"] != [] && d
      end)

    assert [%{"url" => "http://127.0.0.1:" <> _}] = detail["screenshots"]
    assert [%{"url" => "http://127.0.0.1:" <> _}] = detail["artifacts"]
    assert detail["failedSpecs"] == ["tests/b.test.ts"]

    assert %{"structuredContent" => %{"ended" => false}} =
             tool("wait_for_run", %{"id" => id, "timeout_seconds" => 1})

    Task.start(fn -> Process.sleep(700) && finish(id, "passed") end)

    assert %{"structuredContent" => %{"ended" => true, "run" => %{"status" => "passed"}}} =
             tool("wait_for_run", %{"id" => id})

    assert %{"structuredContent" => %{"ended" => true}} = tool("wait_for_run", %{"id" => id})
    assert %{"isError" => true} = tool("wait_for_run", %{"id" => "nope"})
    OS.kill_tree(pid)

    # A tool that fails inside (here: the sessions process does not answer) answers isError.
    :sys.suspend(Testor.Sessions)

    try do
      assert %{"isError" => true, "content" => [%{"text" => "the tool failed" <> _}]} =
               tool("get_status", %{})
    after
      :sys.resume(Testor.Sessions)
    end
  end

  test "edges of the store, the galleries and the file routes" do
    # Two runs of one project that is not text: building the overlap warning fails, the scan goes on.
    a = record(%{"project" => %{"not" => "text"}})
    b = record(%{"project" => %{"not" => "text"}})
    for id <- [a, b], do: File.rm!(Config.run_file(id))
    wait_until(fn -> Store.get(a) == nil and Store.get(b) == nil end)

    # The janitor keeps a run whose start it cannot read.
    odd = record(%{"status" => "passed", "project" => "odd", "startedAt" => "garbage"})
    Testor.Janitor.run("test")
    assert Store.get(odd)

    # A loose file that is not an image, a run folder without artifacts.
    File.mkdir_p!(Config.shots_dir())
    File.write!(Path.join(Config.shots_dir(), "notes.txt"), "x")
    File.mkdir_p!(Path.join(Config.artifacts_dir(), "no-artifacts"))
    shots = http(:get, "/api/screenshots") |> json()
    refute Enum.any?(shots, &(&1["path"] == "notes.txt"))
    refute Enum.any?(http(:get, "/api/artifacts") |> json(), &(&1["runId"] == "no-artifacts"))

    assert %{status: 404} = http(:get, "/shots/")
    assert %{status: 404} = http(:get, "/artifacts/")

    # A same-origin request (the browser's Origin header) passes the CSRF guard.
    port = Application.fetch_env!(:testor, :test_port)

    assert %{status: 400} =
             http(:post, "/api/maintenance/clean",
               headers: [{"origin", "http://127.0.0.1:#{port}"}],
               body: "nope"
             )

    assert http(:get, "/api/v1/runs/#{odd}/log?grep=").status == 200
  end

  test "event streams drop lines they already sent, keep alive, and end with the browser" do
    id = record(%{"status" => "passed", "project" => "sse-edges"})
    Application.put_env(:testor, :sse_heartbeat_ms, 100)

    try do
      sse = stream("/events/runs/#{id}")
      assert [{"snapshot", _} | _] = events(sse, "snapshot")

      [{handler, _}] =
        wait_until(fn -> Registry.lookup(Testor.EventRegistry, {"run", id}) |> then(&(&1 != [] && &1)) end)

      # A log event the snapshot already held is not sent again.
      send(handler, {:event, "log", %{"text" => "old", "from" => 0, "to" => 0}})
      send(handler, {:event, "marker", %{}})
      assert [{"marker", _}] = events(sse, "marker") |> Enum.filter(&(elem(&1, 0) in ["log", "marker"]))

      # The heartbeat, then the browser leaves: the handler ends at its next write.
      Process.sleep(300)
      ref = Process.monitor(handler)
      close(sse)
      assert_receive {:DOWN, ^ref, :process, _, _}, 5000
    after
      Application.delete_env(:testor, :sse_heartbeat_ms)
    end
  end
end
