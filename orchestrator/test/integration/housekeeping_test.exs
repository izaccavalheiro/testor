defmodule Testor.Integration.HousekeepingTest do
  @moduledoc """
  The janitor, the maintenance scan and cleaning, stats and PowerShell sessions, against the
  running server, with the tools' caches and the temporary folder pointed at a sandbox.
  """
  use ExUnit.Case, async: false
  import Testor.Test.Helpers
  alias Testor.{Config, Events, Janitor, Maintenance, OS, Sessions, Stats, Store}

  @moduletag :tmp_dir
  @x [{"x-testor", "1"}]
  @old System.os_time(:second) - 90 * 86_400

  defp config(map) do
    File.write!(Path.join(Config.data_dir(), "config.json"), JSON.encode!(map))
  end

  setup do
    on_exit(fn -> File.rm(Path.join(Config.data_dir(), "config.json")) end)
  end

  defp write(path, bytes \\ "data", mtime \\ nil) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)
    if mtime, do: File.touch!(path, mtime)
    path
  end

  # A PowerShell that works in a project snapshot without run.ps1, as Sessions sees them.
  defp session(project) do
    folder = Path.join(Config.workspaces(), project)
    script = write(Path.join(folder, "session.ps1"), "Start-Sleep 300")
    pwsh = System.find_executable("pwsh")
    port = Port.open({:spawn_executable, pwsh}, [:binary, :hide, args: ["-NoProfile", "-File", script]])
    {:os_pid, pid} = Port.info(port, :os_pid)
    pid
  end

  describe "janitor" do
    test "removes old runs, old screenshots, oversize artifacts, and keeps running ones" do
      {_port, pid} = sleeper()
      old = record(%{"status" => "passed", "project" => "jan", "startedAt" => "2020-01-01T00:00:00.0000000Z"})
      keep = record(%{"status" => "passed", "project" => "jan"})
      running = record(%{"pid" => pid, "project" => "jan"})

      write(Path.join([Config.shots_dir(), keep, "a.png"]), "PNG", @old)
      write(Path.join(Config.shots_dir(), "loose-old.png"), "PNG", @old)
      write(Path.join(Config.shots_dir(), "loose-new.png"), "PNG")
      write(Path.join([Config.artifacts_dir(), keep, "big.bin"]), String.duplicate("x", 2 * 1024 * 1024))
      write(Path.join([Config.artifacts_dir(), running, "big.bin"]), String.duplicate("x", 2 * 1024 * 1024))

      config(%{"artifacts" => %{"maxTotalMB" => 1}})
      Events.subscribe("global")

      assert %{status: 200} = resp = http(:post, "/api/cleanup", headers: @x, body: "")
      assert %{"reason" => "manual", "removed" => removed} = json(resp)
      assert removed["runs"] >= 1
      assert removed["screenshotFolders"] >= 1
      assert removed["artifactFolders"] >= 1
      assert removed["looseFiles"] >= 1

      assert Store.get(old) == nil
      assert Store.get(keep)
      refute File.exists?(Path.join([Config.shots_dir(), keep]))
      refute File.exists?(Path.join(Config.shots_dir(), "loose-old.png"))
      assert File.exists?(Path.join(Config.shots_dir(), "loose-new.png"))
      assert File.exists?(Path.join([Config.artifacts_dir(), running, "big.bin"]))
      assert_receive {:event, "stats", %{"lastCleanup" => %{"reason" => "manual"}}}, 5000

      assert %{"reason" => "api"} = http(:post, "/api/v1/cleanup", body: "{}") |> json()
      Store.cancel(running)
    end

    test "keeps at most maxRuns runs" do
      config(%{"runs" => %{"maxRuns" => 1}})
      a = record(%{"status" => "passed", "project" => "jan-max"})
      b = record(%{"status" => "passed", "project" => "jan-max"})
      Janitor.run()
      assert Store.get(a) == nil or Store.get(b) == nil
    end

    test "a broken configuration is reported, not fatal" do
      config(%{"runs" => %{"maxAgeDays" => "thirty"}})
      assert %{"error" => _} = Janitor.run("test")
      send(Janitor, {:scheduled, "test"})
      File.rm!(Path.join(Config.data_dir(), "config.json"))
      assert %{"removed" => _} = Janitor.run("after")
    end
  end

  describe "config" do
    test "config.json overrides the defaults, a BOM and all" do
      File.write!(
        Path.join(Config.data_dir(), "config.json"),
        "\uFEFF" <> JSON.encode!(%{"runs" => %{"maxRuns" => 3}, "cleanupIntervalMinutes" => 5})
      )

      assert %{"runs" => %{"maxRuns" => 3, "maxAgeDays" => 30}, "cleanupIntervalMinutes" => 5} =
               Config.retention()

      File.write!(Path.join(Config.data_dir(), "config.json"), "[1]")
      assert %{"runs" => %{"maxRuns" => 500}} = Config.retention()
    end
  end

  describe "stats" do
    test "measures on demand and publishes changes" do
      Events.subscribe("global")
      # Refreshes other tests queued are counted first: one landing after the file below could
      # make its +1 meet a screenshot another test deleted, and no change would be published.
      _ = Stats.get()
      write(Path.join([Config.shots_dir(), "stats-run", "s.png"]), "PNG")
      Stats.refresh_screenshots()
      Stats.refresh_artifacts()
      Stats.refresh_artifacts()
      assert_receive {:event, "stats", %{"screenshots" => %{"count" => n}}} when n > 0, 5000
      assert %{"disk" => _, "artifacts" => _} = Stats.get()

      # Stray messages are ignored.
      send(Stats, {make_ref(), :late})
      send(Stats, {:DOWN, make_ref(), :process, self(), :normal})
      send(Stats, :unexpected)
      send(Stats, :disk)
      send(Stats, :screenshots_tick)
      send(Stats, :artifacts_tick)
      assert %{} = Stats.get()
    end
  end

  describe "sessions" do
    test "lists PowerShell sessions in the workspaces that run.ps1 did not start" do
      Events.subscribe("global")
      pid = session("sessproj")

      send(Sessions, :tick)
      send(Sessions, :poll)
      send(Sessions, :poll)
      assert_receive {:event, "sessions", [%{"project" => "sessproj", "pid" => ^pid}]}, 20_000
      assert [%{"project" => "sessproj"}] = http(:get, "/api/v1/sessions") |> json() |> Map.get("data")

      OS.kill_tree(pid)
      Sessions.poke()
      assert_receive {:event, "sessions", []}, 20_000
      send(Sessions, {:DOWN, make_ref(), :process, self(), :normal})
      send(Sessions, :unexpected)
      assert Sessions.list() == []
    end
  end

  describe "maintenance" do
    test "places/4: the tools' folders on each OS" do
      env = fn _ -> nil end
      home = "/h"

      assert %{
               npm: "/h/.npm/_cacache",
               pip: "/h/.cache/pip",
               go: "/h/.cache/go-build",
               cargo: "/h/.cargo/registry/cache",
               playwright: "/h/.cache/ms-playwright"
             } =
               Maintenance.places(:linux, env, home, "/tmp")

      assert %{npm: "/h/.npm/_cacache", pip: "/h/Library/Caches/pip"} =
               Maintenance.places(:macos, env, home, "/tmp")

      assert %{npm: nil, pip: nil, go: nil, playwright: nil} =
               Maintenance.places(:windows, env, "C:/h", "C:/t")

      local = %{"LOCALAPPDATA" => "C:/L"}

      assert %{npm: "C:/L/npm-cache/_cacache", pip: "C:/L/pip/Cache", go: "C:/L/go-build"} =
               Maintenance.places(:windows, &local[&1], "C:/h", "C:/t")

      own = %{
        "npm_config_cache" => "/n",
        "PIP_CACHE_DIR" => "/p",
        "GOCACHE" => "/g",
        "CARGO_HOME" => "/c",
        "PLAYWRIGHT_BROWSERS_PATH" => "/pw",
        "XDG_CACHE_HOME" => "/x"
      }

      assert %{npm: "/n/_cacache", pip: "/p", go: "/g", cargo: "/c/registry/cache", playwright: "/pw"} =
               Maintenance.places(:linux, &own[&1], home, "/tmp")

      assert %{pip: "/x/pip"} =
               Maintenance.places(
                 :linux,
                 &%{"XDG_CACHE_HOME" => "/x", "PLAYWRIGHT_BROWSERS_PATH" => "0"}[&1],
                 home,
                 "/tmp"
               )

      assert Maintenance.display(%{family: :windows}, "C:/a/b") == "C:\\a\\b"
      assert Maintenance.display(%{family: :linux}, "/a/b") == "/a/b"
    end

    test "scan, and clean what was chosen when nothing runs", %{tmp_dir: sandbox} do
      saved =
        for name <-
              ~w(TMPDIR TEMP TMP npm_config_cache PIP_CACHE_DIR GOCACHE CARGO_HOME PLAYWRIGHT_BROWSERS_PATH),
            into: %{},
            do: {name, System.get_env(name)}

      on_exit(fn ->
        for {name, value} <- saved,
            do: if(value, do: System.put_env(name, value), else: System.delete_env(name))
      end)

      temp = Path.join(sandbox, "temp")
      for name <- ~w(TMPDIR TEMP TMP), do: System.put_env(name, temp)
      write(Path.join(temp, "old.log"), "old", @old)
      write(Path.join(temp, "new.log"), "new")

      for {name, dir} <- [
            {"npm_config_cache", "npm"},
            {"PIP_CACHE_DIR", "pip"},
            {"GOCACHE", "go"},
            {"CARGO_HOME", "cargo"}
          ] do
        System.put_env(name, Path.join(sandbox, dir))
      end

      write(Path.join([sandbox, "npm", "_cacache", "index", "x"]), "npm")
      # Something cleaning cannot delete.
      locked_dir = Path.join([sandbox, "npm", "_cacache", "locked"])
      write(Path.join(locked_dir, "f"), "locked")
      unlock = lock(locked_dir)
      on_exit(unlock)

      write(Path.join([sandbox, "pip", "http", "y"]), "pip")
      write(Path.join([sandbox, "cargo", "registry", "cache", "z.crate"]), "crate")
      System.put_env("PLAYWRIGHT_BROWSERS_PATH", Path.join(sandbox, "pw"))
      write(Path.join([sandbox, "pw", "chromium-1100", "chrome"]), "old")
      write(Path.join([sandbox, "pw", "chromium-1200", "chrome"]), "new")

      snapshot = Path.join(Config.workspaces(), "idle-project")
      write(Path.join(snapshot, "node_modules/x.js"), "x", @old)
      File.touch!(snapshot, @old)
      used = Path.join(Config.workspaces(), "used-project")
      write(Path.join(used, "a.txt"))
      record(%{"status" => "passed", "project" => "used-project"})

      Events.subscribe("global")
      assert %{status: 202} = http(:post, "/api/maintenance/scan", headers: @x, body: "")

      # A scan asked for while one runs changes nothing. Scanning this sandbox takes
      # milliseconds, so two calls are queued while the server is suspended: one of them finds
      # a scan running, however fast this machine is.
      pid = Process.whereis(Maintenance)
      :sys.suspend(pid)

      calls =
        for _ <- 1..2 do
          call = Task.async(&Maintenance.scan/0)
          wait_until(fn -> Process.info(call.pid, :status) == {:status, :waiting} end)
          call
        end

      :sys.resume(pid)
      assert [%{"scanning" => true}, %{"scanning" => true}] = Task.await_many(calls)

      scan =
        wait_until(
          fn ->
            match?(%{"scanning" => false, "scan" => %{}}, Maintenance.state()) && Maintenance.state()["scan"]
          end,
          60_000
        )

      ids = Enum.map(scan["targets"], & &1["id"])

      for id <-
            ~w(snapshot:idle-project snapshot:used-project temp cache:npm cache:pip cache:cargo browsers:playwright),
          do: assert(id in ids, "#{id} not in #{inspect(ids)}")

      refute "cache:go" in ids
      by_id = Map.new(scan["targets"], &{&1["id"], &1})
      assert by_id["snapshot:idle-project"]["suggested"]
      refute by_id["snapshot:used-project"]["suggested"]
      assert by_id["browsers:playwright"]["note"] =~ "chromium-1100"

      targets = ["snapshot:idle-project", "temp", "cache:npm", "browsers:playwright"]
      body = JSON.encode!(%{"scanId" => scan["id"], "targets" => targets})

      # Off until config.json turns it on.
      assert %{status: 403} = http(:post, "/api/maintenance/clean", headers: @x, body: body)
      config(%{"maintenance" => %{"enabled" => true}})

      assert %{status: 400} = http(:post, "/api/maintenance/clean", headers: @x, body: ~s({"scanId": "x"}))

      assert %{status: 409} =
               http(:post, "/api/maintenance/clean",
                 headers: @x,
                 body: JSON.encode!(%{"scanId" => "stale", "targets" => targets})
               )

      assert %{status: 400} =
               http(:post, "/api/maintenance/clean",
                 headers: @x,
                 body: JSON.encode!(%{"scanId" => scan["id"], "targets" => ["nope"]})
               )

      # Not while a PowerShell session works in the workspaces.
      pid = session("busy-project")
      Sessions.poke()
      wait_until(fn -> Sessions.list() != [] end, 20_000)
      assert %{status: 409} = http(:post, "/api/maintenance/clean", headers: @x, body: body)
      OS.kill_tree(pid)
      Sessions.poke()
      wait_until(fn -> Sessions.list() == [] end, 20_000)

      assert %{status: 202} = http(:post, "/api/v1/maintenance/clean", body: body)

      after_clean =
        wait_until(
          fn ->
            match?(%{"cleaning" => false, "scanning" => false, "lastClean" => %{}}, Maintenance.state()) &&
              Maintenance.state()
          end,
          60_000
        )

      assert after_clean["lastClean"]["freed"] > 0
      npm = Enum.find(after_clean["lastClean"]["targets"], &(&1["id"] == "cache:npm"))
      assert [_ | _] = npm["errors"]
      refute File.exists?(snapshot)
      refute File.exists?(Path.join(temp, "old.log"))
      assert File.exists?(Path.join(temp, "new.log"))
      refute File.exists?(Path.join([sandbox, "pw", "chromium-1100"]))
      assert File.exists?(Path.join([sandbox, "pw", "chromium-1200"]))
      assert %{"enabled" => true} = http(:get, "/api/v1/maintenance") |> json()
      assert %{"enabled" => true} = http(:get, "/api/maintenance") |> json()
      assert %{status: 202} = http(:post, "/api/v1/maintenance/scan", body: "{}")
      wait_until(fn -> Maintenance.state()["scanning"] == false end, 60_000)
    end

    test "a scan that fails is reported" do
      wait_until(fn -> Maintenance.state()["scanning"] == false end, 60_000)
      config(%{"maintenance" => %{"tempMinAgeDays" => "seven"}})
      Maintenance.scan()

      assert %{"error" => "scan failed" <> _} =
               wait_until(fn -> Maintenance.state()["error"] && Maintenance.state() end, 30_000)

      send(Maintenance, :unexpected)
      assert %{"scanning" => false} = Maintenance.state()
    end

    test "a target that cannot be deleted is reported", %{tmp_dir: root} do
      dir = Path.join(root, "locked")
      write(Path.join(dir, "f.txt"))
      unlock = lock(dir)

      try do
        # The parent reports its child's error and stays.
        assert [error | _] = Maintenance.remove_tree(root)
        assert error =~ "locked"
        assert File.dir?(dir)
      after
        unlock.()
      end

      assert Maintenance.remove_tree(Path.join(root, "missing")) == []
    end
  end
end
