defmodule Testor.SessionsTest do
  use ExUnit.Case, async: true
  alias Testor.Sessions

  # A command line as remote.yml sends it: the prelude and the script, base64-encoded.
  defp encoded(script) do
    prelude = ~S"""
    $ErrorActionPreference = "Stop"
    $workspace = Join-Path (Join-Path $HOME "test-run") "demo"
    $testorRun = Join-Path (Join-Path $HOME "test-run/.testor") "run.ps1"
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
    cmd = ~S|"pwsh.exe" -c "Set-Location \"$HOME\test-run\anonymous-app\"; npm test"|
    assert [%{"project" => "anonymous-app", "command" => "npm test"}] = Sessions.describe({1, "t", cmd})
  end

  test "describe/1 ignores sessions outside the workspace" do
    assert Sessions.describe({1, "t", "pwsh -NoProfile"}) == []
  end

  test "elapsed/1 reads ps's etime" do
    assert Sessions.elapsed("05") == 5
    assert Sessions.elapsed("01:02") == 62
    assert Sessions.elapsed("02:03:04") == 7384
    assert Sessions.elapsed("1-00:00:01") == 86_401
  end
end
