# Prepares a machine as a testor runner, or with -Check only reports what is missing. Runs on
# Windows (Windows PowerShell 5.1 or PowerShell 7, elevated) and on Linux and macOS
# (PowerShell 7: install it first, see docs/runner-setup.md).
#
#   setup.ps1 -Check                                  report only
#   setup.ps1 [-Tailscale] [-DefenderExclusion]       install what is missing
#
# It changes nothing that is already in place:
#   - PowerShell 7 (the shell the tasks' commands run in) and Git
#   - an SSH server: OpenSSH Server on Windows (started at boot, PowerShell 7 as its default
#     shell); openssh-server on Linux; Remote Login on macOS (reported, enable it in System
#     Settings > General > Sharing)
#   - Erlang/OTP 27+ and Elixir 1.18+: winget on Windows, Homebrew on macOS; on Linux the
#     distribution's packages when recent enough, otherwise it explains how to get them (mise)
#   - the workspace folder (default ~/test-run) and testor's home in it (.testor)
#   - -DefenderExclusion (Windows): excludes the workspace folder from Microsoft Defender's
#     real-time scanning, which otherwise scans every file a snapshot or a build writes
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
# $IsWindows does not exist in Windows PowerShell 5.1.
$onWindows = $env:OS -eq "Windows_NT"
$onMac = -not $onWindows -and $IsMacOS

function Report([string]$what, [bool]$ok, [string]$detail = "") {
  $mark = if ($ok) { "ok     " } else { "MISSING" }
  if (-not $ok) { $script:missing++ }
  "{0}  {1}{2}" -f $mark, $what, $(if ($detail) { " ($detail)" } else { "" })
}

function Have([string]$command) { [bool](Get-Command $command -ErrorAction SilentlyContinue) }

# Version of an installed Elixir ("1.18.4"), or $null.
function Get-ElixirVersion {
  if (-not (Have "elixir")) { return $null }
  try { (& elixir -e "IO.write(System.version())" 2>$null | Select-Object -Last 1) } catch { $null }
}

function At-Least([string]$version, [string]$minimum) {
  if (-not $version) { return $false }
  try { return [version]($version -replace "[^0-9.].*$", "") -ge [version]$minimum } catch { return $false }
}

# The package manager of a Linux distribution: apt, dnf, zypper or pacman.
function Get-LinuxInstaller {
  foreach ($pm in "apt-get", "dnf", "zypper", "pacman") { if (Have $pm) { return $pm } }
  return $null
}

function Install-Linux([string[]]$packages) {
  if ($Check) { return }
  switch (Get-LinuxInstaller) {
    "apt-get" { sudo apt-get update -qq; sudo apt-get install -y @packages }
    "dnf" { sudo dnf install -y @packages }
    "zypper" { sudo zypper --non-interactive install @packages }
    "pacman" { sudo pacman -S --noconfirm @packages }
    default { Write-Warning "no known package manager: install $($packages -join ', ') yourself" }
  }
}

function Install-Brew([string[]]$formulas) {
  if ($Check) { return }
  if (-not (Have "brew")) { throw "Homebrew is needed on macOS: https://brew.sh" }
  brew install @formulas
}

function Install-Winget([string]$id) {
  if ($Check) { return }
  winget install --id $id --exact --silent --accept-package-agreements --accept-source-agreements --disable-interactivity
}

"testor runner setup: $(if ($onWindows) { 'Windows' } elseif ($onMac) { 'macOS' } else { 'Linux' })$(if ($Check) { ', check only' })"

