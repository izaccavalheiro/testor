#Requires -Version 7
# Installs (or updates) testor on this machine: Windows, Linux or macOS, in PowerShell 7.
# `task testor:deploy` uploads the repository's orchestrator/ and runner/ folders to
# <home>/src and runs this script there. It:
#
#   1. copies run.ps1 to <home>, where the projects' Taskfiles call it;
#   2. builds the release (MIX_ENV=prod) into <home>/app.new while the running one serves on;
#   3. installs a service that starts the release at boot and restarts it if it stops:
#        Windows  the scheduled task "Testor" (S4U logon: no stored password, no one needs to
#                 be logged on) and the firewall rule "Testor (TCP <port>)" for -AllowFrom
#                 (needs an administrator: OpenSSH sessions of one are elevated)
#        Linux    the systemd user unit testor.service, with lingering enabled so it runs
#                 without a login session
#        macOS    the launchd agent dev.testor (~/Library/LaunchAgents): runs while the user
#                 is logged in; enable automatic login for a headless runner
#   4. stops the running release, swaps <home>/app.new in as <home>/app, starts the service
#      and waits for /api/health.
#
#   -Test        runs the ExUnit tests instead (mix test)
#   -Uninstall   removes the service (and on Windows the firewall rule); data is kept
param(
  [switch]$Uninstall,
  [switch]$Test,
  [int]$Port = 6767,
  [string[]]$AllowFrom = @("100.64.0.0/10", "LocalSubnet")
)
$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true

$src = Split-Path $PSScriptRoot          # <home>/src
$testorHome = Split-Path $src             # <home>
$workspaces = Split-Path $testorHome      # the folder of the project snapshots
$app = Join-Path $testorHome "app"
$name = "Testor"
$rule = "Testor (TCP $Port)"
$unit = Join-Path $HOME ".config/systemd/user/testor.service"
$label = "dev.testor"
$plist = Join-Path $HOME "Library/LaunchAgents/$label.plist"

if ($IsWindows) {
  # winget installs Erlang/OTP and Elixir here without touching PATH (setup.ps1 does that).
  foreach ($dir in "C:\Program Files\Erlang OTP\bin", "C:\Program Files\Elixir\bin") {
    if ((Test-Path $dir) -and ($env:Path -notlike "*$dir*")) { $env:Path = "$dir;$env:Path" }
  }
} else {
  # Homebrew, and mise's or asdf's shims: SSH sessions often start without them on the PATH.
  foreach ($dir in "/opt/homebrew/bin", "/usr/local/bin", (Join-Path $HOME ".local/share/mise/shims"), (Join-Path $HOME ".asdf/shims")) {
    if ((Test-Path $dir) -and ($env:PATH -notlike "*$dir*")) { $env:PATH = "${dir}:$env:PATH" }
  }
}

# systemctl --user finds the user's manager through XDG_RUNTIME_DIR, which some sessions lack.
if ($IsLinux -and -not $env:XDG_RUNTIME_DIR) { $env:XDG_RUNTIME_DIR = "/run/user/$(id -u)" }

function Stop-Testor {
  if ($IsWindows) {
    if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) { Stop-ScheduledTask -TaskName $name }
    # Stopping the task ends cmd.exe, not always the VM under it.
    Get-CimInstance Win32_Process -Filter "Name='erl.exe' OR Name='werl.exe'" |
      Where-Object { $_.CommandLine -like "*$app*" } |
      ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  } elseif ($IsLinux) {
    if (Test-Path $unit) { systemctl --user stop testor.service 2>$null }
  } else {
    if (Test-Path $plist) { launchctl bootout "gui/$(id -u)/$label" 2>$null }
  }
  # Whatever still runs from the release.
  if (-not $IsWindows) {
    $PSNativeCommandUseErrorActionPreference = $false
    pkill -f "$app/" 2>$null
    $PSNativeCommandUseErrorActionPreference = $true
  }
  Start-Sleep -Milliseconds 500
}

if ($Uninstall) {
  Stop-Testor
  if ($IsWindows) {
    if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) { Unregister-ScheduledTask -TaskName $name -Confirm:$false }
    Get-NetFirewallRule -DisplayName $rule -ErrorAction SilentlyContinue | Remove-NetFirewallRule
  } elseif ($IsLinux) {
    if (Test-Path $unit) { systemctl --user disable testor.service; Remove-Item $unit; systemctl --user daemon-reload }
  } else {
    if (Test-Path $plist) { Remove-Item $plist }
  }
  "Removed the testor service; $testorHome is kept."
  return
}

