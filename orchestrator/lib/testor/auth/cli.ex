defmodule Testor.Auth.CLI.Error do
  defexception [:message]
end

defmodule Testor.Auth.CLI do
  @moduledoc """
  Manages users, tokens and the signing key on the runner, through the release (on Windows
  `bin\\testor.bat`). `task testor:user` and `task testor:token` run these from the workstation.

      bin/testor eval 'Testor.Auth.CLI.user("ada", "admin")'   # add or change; password from stdin
      bin/testor eval 'Testor.Auth.CLI.remove("ada")'
      bin/testor eval 'Testor.Auth.CLI.revoke("ada")'          # her tokens issued until now stop working
      bin/testor eval 'Testor.Auth.CLI.token("ada", 30)'       # prints a token valid 30 days
      bin/testor eval 'Testor.Auth.CLI.token("ada", 30, "read")'
      bin/testor eval 'Testor.Auth.CLI.rotate_key()'           # revokes every token and file link
      bin/testor eval 'Testor.Auth.CLI.list()'

  The password comes from `TESTOR_PASSWORD` or the first line of stdin, never from the command
  line, where other users of the machine could see it. A running testor applies every change
  within a second. A refused change raises `Testor.Auth.CLI.Error`, which `eval` prints and
  exits with a non-zero status.
  """
  alias Testor.Auth
  alias Testor.Auth.Password

  @min_password 12

  @doc "Adds `name` with `role`, or changes their password and role."
  def user(name, role \\ "viewer") do
    cond do
      not Auth.valid_name?(name) ->
        fail("a user name is 1 to 64 letters, digits, or _ . @ -")

      Auth.role_scopes(role) == nil ->
        fail("the role is one of #{Enum.join(Auth.roles(), ", ")}")

      true ->
        password = read_password()

        if String.length(password) < @min_password do
          fail("the password needs #{@min_password} characters or more")
        else
          update(fn raw ->
            users = Map.get(raw, "users", %{})

            entry =
              Map.merge(Map.get(users, name, %{}), %{"password" => Password.hash(password), "role" => role})

            Map.put(raw, "users", Map.put(users, name, entry))
          end)

          Auth.key!()
          IO.puts("#{name} (#{role}) saved in #{Auth.auth_file()}; authentication is on")
        end
    end
  end

  @doc "Removes `name`; their tokens stop working."
  def remove(name) do
    update(fn raw -> Map.update(raw, "users", %{}, &Map.delete(&1, name)) end)
    IO.puts("#{name} removed")
  end

  @doc "Forgets the signing key pinned to agent `name`: its next lease pins the key it presents."
  def forget_agent_key(name) do
    if Testor.AgentKeys.forget(name),
      do: IO.puts("the key of #{name} is forgotten: its next lease pins a new one"),
      else: IO.puts("#{name} has no pinned key")
  end

  @doc "Revokes every token `name` holds now."
  def revoke(name) do
    now = System.system_time(:second)

    update(fn raw ->
      case raw do
        %{"users" => %{^name => user} = users} ->
          Map.put(raw, "users", Map.put(users, name, Map.put(user, "tokensValidAfter", now + 1)))

        _ ->
          fail("no user #{name}")
      end
    end)

    IO.puts("tokens of #{name} issued until now are revoked")
  end

  @doc "Prints a Bearer token for `name`, valid `days`, with `scope` (the role's by default)."
  def token(name, days \\ 30, scope \\ nil) do
    settings = %{Auth.load_settings() | key: Auth.key!()}

    case settings.users[name] do
      nil ->
        fail("no user #{name}")

      user ->
        scopes = if scope, do: String.split(scope, " ", trim: true), else: user.scopes

        cond do
          scopes == [] or not Enum.all?(scopes, &(&1 in user.scopes)) ->
            fail("#{name} (#{user.role}) can have #{Enum.join(user.scopes, " ")}")

          not is_number(days) or days <= 0 ->
            fail("days must be a positive number")

          true ->
            ttl = round(days * 86_400)
            IO.puts(Auth.mint(name, scopes, ttl, settings)["access_token"])
        end
    end
  end

  @doc "Replaces the signing key: every token and every file link stops working."
  def rotate_key do
    path = Auth.key_file()
    _ = File.rm(path)
    Auth.key!()
    IO.puts("new key in #{path}; every token is revoked")
  end

  @doc "Lists the users and whether authentication is on."
  def list do
    settings = Auth.load_settings()
    IO.puts("authentication: #{if settings.enabled, do: "on", else: "off"} (#{Auth.auth_file()})")

    for {name, user} <- Enum.sort(settings.users) do
      IO.puts("  #{name}  #{user.role}  [#{Enum.join(user.scopes, " ")}]")
    end

    :ok
  end

  @doc "Turns authentication off (`false`) or back on, keeping the users."
  def enable(on \\ true) when is_boolean(on) do
    update(&Map.put(&1, "enabled", on))
    IO.puts("authentication #{if on, do: "on", else: "off"}")
  end

  # Reads, changes and writes auth.json (replacing it in one rename, readable by its owner only).
  defp update(fun) do
    path = Auth.auth_file()
    raw = Auth.read_raw() |> fun.()
    File.mkdir_p!(Path.dirname(path))
    tmp = path <> ".tmp"
    File.write!(tmp, [:json.format(raw), "\n"])
    _ = File.chmod(tmp, 0o600)
    File.rename!(tmp, path)
  end

  defp read_password do
    case System.get_env("TESTOR_PASSWORD") do
      value when is_binary(value) and value != "" ->
        value

      _ ->
        case IO.gets("") do
          line when is_binary(line) -> String.trim_trailing(line, "\n") |> String.trim_trailing("\r")
          _ -> ""
        end
    end
  end

  defp fail(message), do: raise(Testor.Auth.CLI.Error, message)
end
