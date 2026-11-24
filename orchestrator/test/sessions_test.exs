defmodule Testor.SessionsTest do
  use ExUnit.Case, async: true
  alias Testor.Sessions

  # The workspaces folder's name (the tests use one of their own).
  defp ws, do: Testor.Config.workspaces_name()

  # A command line as remote.yml sends it: the prelude and the script, base64-encoded.
  defp encoded(script) do
    prelude = """
    $ErrorActionPreference = "Stop"
    $workspace = Join-Path (Join-Path $HOME "#{ws()}") "demo"
    $testorRun = Join-Path (Join-Path $HOME "#{ws()}/.testor") "run.ps1"
    """

    b64 = Base.encode64(prelude <> script)

    ~s|pwsh -NoProfile -NonInteractive -Command &([scriptblock]::Create([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("#{b64}"))))|
  end

  test "describe/1 decodes remote.yml's commands" do
    cmd = encoded("Set-Location $workspace\nnpm run lint\n")

    assert [%{"project" => "demo", "command" => "npm run lint", "pid" => 7}] =
             Sessions.describe({7, "t", cmd})
  end

  test "describe/1 leaves out runs that run.ps1 records" do
    cmd =
      encoded(
        "Set-Location $workspace\n$body = {\nnpm test\n}\nif (Test-Path $testorRun) { & $testorRun -Project \"demo\" }\n"
      )

    assert Sessions.describe({7, "t", cmd}) == []
  end

  test "describe/1 reads older commands sent in clear, with Windows' escaped quotes" do
    cmd = ~S|"pwsh.exe" -c "Set-Location \"$HOME\WS\anonymous-app\"; npm test"| |> String.replace("WS", ws())
    assert [%{"project" => "anonymous-app", "command" => "npm test"}] = Sessions.describe({1, "t", cmd})
  end

  test "describe/1 ignores sessions outside the workspace" do
    assert Sessions.describe({1, "t", "pwsh -NoProfile"}) == []
  end

  test "elapsed/1 reads ps's etime" do
    assert Testor.OS.elapsed("05") == 5
    assert Testor.OS.elapsed("01:02") == 62
    assert Testor.OS.elapsed("02:03:04") == 7384
    assert Testor.OS.elapsed("1-00:00:01") == 86_401
  end
end
