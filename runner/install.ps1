# Installs (or updates) testor on this Windows machine. `task testor:deploy` uploads the
# repository's orchestrator\ and runner\ folders to <home>\src and runs this script there, as
# an administrator (an OpenSSH session of an admin account is elevated). It:
#
#   1. copies run.ps1 to <home>, where the projects' Taskfiles call it;
#   2. builds the release (MIX_ENV=prod) into <home>\app.new while the running one serves on;
#   3. registers the scheduled task "Testor": the release, at boot, whether or not anyone is
#      logged on (S4U, no stored password), restarted if it fails; and an inbound firewall
#      rule for the port, open to -AllowFrom only (the tailnet and the local subnet);
#   4. stops the running release, swaps <home>\app.new in as <home>\app, starts the task and
#      waits for /api/health.
#
#   -Test        runs the ExUnit tests instead (mix test)
#   -Uninstall   removes the task and the firewall rule; runs, logs and screenshots are kept
param(
  [switch]$Uninstall,
  [switch]$Test,
  [int]$Port = 6767,
  [string[]]$AllowFrom = @("100.64.0.0/10", "LocalSubnet")
)
$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true

$name = "Testor"
$rule = "Testor (TCP $Port)"
$src = Split-Path $PSScriptRoot          # <home>\src
$testorHome = Split-Path $src             # <home>
$app = Join-Path $testorHome "app"

# winget installs Erlang/OTP and Elixir here without touching PATH (setup.ps1 does that).
foreach ($dir in "C:\Program Files\Erlang OTP\bin", "C:\Program Files\Elixir\bin") {
  if ((Test-Path $dir) -and ($env:Path -notlike "*$dir*")) { $env:Path = "$dir;$env:Path" }
}

function Stop-Testor {
  if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) { Stop-ScheduledTask -TaskName $name }
  # Stopping the task ends cmd.exe, not always the VM under it.
  Get-CimInstance Win32_Process -Filter "Name='erl.exe' OR Name='werl.exe'" |
    Where-Object { $_.CommandLine -like "*$app*" } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  Start-Sleep -Milliseconds 500
}

if ($Uninstall) {
  Stop-Testor
  if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) { Unregister-ScheduledTask -TaskName $name -Confirm:$false }
  Get-NetFirewallRule -DisplayName $rule -ErrorAction SilentlyContinue | Remove-NetFirewallRule
  "Removed the scheduled task and the firewall rule; $testorHome is kept."
  return
}

if (-not (Get-Command mix -ErrorAction SilentlyContinue)) {
  throw "Elixir is not installed: run runner\setup.ps1 (or winget install Erlang.ErlangOTP Elixir.Elixir)"
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

$bat = Join-Path $app "bin\testor.bat"
# The release reads TESTOR_HOME, TESTOR_WORKSPACES (the home's parent) and TESTOR_PORT.
$workspaces = Split-Path $testorHome
$command = "set `"TESTOR_HOME=$testorHome`" && set `"TESTOR_WORKSPACES=$workspaces`" && set `"TESTOR_PORT=$Port`" && `"$bat`" start"
$action = New-ScheduledTaskAction -Execute "cmd.exe" -Argument "/c $command" -WorkingDirectory $testorHome
$trigger = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType S4U -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
  -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew

Stop-Testor
if (Test-Path $app) { Remove-Item -Recurse -Force $app }
Move-Item $staging $app

$null = Register-ScheduledTask -TaskName $name -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
  -Description "testor on port $Port ($app)" -Force -ErrorAction Stop
Get-NetFirewallRule -DisplayName $rule -ErrorAction SilentlyContinue | Remove-NetFirewallRule
$null = New-NetFirewallRule -DisplayName $rule -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Port `
  -RemoteAddress $AllowFrom -Profile Any
Start-ScheduledTask -TaskName $name

$deadline = (Get-Date).AddSeconds(30)
do {
  Start-Sleep -Milliseconds 500
  try { $health = Invoke-RestMethod "http://127.0.0.1:$Port/api/health" -TimeoutSec 2 } catch { $health = $null }
} until ($health -or (Get-Date) -gt $deadline)
if (-not $health) { throw "testor did not answer on port $Port; see $testorHome\testor.log" }
"testor $($health.version) (Elixir $($health.elixir), OTP $($health.otp)) on http://$($env:COMPUTERNAME.ToLower()):$Port"
