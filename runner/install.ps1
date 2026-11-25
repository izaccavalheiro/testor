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
#   -Test        checks the sources instead, as CI does: formatting, a compile with warnings as
#                errors, and the ExUnit tests with the coverage gate (mix test --cover)
#   -Smoke       builds the release into a temporary folder (the installed one keeps running)
#                and runs scripts/smoke.ps1 against it: the end-to-end check CI runs
#   -Format      formats the sources in place (mix format), for `task testor:format`
#   -Uninstall   removes the service (and on Windows the firewall rule); data is kept
#
# The service's environment (saved in <home>/service.json, so later deploys keep it; pass ""
# to remove one): -Bind (TESTOR_BIND), -AllowedHosts (TESTOR_ALLOWED_HOSTS), -TrustedProxies
# (TESTOR_TRUSTED_PROXIES), -Anonymous (TESTOR_ANONYMOUS), -SecretsDir (TESTOR_SECRETS_DIR).
param(
  [switch]$Uninstall,
  [switch]$Test,
  [switch]$Format,
  [switch]$Smoke,
  [string[]]$TestArgs = @(),
  [int]$Port = 6767,
  # The service's environment, kept across redeploys: TESTOR_BIND (an address, "" for every
  # interface), TESTOR_ALLOWED_HOSTS, TESTOR_TRUSTED_PROXIES, TESTOR_ANONYMOUS, TESTOR_SECRETS_DIR.
  [string]$Bind = "",
  [string]$AllowedHosts = "",
  [string]$TrustedProxies = "",
  [ValidateSet("", "private", "loopback", "any")][string]$Anonymous = "",
  [string]$SecretsDir = "",
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
  # pkill or launchctl finding nothing to stop is not a failure of this script.
  $global:LASTEXITCODE = 0
  return
}

if (-not (Get-Command mix -ErrorAction SilentlyContinue)) {
  throw "Elixir is not installed: run runner/setup.ps1"
}

Set-Location (Join-Path $src "orchestrator")
mix local.hex --force --if-missing | Out-Null
mix local.rebar --force --if-missing | Out-Null

if ($Format) {
  $env:MIX_ENV = "test"
  mix deps.get | Out-Null
  mix format
  return
}

if ($Test) {
  $env:MIX_ENV = "test"
  mix deps.get | Out-Null
  "== mix format --check-formatted"
  mix format --check-formatted
  "== mix compile --warnings-as-errors"
  mix compile --warnings-as-errors --force
  "== mix test --cover"
  mix test --cover --color @TestArgs
  return
}

if ($Smoke) {
  $env:MIX_ENV = "prod"
  mix deps.get --only prod | Out-Null
  $release = Join-Path ([IO.Path]::GetTempPath()) "testor-smoke-release"
  if (Test-Path $release) { Remove-Item -Recurse -Force $release }
  "== mix release (MIX_ENV=prod) into $release"
  mix release --overwrite --quiet --path $release
  "== scripts/smoke.ps1"
  try { & (Join-Path (Join-Path $src "scripts") "smoke.ps1") -Release $release }
  finally { Remove-Item -Recurse -Force $release -ErrorAction SilentlyContinue }
  return
}

Copy-Item (Join-Path $PSScriptRoot "run.ps1") (Join-Path $testorHome "run.ps1") -Force

# The service's environment: what this call names, else what the last install saved.
$serviceFile = Join-Path $testorHome "service.json"
$serviceEnv = [ordered]@{}
if (Test-Path $serviceFile) {
  (Get-Content -Raw $serviceFile | ConvertFrom-Json -AsHashtable).GetEnumerator() | ForEach-Object { $serviceEnv[$_.Key] = $_.Value }
}
foreach ($pair in @(
    @("TESTOR_BIND", $Bind, $PSBoundParameters.ContainsKey("Bind")),
    @("TESTOR_ALLOWED_HOSTS", $AllowedHosts, $PSBoundParameters.ContainsKey("AllowedHosts")),
    @("TESTOR_TRUSTED_PROXIES", $TrustedProxies, $PSBoundParameters.ContainsKey("TrustedProxies")),
    @("TESTOR_ANONYMOUS", $Anonymous, $PSBoundParameters.ContainsKey("Anonymous")),
    @("TESTOR_SECRETS_DIR", $SecretsDir, $PSBoundParameters.ContainsKey("SecretsDir")))) {
  if (-not $pair[2]) { continue }
  if ($pair[1]) { $serviceEnv[$pair[0]] = $pair[1] } else { $serviceEnv.Remove($pair[0]) }
}
foreach ($value in $serviceEnv.Values) {
  if ($value -match '["\r\n%]') { throw "service settings cannot hold double quotes, percent signs or line breaks: $value" }
}
$serviceEnv | ConvertTo-Json | Set-Content -Path $serviceFile -Encoding utf8NoBOM

$staging = Join-Path $testorHome "app.new"
if (Test-Path $staging) { Remove-Item -Recurse -Force $staging }
$env:MIX_ENV = "prod"
mix deps.get --only prod | Out-Null
mix release --overwrite --quiet --path $staging

Stop-Testor
if (Test-Path $app) { Remove-Item -Recurse -Force $app }
Move-Item $staging $app

if ($IsWindows) {
  $bat = Join-Path $app "bin\testor.bat"
  $extra = ($serviceEnv.GetEnumerator() | ForEach-Object { "set `"$($_.Key)=$($_.Value)`" && " }) -join ""
  $command = "set `"TESTOR_HOME=$testorHome`" && set `"TESTOR_WORKSPACES=$workspaces`" && set `"TESTOR_PORT=$Port`" && $extra`"$bat`" start"
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
  $extra = ($serviceEnv.GetEnumerator() | ForEach-Object { "Environment=`"$($_.Key)=$($_.Value)`"`n" }) -join ""
  @"
[Unit]
Description=testor, the test orchestrator (port $Port)
After=network-online.target

[Service]
Environment=TESTOR_HOME=$testorHome
Environment=TESTOR_WORKSPACES=$workspaces
Environment=TESTOR_PORT=$Port
$extra
WorkingDirectory=$testorHome
ExecStart=$app/bin/testor start
Restart=always
RestartSec=5
# What a user unit can harden without privileges: no privilege gain through setuid programs,
# and files only the user reads.
NoNewPrivileges=yes
UMask=0077

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
  $extra = ($serviceEnv.GetEnumerator() | ForEach-Object {
      "    <key>$($_.Key)</key><string>$([Security.SecurityElement]::Escape($_.Value))</string>`n" }) -join ""
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
$extra    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
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

$healthHost = if ($serviceEnv["TESTOR_BIND"] -and $serviceEnv["TESTOR_BIND"] -notin "0.0.0.0", "::") { $serviceEnv["TESTOR_BIND"] } else { "127.0.0.1" }
if ($healthHost -match ":") { $healthHost = "[$healthHost]" }
$deadline = (Get-Date).AddSeconds(30)
do {
  Start-Sleep -Milliseconds 500
  try { $health = Invoke-RestMethod "http://${healthHost}:$Port/api/health" -TimeoutSec 2 } catch { $health = $null }
} until ($health -or (Get-Date) -gt $deadline)
if (-not $health) { throw "testor did not answer on port $Port; see $(Join-Path $testorHome 'testor.log')" }
$hostName = [Environment]::MachineName.ToLower()
"testor $($health.version) (Elixir $($health.elixir), OTP $($health.otp)) on http://${hostName}:$Port"
if (-not $IsWindows) { "No firewall rule was added: allow TCP $Port from your workstation if this machine filters inbound traffic." }
$global:LASTEXITCODE = 0