if ($onWindows) {
  if ($Check) { "" }
  $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  Report "elevated (administrator) session" $admin
  if (-not $admin -and -not $Check) { throw "run this script in an elevated PowerShell" }

  $pwsh = "C:\Program Files\PowerShell\7\pwsh.exe"
  Report "PowerShell 7" (Test-Path $pwsh) $pwsh
  if (-not (Test-Path $pwsh)) { Install-Winget "Microsoft.PowerShell" }

  $git = (Have "git") -or (Test-Path "C:\Program Files\Git\cmd\git.exe")
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
  Report "SSH keys for administrators" (Test-Path $keys) "${keys}: see docs/runner-setup.md"

  $erl = "C:\Program Files\Erlang OTP\bin"
  Report "Erlang/OTP" (Test-Path "$erl\erl.exe") $erl
  if (-not (Test-Path "$erl\erl.exe")) { Install-Winget "Erlang.ErlangOTP" }
  $ex = "C:\Program Files\Elixir\bin"
  Report "Elixir" (Test-Path "$ex\elixir.bat") $ex
  if (-not (Test-Path "$ex\elixir.bat")) { Install-Winget "Elixir.Elixir" }
  $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine") -split ";"
  $onPath = ($machinePath -contains $erl) -and ($machinePath -contains $ex)
  Report "Erlang/OTP and Elixir on the machine PATH" $onPath
  if (-not $onPath -and -not $Check) {
    $add = @($erl, $ex | Where-Object { $machinePath -notcontains $_ })
    [Environment]::SetEnvironmentVariable("Path", (($machinePath + $add) -join ";"), "Machine")
  }

  if ($DefenderExclusion) {
    $excluded = (Get-MpPreference).ExclusionPath -contains $Workspaces
    Report "Defender excludes the workspace folder" $excluded
    if (-not $excluded -and -not $Check) { Add-MpPreference -ExclusionPath $Workspaces }
  }
  if ($Tailscale -and -not (Have "tailscale")) { Install-Winget "tailscale.tailscale" }
} else {
  if ($onMac) {
    foreach ($dir in "/opt/homebrew/bin", "/usr/local/bin") { if ((Test-Path $dir) -and ($env:PATH -notlike "*$dir*")) { $env:PATH = "${dir}:$env:PATH" } }
    Report "Homebrew" (Have "brew") "https://brew.sh"
  } else {
    foreach ($dir in (Join-Path $HOME ".local/share/mise/shims"), (Join-Path $HOME ".asdf/shims")) { if ((Test-Path $dir) -and ($env:PATH -notlike "*$dir*")) { $env:PATH = "${dir}:$env:PATH" } }
    Report "a package manager" ([bool](Get-LinuxInstaller)) "$(Get-LinuxInstaller)"
  }
  Report "PowerShell 7" ($PSVersionTable.PSVersion.Major -ge 7) "$($PSVersionTable.PSVersion)"
  foreach ($tool in "git", "tar", "curl") {
    Report $tool (Have $tool)
    if (-not (Have $tool)) { if ($onMac) { Install-Brew @($tool) } else { Install-Linux @($tool) } }
  }

  if ($onMac) {
    $PSNativeCommandUseErrorActionPreference = $false
    & nc -z 127.0.0.1 22 2>$null
    $ssh = $LASTEXITCODE -eq 0
    Report "SSH server (Remote Login)" $ssh "System Settings > General > Sharing > Remote Login"
  } else {
    $ssh = (Have "sshd") -or (Test-Path "/usr/sbin/sshd")
    Report "SSH server" $ssh "openssh-server"
    if (-not $ssh) { Install-Linux @("openssh-server") }
    Report "systemd user services" (Have "systemctl") "testor runs as a user service"
  }

  $elixir = Get-ElixirVersion
  $erlang = if (Have "erl") { (& erl -noshell -eval 'io:put_chars(erlang:system_info(otp_release)), halt().' 2>$null) } else { $null }
  Report "Erlang/OTP 27+" (At-Least $erlang "27") "$erlang"
  Report "Elixir 1.18+" (At-Least $elixir "1.18") "$elixir"
  if (-not (At-Least $elixir "1.18")) {
    if ($onMac) { Install-Brew @("erlang", "elixir") }
    elseif (-not $Check) {
      Write-Warning ("Elixir 1.18+ and Erlang/OTP 27+ are needed; distribution packages are often older. With mise " +
        "(https://mise.jdx.dev): mise use -g erlang@27 elixir@1.18-otp-27, then run this script again.")
    }
  }
  if ($Tailscale -and -not (Have "tailscale")) {
    if ($onMac) { Install-Brew @("tailscale") }
    elseif (-not $Check) { sh -c "curl -fsSL https://tailscale.com/install.sh | sh" }
  }
}

Report "workspace folder" (Test-Path $Workspaces) $Workspaces
if (-not $Check) { $null = New-Item -ItemType Directory -Force -Path (Join-Path $Workspaces ".testor") }

if ($Tailscale -or (Have "tailscale")) {
  $ip = if (Have "tailscale") { try { (& tailscale ip -4 2>$null | Select-Object -First 1) } catch { "" } }
  Report "Tailscale (optional)" (Have "tailscale") "$ip"
}

$installed = if ($onWindows) { [bool](Get-ScheduledTask -TaskName Testor -ErrorAction SilentlyContinue) }
  elseif ($onMac) { Test-Path (Join-Path $HOME "Library/LaunchAgents/dev.testor.plist") }
  else { Test-Path (Join-Path $HOME ".config/systemd/user/testor.service") }
Report "testor installed (task testor:deploy)" $installed

if ($Check) { "`n$missing missing" } else { "`nDone.$(if ($onWindows) { ' Restart sshd (Restart-Service sshd) if its default shell changed.' })" }
