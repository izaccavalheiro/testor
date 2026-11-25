defmodule Testor.HardeningTest do
  @moduledoc """
  The defences in front of every request and around the files runs leave: the Host
  allow-list (DNS rebinding), the client's address behind trusted proxies, private-only access
  while authentication is off, limits on event streams and password hashing, the per-user
  failure limit, symbolic links, and the checks before a cancel kills a process.
  """
  # Changes the application env and the guard's tables: not async.
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn
  import ExUnit.CaptureLog
  import Testor.Test.Helpers
  alias Testor.{Auth, Config, Files, Store}
  alias Testor.Auth.{Guard, Password}
  alias Testor.Web.Router

  @opts Router.init([])
  @password "correct horse battery"

  defp call(conn), do: Router.call(conn, @opts)
  defp body(conn), do: JSON.decode!(conn.resp_body)
  defp from(conn, ip), do: %{conn | remote_ip: ip}

  defp basic(conn, user, password \\ @password),
    do: put_req_header(conn, "authorization", "Basic " <> Base.encode64("#{user}:#{password}"))

  defp put_env(key, value) do
    saved = Application.fetch_env(:testor, key)
    Application.put_env(:testor, key, value)

    on_exit(fn ->
      case saved do
        {:ok, value} -> Application.put_env(:testor, key, value)
        :error -> Application.delete_env(:testor, key)
      end
    end)
  end

  defp auth_on do
    put_env(:auth, %{
      "users" => %{"ada" => %{"password" => Password.hash(@password, 1000), "role" => "admin"}}
    })
  end

  setup do
    Guard.reset()
    put_env(:auth, %{})
    :ok
  end

  describe "the Host allow-list" do
    test "a name this server does not know is refused (DNS rebinding)" do
      log =
        capture_log(fn ->
          conn = conn(:get, "/api/v1/runs") |> Map.put(:host, "rebind.attacker.example") |> call()
          assert conn.status == 421
          assert %{"error" => %{"code" => "misdirected"}} = body(conn)
        end)

      assert log =~ "refused Host"
    end

    test "IP addresses, localhost, listed names and * are answered" do
      for host <- ["127.0.0.1", "localhost", "www.example.com"] do
        assert (conn(:get, "/api/health") |> Map.put(:host, host) |> call()).status == 200
      end

      put_env(:allowed_hosts, "*")
      assert (conn(:get, "/api/health") |> Map.put(:host, "rebind.attacker.example") |> call()).status == 200
    end

    test "over real HTTP too" do
      assert %{status: 421} = http(:get, "/api/health", headers: [{"host", "evil.example"}])
    end
  end

  describe "while authentication is off" do
    test "private addresses are answered, others are refused, health checks stay public" do
      assert (conn(:get, "/api/state") |> from({192, 168, 1, 20}) |> call()).status == 200

      log =
        capture_log(fn ->
          conn = conn(:get, "/api/state") |> from({203, 0, 113, 9}) |> call()
          assert conn.status == 403
          assert body(conn)["error"] =~ "authentication is off"
        end)

      assert log =~ "authentication is off"
      assert (conn(:get, "/api/health") |> from({203, 0, 113, 9}) |> call()).status == 200
    end

    test "TESTOR_ANONYMOUS: loopback, any" do
      assert Testor.Web.Auth.anonymous_allowed?({203, 0, 113, 9}, "any")
      assert Testor.Web.Auth.anonymous_allowed?({127, 0, 0, 1}, "loopback")
      refute Testor.Web.Auth.anonymous_allowed?({10, 0, 0, 1}, "loopback")

      put_env(:anonymous, "any")
      assert (conn(:get, "/api/state") |> from({203, 0, 113, 9}) |> call()).status == 200
    end

    test "behind a trusted proxy, the client X-Forwarded-For names is checked" do
      proxied = fn ->
        conn(:get, "/api/state") |> put_req_header("x-forwarded-for", "203.0.113.9") |> call()
      end

      # Untrusted: the header is ignored, the proxy (loopback) is the client.
      assert proxied.().status == 200

      put_env(:trusted_proxies, "127.0.0.1")
      capture_log(fn -> assert proxied.().status == 403 end)
    end
  end

  describe "limits" do
    test "event streams, per client" do
      put_env(:max_streams_per_client, 0)
      conn = conn(:get, "/events") |> call()
      assert conn.status == 503
      assert get_resp_header(conn, "retry-after") == ["10"]
    end

    test "a stream of a missing run counts no more once answered, for a user too" do
      assert (conn(:get, "/events/runs/nope") |> call()).status == 404
      auth_on()
      assert (conn(:get, "/events/runs/nope") |> basic("ada") |> call()).status == 404
      # This process (Plug.Test runs the request in it) holds no stream once answered.
      assert Registry.keys(Testor.StreamRegistry, self()) == []
    end

    test "password hashes at once" do
      auth_on()
      put_env(:max_hashing, 0)
      conn = conn(:get, "/api/state") |> basic("ada") |> call()
      assert conn.status == 503
      assert body(conn)["error"] =~ "too many sign-ins"
      assert (conn(:get, "/api/state") |> basic("nobody") |> call()).status == 503
    end

    test "a user is refused after 30 failures from any addresses; verified credentials still pass" do
      auth_on()
      assert (conn(:get, "/api/state") |> basic("ada") |> call()).status == 200

      capture_log(fn ->
        for i <- 1..30 do
          assert (conn(:get, "/api/state") |> basic("ada", "wrong") |> from({10, 9, 0, i}) |> call()).status ==
                   401
        end

        # Cached: the browser that signed in keeps working.
        assert (conn(:get, "/api/state") |> basic("ada") |> call()).status == 200
        :ets.delete_all_objects(:testor_auth_cache)
        assert (conn(:get, "/api/state") |> basic("ada") |> from({10, 9, 1, 1}) |> call()).status == 429
      end)
    end

    test "a log is read 8 MB at most" do
      assert Testor.Query.max_tail() == 8 * 1024 * 1024
    end
  end

  test "TESTOR_SECRETS_DIR moves auth.json and jwt.key" do
    put_env(:secrets_dir, "/elsewhere")
    assert Auth.auth_file() == Path.join("/elsewhere", "auth.json")
    assert Auth.key_file() == Path.join("/elsewhere", "jwt.key")
    Application.delete_env(:testor, :secrets_dir)
    assert Config.secrets_dir() == Config.data_dir()
  end

  test "plugs initialize" do
    assert Testor.Web.Edge.init(a: 1) == [a: 1]
  end

  describe "symbolic links" do
    @tag :tmp_dir
    test "walks do not follow them even in a loop", %{tmp_dir: root} do
      File.mkdir_p!(Path.join(root, "a"))
      File.write!(Path.join(root, "a/file.txt"), "12345")
      link_dir(root, Path.join(root, "a/loop"))
      on_exit(fn -> Testor.OS.remove_link(Path.join(root, "a/loop")) end)

      assert [%{rel: "a/file.txt"}] = Files.walk(root)
      assert Files.entry(Path.join(root, "a/loop")) == :skip
      assert Files.kind({:error, :enoent}) == :skip
      assert Files.size(Path.join(root, "a/loop")) == 0
      assert Files.mtime(Path.join(root, "a/loop")) == nil
      refute Files.no_links?(root, ["a", "loop", "a", "file.txt"])
      assert Files.no_links?(root, ["a", "file.txt"])
      assert [%{"path" => "a/file.txt"}] = Files.list_artifacts(root, "/artifacts/x")
    end

    test "a run's artifact folder linking to testor's own files serves nothing" do
      id = run_id()
      dir = Path.join(Config.artifacts_dir(), id)
      File.mkdir_p!(dir)
      File.write!(Path.join(Config.data_dir(), "secret.txt"), "jwt key")
      link_dir(Config.data_dir(), Path.join(dir, "home"))

      on_exit(fn ->
        Testor.OS.remove_link(Path.join(dir, "home"))
        File.rm_rf(dir)
        File.rm(Path.join(Config.data_dir(), "secret.txt"))
      end)

      assert (conn(:get, "/artifacts/#{id}/home/secret.txt") |> call()).status == 404
      assert Files.artifacts(id) == []
    end

    test "a log that is a link is read as empty" do
      id = run_id()
      link_dir(Config.data_dir(), Config.log_file(id))
      on_exit(fn -> Testor.OS.remove_link(Config.log_file(id)) end)
      assert Files.log_specs(id) == []
      assert %{text: "", size: 0} = Files.tail(Config.log_file(id), 1024)
    end
  end

  describe "cancelling checks the process first" do
    @now ~U[2026-11-24 10:00:00Z]

    test "kill_check/3" do
      run = %{"pid" => 4242, "startedAt" => "2026-11-24T10:00:00.1234567Z"}
      assert Store.kill_check(run, [1, 2], ~U[2026-11-24 09:59:58Z]) == :kill
      assert Store.kill_check(run, [1, 2], ~U[2026-11-24 10:00:04Z]) == :kill
      assert {:skip, "the record has no valid process id"} = Store.kill_check(%{run | "pid" => "1"}, [], @now)
      assert {:skip, _} = Store.kill_check(%{run | "pid" => 0}, [], @now)
      assert {:skip, "process 4242 is testor or runs it"} = Store.kill_check(run, [4242], @now)
      assert {:skip, "process 4242 has already ended"} = Store.kill_check(run, [], nil)

      assert {:skip, "process 4242 started after the run" <> _} =
               Store.kill_check(run, [], ~U[2026-11-24 10:05:00Z])

      assert Store.kill_check(%{run | "startedAt" => "?"}, [], @now) == :kill
    end

    test "a record naming testor's own process is cancelled without killing it" do
      beam = String.to_integer(System.pid())
      id = record(%{"pid" => beam, "project" => "forged"})

      log = capture_log(fn -> assert {:ok, %{"status" => "cancelled"}} = Store.cancel(id) end)
      assert log =~ "without killing"

      assert Store.get(id)["warning"] ==
               "cancelled without killing a process: process #{beam} is testor or runs it"

      assert Testor.OS.alive?(beam)
    end
  end
end