if (-not (Get-Command mix -ErrorAction SilentlyContinue)) {
  throw "Elixir is not installed: run runner/setup.ps1"
}

Set-Location (Join-Path $src "orchestrator")
mix local.hex --force --if-missing | Out-Null
mix local.rebar --force --if-missing | Out-Null

if ($Test) {
  $env:MIX_ENV = "test"
  mix deps.get | Out-Null
  mix test --color
  return
}

Copy-Item (Join-Path $PSScriptRoot "run.ps1") (Join-Path $testorHome "run.ps1") -Force

$env:MIX_ENV = "prod"
mix deps.get --only prod | Out-Null
$staging = Join-Path $testorHome "app.new"
if (Test-Path $staging) { Remove-Item -Recurse -Force $staging }
mix release --overwrite --quiet --path $staging

Stop-Testor
if (Test-Path $app) { Remove-Item -Recurse -Force $app }
Move-Item $staging $app

if ($IsWindows) {
  $bat = Join-Path $app "bin\testor.bat"
  $command = "set `"TESTOR_HOME=$testorHome`" && set `"TESTOR_WORKSPACES=$workspaces`" && set `"TESTOR_PORT=$Port`" && `"$bat`" start"
  $action = New-ScheduledTaskAction -Execute "cmd.exe" -Argument "/c $command" -WorkingDirectory $testorHome
  $trigger = New-ScheduledTaskTrigger -AtStartup
  $principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType S4U -RunLevel Limited
  $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
    -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew
  $null = Register-ScheduledTask -TaskName $name -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
    -Description "testor on port $Port ($app)" -Force -ErrorAction Stop
  Get-NetFirewallRule -DisplayName $rule -ErrorAction SilentlyContinue | Remove-NetFirewallRule
  $null = New-NetFirewallRule -DisplayName $rule -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Port `
    -RemoteAddress $AllowFrom -Profile Any
  Start-ScheduledTask -TaskName $name
} elseif ($IsLinux) {
  $null = New-Item -ItemType Directory -Force -Path (Split-Path $unit)
  @"
[Unit]
Description=testor, the test orchestrator (port $Port)
After=network-online.target

[Service]
Environment=TESTOR_HOME=$testorHome
Environment=TESTOR_WORKSPACES=$workspaces
Environment=TESTOR_PORT=$Port
WorkingDirectory=$testorHome
ExecStart=$app/bin/testor start
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
"@ | Set-Content -Path $unit -Encoding utf8NoBOM
  systemctl --user daemon-reload
  systemctl --user enable testor.service | Out-Null
  systemctl --user restart testor.service
  # Without lingering, user services stop at logout and do not start at boot.
  $PSNativeCommandUseErrorActionPreference = $false
  loginctl enable-linger $env:USER 2>$null
  if ($LASTEXITCODE) { Write-Warning "could not enable lingering: run 'sudo loginctl enable-linger $env:USER' so testor runs without a login session" }
  $PSNativeCommandUseErrorActionPreference = $true
} else {
  $null = New-Item -ItemType Directory -Force -Path (Split-Path $plist)
  @"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key><array><string>$app/bin/testor</string><string>start</string></array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>TESTOR_HOME</key><string>$testorHome</string>
    <key>TESTOR_WORKSPACES</key><string>$workspaces</string>
    <key>TESTOR_PORT</key><string>$Port</string>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>WorkingDirectory</key><string>$testorHome</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardErrorPath</key><string>$testorHome/testor.stderr.log</string>
</dict>
</plist>
"@ | Set-Content -Path $plist -Encoding utf8NoBOM
  launchctl bootstrap "gui/$(id -u)" $plist
}

$deadline = (Get-Date).AddSeconds(30)
do {
  Start-Sleep -Milliseconds 500
  try { $health = Invoke-RestMethod "http://127.0.0.1:$Port/api/health" -TimeoutSec 2 } catch { $health = $null }
} until ($health -or (Get-Date) -gt $deadline)
if (-not $health) { throw "testor did not answer on port $Port; see $(Join-Path $testorHome 'testor.log')" }
$hostName = [Environment]::MachineName.ToLower()
"testor $($health.version) (Elixir $($health.elixir), OTP $($health.otp)) on http://${hostName}:$Port"
if (-not $IsWindows) { "No firewall rule was added: allow TCP $Port from your workstation if this machine filters inbound traffic." }
