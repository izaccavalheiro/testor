# Prepares a Windows 10/11 machine as a testor runner, or with -Check only reports what is
# missing. Run it once, at the machine, in an elevated PowerShell (winget needs a desktop
# session the first time):
#
#   powershell -ExecutionPolicy Bypass -File setup.ps1 -Check
#   powershell -ExecutionPolicy Bypass -File setup.ps1 [-Tailscale] [-DefenderExclusion]
#
# It installs what is missing and changes nothing that is already in place:
#   - PowerShell 7 (the shell the tasks' commands run in) and Git
#   - OpenSSH Server, started at boot, with PowerShell 7 as its default shell
#   - Erlang/OTP and Elixir (testor's orchestrator), added to the machine PATH
#   - the workspace folder (default ~\test-run) and testor's home in it (.testor)
#   - -DefenderExclusion: excludes the workspace folder from Microsoft Defender real-time
#     scanning, which otherwise scans every file a snapshot upload or a build writes
#   - -Tailscale: installs Tailscale; sign in afterwards with `tailscale up`
# Project toolchains (Node.js, Rust, Go, Python, ...) are the projects' business.
param(
  [switch]$Check,
  [switch]$Tailscale,
  [switch]$DefenderExclusion,
  [string]$Workspaces = (Join-Path $HOME "test-run")
)
$ErrorActionPreference = "Stop"
$missing = 0

function Report([string]$what, [bool]$ok, [string]$detail = "") {
  $mark = if ($ok) { "ok     " } else { "MISSING" }
  if (-not $ok) { $script:missing++ }
  "{0}  {1}{2}" -f $mark, $what, $(if ($detail) { " ($detail)" } else { "" })
}

function Install-Winget([string]$id) {
  if ($Check) { return }
  winget install --id $id --exact --silent --accept-package-agreements --accept-source-agreements --disable-interactivity
}

function Add-MachinePath([string]$dir) {
  $path = [Environment]::GetEnvironmentVariable("Path", "Machine")
  if ((Test-Path $dir) -and ($path -split ";") -notcontains $dir) {
    if (-not $Check) { [Environment]::SetEnvironmentVariable("Path", "$path;$dir", "Machine") }
    return $false
  }
  return $true
}

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Report "elevated (administrator) session" $admin
if (-not $admin -and -not $Check) { throw "run this script in an elevated PowerShell" }

$pwsh = "C:\Program Files\PowerShell\7\pwsh.exe"
$hasPwsh = Test-Path $pwsh
Report "PowerShell 7" $hasPwsh $pwsh
if (-not $hasPwsh) { Install-Winget "Microsoft.PowerShell" }

$git = [bool](Get-Command git -ErrorAction SilentlyContinue) -or (Test-Path "C:\Program Files\Git\cmd\git.exe")
Report "Git" $git
if (-not $git) { Install-Winget "Git.Git" }

$sshd = Get-Service sshd -ErrorAction SilentlyContinue
Report "OpenSSH Server" ([bool]$sshd) $(if ($sshd) { "$($sshd.Status), $($sshd.StartType)" })
if (-not $sshd -and -not $Check) {
  Add-WindowsCapability -Online -Name (Get-WindowsCapability -Online -Name "OpenSSH.Server*").Name | Out-Null
  $sshd = Get-Service sshd
}
if ($sshd -and -not $Check) {
  Set-Service sshd -StartupType Automatic
  if ($sshd.Status -ne "Running") { Start-Service sshd }
}

$shell = (Get-ItemProperty "HKLM:\SOFTWARE\OpenSSH" -Name DefaultShell -ErrorAction SilentlyContinue).DefaultShell
Report "OpenSSH default shell is PowerShell 7" ($shell -eq $pwsh) $shell
if ($shell -ne $pwsh -and -not $Check -and (Test-Path $pwsh)) {
  New-ItemProperty "HKLM:\SOFTWARE\OpenSSH" -Name DefaultShell -Value $pwsh -PropertyType String -Force | Out-Null
}

$keys = "C:\ProgramData\ssh\administrators_authorized_keys"
Report "SSH keys for administrators" (Test-Path $keys) "${keys}: add your workstation's public key, see docs/runner-setup.md"

$erl = "C:\Program Files\Erlang OTP\bin"
Report "Erlang/OTP" (Test-Path "$erl\erl.exe") $erl
if (-not (Test-Path "$erl\erl.exe")) { Install-Winget "Erlang.ErlangOTP" }
$ex = "C:\Program Files\Elixir\bin"
Report "Elixir" (Test-Path "$ex\elixir.bat") $ex
if (-not (Test-Path "$ex\elixir.bat")) { Install-Winget "Elixir.Elixir" }
Report "Erlang/OTP and Elixir on the machine PATH" ((Add-MachinePath $erl) -and (Add-MachinePath $ex))

Report "workspace folder" (Test-Path $Workspaces) $Workspaces
if (-not $Check) { $null = New-Item -ItemType Directory -Force -Path (Join-Path $Workspaces ".testor") }

if ($DefenderExclusion) {
  $excluded = (Get-MpPreference).ExclusionPath -contains $Workspaces
  Report "Defender excludes the workspace folder" $excluded
  if (-not $excluded -and -not $Check) { Add-MpPreference -ExclusionPath $Workspaces }
}

$ts = Get-Command tailscale -ErrorAction SilentlyContinue
if ($Tailscale -or $ts) {
  Report "Tailscale (optional)" ([bool]$ts) $(if ($ts) { (tailscale ip -4 2>$null | Select-Object -First 1) })
  if (-not $ts -and $Tailscale) { Install-Winget "tailscale.tailscale" }
}

$testor = Get-ScheduledTask -TaskName Testor -ErrorAction SilentlyContinue
Report "testor installed (task testor:deploy)" ([bool]$testor) $(if ($testor) { "$($testor.State)" })

if ($Check) { "`n$missing missing" } else { "`nDone. Restart sshd (Restart-Service sshd) if its default shell changed." }
