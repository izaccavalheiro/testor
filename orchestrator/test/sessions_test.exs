defmodule Testor.SessionsTest do
  use ExUnit.Case, async: true
  alias Testor.Sessions

  # The workspaces folder's name (the tests use one of their own).
  defp ws, do: Testor.Config.workspaces_name()

  # A command line as remote.yml sends it: the prelude and the script, base64-encoded.
  defp encoded(script, workspaces \\ ws()) do
    prelude = """
    $ErrorActionPreference = "Stop"
    $workspace = Join-Path ([IO.Path]::Combine($HOME, "#{workspaces}")) "demo"
    $testorRun = Join-Path ([IO.Path]::Combine($HOME, "#{workspaces}/.testor")) "run.ps1"
    """

    b64 = Base.encode64(prelude <> script)

    ~s|pwsh -NoProfile -NonInteractive -Command &([scriptblock]::Create([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("#{b64}"))))|
  end

  test "describe/1 decodes remote.yml's commands" do
    cmd = encoded("Set-Location $workspace\nnpm run lint\n")

    assert [%{"project" => "demo", "command" => "npm run lint", "pid" => 7}] =
             Sessions.describe({7, "t", cmd})
  end

  test "describe/1 finds the project of an absolute workspaces folder, and of the older prelude" do
    absolute = encoded("Set-Location $workspace\nnpm ci\n", "/srv/#{ws()}")
    assert [%{"project" => "demo", "command" => "npm ci"}] = Sessions.describe({7, "t", absolute})

    older = """
    $workspace = Join-Path (Join-Path $HOME "#{ws()}") "legacy"
    $testorRun = Join-Path (Join-Path $HOME "#{ws()}/.testor") "run.ps1"
    Set-Location $workspace
    npm ci
    """

    cmd =
      ~s|pwsh -Command &([scriptblock]::Create([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("#{Base.encode64(older)}"))))|

    assert [%{"project" => "legacy", "command" => "npm ci"}] = Sessions.describe({7, "t", cmd})
  end

  test "describe/1 leaves out runs that run.ps1 records" do
    cmd =
      encoded(
        "Set-Location $workspace\n$body = {\nnpm test\n}\nif (Test-Path $testorRun) { & $testorRun -Project \"demo\" }\n"
      )

    assert Sessions.describe({7, "t", cmd}) == []
  end

  test "describe/1 leaves out testor.yml's sessions in testor's own home" do
    # testor.yml's prelude: Join-Path $HOME "<workspaces>/.testor", then its upload or deploy.
    script = """
    $testorHome = Join-Path $HOME "#{ws()}/#{Path.basename(Testor.Config.data_dir())}"
    $src = Join-Path $testorHome "src"
    tar -xzf - -C $src
    """

    b64 = Base.encode64(script)

    cmd =
      ~s|pwsh -NoProfile -Command &([scriptblock]::Create([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("#{b64}"))))|

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
