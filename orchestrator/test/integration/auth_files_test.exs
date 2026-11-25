defmodule Testor.Integration.AuthFilesTest do
  @moduledoc """
  Authentication as an operator sets it up: users added with the CLI into auth.json, the key
  created on first use, the server applying changes without a restart, over real HTTP.
  """
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  import Testor.Test.Helpers
  alias Testor.Auth
  alias Testor.Auth.CLI

  @password "correct horse battery staple"

  setup do
    Testor.Auth.Guard.reset()
    System.put_env("TESTOR_PASSWORD", @password)

    on_exit(fn ->
      System.delete_env("TESTOR_PASSWORD")
      System.delete_env("TESTOR_JWT_SECRET")
      File.rm_rf(Auth.auth_file())
      File.rm_rf(Auth.key_file())
      File.rm(Auth.auth_file() <> ".tmp")
      :persistent_term.erase({Auth, :settings})
    end)
  end

  defp basic(user, password \\ @password),
    do: {"authorization", "Basic " <> Base.encode64("#{user}:#{password}")}

  defp bearer(token), do: {"authorization", "Bearer " <> token}
  defp me(headers), do: http(:get, "/api/v1/auth/me", headers: headers)

  # The server reads auth.json again at most once a second. Polling with wrong credentials
  # counts as failed attempts: the address is forgiven once the change is seen.
  defp applied(fun) do
    wait_until(fun, 5_000)
    Testor.Auth.Guard.reset()
  end

  test "users, tokens, revocation, key rotation and turning it off, end to end" do
    refute Auth.enabled?()
    assert %{status: 200} = me([])

    assert capture_io(fn -> CLI.user("ada", "admin") end) =~ "authentication is on"
    assert File.exists?(Auth.key_file())
    assert capture_io(fn -> CLI.user("val") end) =~ "val (viewer)"

    applied(fn -> me([]).status != 200 end)

    assert %{"user" => "ada", "scopes" => ["read", "operate", "maintain", "execute"]} =
             me([basic("ada")]) |> json()

    assert %{status: 401} = me([basic("ada", "nope")])
    assert %{"ok" => true, "auth" => true} = health = http(:get, "/api/health") |> json()
    refute Map.has_key?(health, "home")

    # A token from the endpoint and one from the CLI.
    %{"access_token" => token} =
      http(:post, "/api/v1/auth/token",
        headers: [basic("val")],
        body: "grant_type=client_credentials",
        type: "application/x-www-form-urlencoded"
      )
      |> json()

    assert %{"user" => "val", "via" => "bearer"} = me([bearer(token)]) |> json()
    cli_token = capture_io(fn -> CLI.token("ada", 1, "read") end) |> String.trim()
    assert %{"scopes" => ["read"]} = me([bearer(cli_token)]) |> json()
    all = capture_io(fn -> CLI.token("ada") end) |> String.trim()
    assert %{"scopes" => ["read", "operate", "maintain", "execute"]} = me([bearer(all)]) |> json()

    # Signed links work without credentials, and only for their run.
    id = record(%{"status" => "passed", "project" => "signed"})
    path = Path.join([Testor.Config.shots_dir(), id, "s.png"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "PNG")
    [shot] = http(:get, "/api/v1/runs/#{id}", headers: [basic("val")]) |> json() |> Map.get("screenshots")
    assert "/s/" <> _ = shot["url"]
    assert %{status: 200, body: "PNG"} = http(:get, shot["url"])
    assert %{status: 401} = http(:get, "/shots/#{id}/s.png")
    assert %{status: 404} = http(:get, String.replace(shot["url"], id, "other-run"))
    assert %{status: 404} = http(:get, "/s/x/shots")

    # The CLI's listing.
    listing = capture_io(fn -> CLI.list() end)
    assert listing =~ "authentication: on"
    assert listing =~ "ada  admin"

    # Revoking ada's tokens leaves val's.
    capture_io(fn -> CLI.revoke("ada") end)
    applied(fn -> me([bearer(cli_token)]).status != 200 end)
    assert %{status: 200} = me([bearer(token)])

    # Rotating the key revokes every token.
    capture_io(fn -> CLI.rotate_key() end)
    applied(fn -> me([bearer(token)]).status != 200 end)

    # Removing a user.
    capture_io(fn -> CLI.remove("val") end)
    applied(fn -> me([basic("val")]).status != 200 end)

    # Off, with the users kept; and on again.
    capture_io(fn -> CLI.enable(false) end)
    applied(fn -> me([]).status == 200 end)
    assert capture_io(fn -> CLI.list() end) =~ "authentication: off"
    capture_io(fn -> CLI.enable() end)
    applied(fn -> me([]).status != 200 end)
  end

  test "the password can come from stdin" do
    System.delete_env("TESTOR_PASSWORD")
    capture_io([input: @password <> "\r\n"], fn -> CLI.user("bob", "operator") end)
    assert %{users: %{"bob" => %{role: "operator"}}} = Auth.load_settings()
    assert_raise CLI.Error, ~r/12 characters/, fn -> capture_io([input: ""], fn -> CLI.user("eve") end) end
  end

  test "the CLI refuses what it cannot do" do
    assert_raise CLI.Error, ~r/user name/, fn -> CLI.user("a b") end
    assert_raise CLI.Error, ~r/role/, fn -> CLI.user("ada", "root") end
    System.put_env("TESTOR_PASSWORD", "short")
    assert_raise CLI.Error, ~r/12 characters/, fn -> CLI.user("ada") end
    assert_raise CLI.Error, ~r/no user/, fn -> CLI.revoke("nobody") end
    assert_raise CLI.Error, ~r/no user/, fn -> CLI.token("nobody") end
    System.put_env("TESTOR_PASSWORD", @password)
    capture_io(fn -> CLI.user("val") end)
    assert_raise CLI.Error, ~r/can have read/, fn -> CLI.token("val", 1, "operate") end
    assert_raise CLI.Error, ~r/days/, fn -> CLI.token("val", 0) end
  end

  test "settings from auth.json: roles, token lifetimes, an explicit switch" do
    hash = Auth.Password.hash(@password, 1000)

    File.write!(
      Auth.auth_file(),
      JSON.encode!(%{
        "enabled" => false,
        "users" => %{
          "ada" => %{"password" => hash, "role" => "wizard", "tokensValidAfter" => 5},
          "bad name" => %{"password" => hash},
          "nohash" => %{"password" => "plain"}
        },
        "tokens" => %{"defaultTtlMinutes" => 5, "maxTtlDays" => 2}
      })
    )

    settings = Auth.load_settings()
    refute settings.enabled
    assert settings.key == nil
    assert %{"ada" => %{scopes: [], valid_after: 5}} = settings.users
    assert map_size(settings.users) == 1
    assert settings.default_ttl == 300
    assert settings.max_ttl == 2 * 86_400

    File.write!(Auth.auth_file(), JSON.encode!(%{"users" => [], "tokens" => []}))
    assert %{enabled: false, users: %{}, default_ttl: 3600} = Auth.load_settings()
  end

  test "a broken auth.json or key locks everything but the health check" do
    File.write!(Auth.auth_file(), "{nope")
    assert %{enabled: true, users: users} = Auth.load_settings()
    assert users == %{}
    applied(fn -> http(:get, "/api/v1/runs").status == 401 end)
    assert %{status: 200} = http(:get, "/api/health")

    File.write!(Auth.auth_file(), "[]")
    assert %{enabled: true, users: %{}} = Auth.load_settings()

    File.rm!(Auth.auth_file())
    File.mkdir_p!(Auth.auth_file())
    assert %{enabled: true, users: %{}} = Auth.load_settings()
    File.rmdir!(Auth.auth_file())

    hash = Auth.Password.hash(@password, 1000)
    File.write!(Auth.auth_file(), JSON.encode!(%{"users" => %{"ada" => %{"password" => hash}}}))
    File.write!(Auth.key_file(), "short")
    assert %{users: %{}} = Auth.load_settings()
    File.rm!(Auth.key_file())
    File.mkdir_p!(Auth.key_file())
    assert %{users: %{}} = Auth.load_settings()
    File.rmdir!(Auth.key_file())

    # TESTOR_JWT_SECRET replaces the key file.
    System.put_env("TESTOR_JWT_SECRET", String.duplicate("e", 40))
    assert %{key: "eeee" <> _} = Auth.load_settings()
    refute File.exists?(Auth.key_file())
  end
end
