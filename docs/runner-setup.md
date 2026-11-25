# Setting up the runner

The runner is a Windows 10/11, Linux (with systemd) or macOS machine. Everything below happens
once, at the machine; after that the workstation reaches it over SSH only.

## 1. PowerShell 7

Commands run in PowerShell 7 on every runner, so the same tasks work on all of them.

| OS      | How                                                                                     |
| ------- | --------------------------------------------------------------------------------------- |
| Windows | `setup.ps1` installs it (it runs in the built-in Windows PowerShell 5.1)                 |
| macOS   | `brew install powershell`                                                                |
| Linux   | Microsoft's packages: [installing PowerShell on Linux](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-linux) (apt, dnf, zypper), or `sudo snap install powershell --classic` |

## 2. Run setup.ps1

```sh
curl -fsSLO https://raw.githubusercontent.com/izaccavalheiro/testor/main/runner/setup.ps1
pwsh setup.ps1 -Check
pwsh setup.ps1 [-Tailscale]
```

On Windows, in an elevated Windows PowerShell:

```powershell
Invoke-WebRequest https://raw.githubusercontent.com/izaccavalheiro/testor/main/runner/setup.ps1 -OutFile setup.ps1
powershell -ExecutionPolicy Bypass -File setup.ps1 -Check
powershell -ExecutionPolicy Bypass -File setup.ps1 -DefenderExclusion [-Tailscale]
```

`-Check` changes nothing and lists what is missing. Without it, the script installs what is
missing and leaves the rest alone:

| Item                 | Windows                                   | Linux                              | macOS                         |
| -------------------- | ----------------------------------------- | ---------------------------------- | ----------------------------- |
| PowerShell 7, Git    | winget                                    | Git: apt, dnf, zypper or pacman    | Homebrew                      |
| SSH server           | OpenSSH Server capability, started at boot, PowerShell 7 as its default shell | `openssh-server` | reported: turn on Remote Login (System Settings > General > Sharing) |
| Erlang/OTP 27+, Elixir 1.18+ | winget, added to the machine PATH | checked; see below                 | Homebrew                      |
| workspace folder     | `~/test-run` and `~/test-run/.testor` (`-Workspaces` changes it) | same | same |
| `-DefenderExclusion` | excludes the workspace from real-time scanning (see below) | n/a | n/a              |
| `-Tailscale`         | winget                                    | Tailscale's install script         | Homebrew                      |

**Erlang and Elixir on Linux.** Distribution packages are often older than testor needs
(Ubuntu 24.04 ships Elixir 1.14). [mise](https://mise.jdx.dev) installs current ones for the
runner's user:

```sh
curl https://mise.run | sh
~/.local/bin/mise use -g erlang@27 elixir@1.18-otp-27
```

testor's installer finds mise's and asdf's shims; the installed service carries its own
Erlang runtime, so it does not depend on them.

Install your projects' own toolchains (Node.js, Rust, Go, Python, ...) as you would on any
machine.

## 3. Authorize the workstation's key

**Linux and macOS:** append the workstation's public key (`~/.ssh/id_ed25519.pub`) to the
runner user's `~/.ssh/authorized_keys` (`ssh-copy-id runner-user@my-runner` does it).

**Windows:** for an account in the Administrators group, OpenSSH reads keys from one file for
all administrators, not from `~\.ssh\authorized_keys`:

```powershell
# elevated, on the runner; paste the workstation's ~/.ssh/id_ed25519.pub
Add-Content C:\ProgramData\ssh\administrators_authorized_keys "ssh-ed25519 AAAA... you@workstation"
icacls C:\ProgramData\ssh\administrators_authorized_keys /inheritance:r /grant "Administrators:F" /grant "SYSTEM:F"
```

The `icacls` line matters: sshd ignores the file if anyone else can write to it. On Windows
testor needs an administrator account, because the installer registers a scheduled task and a
firewall rule (SSH sessions of an administrator are elevated); the orchestrator itself runs
with a limited token. On Linux and macOS an ordinary account is enough.

Turn off password authentication (`PasswordAuthentication no` in `sshd_config`) once the key
works.

## 4. Network: Tailscale (optional) or the LAN

- **Tailscale.** Install it on both machines and sign in to the same tailnet. MagicDNS gives the
  runner a name (`my-runner`) that works from anywhere, and the traffic is encrypted end to
  end. On Windows, testor's firewall rule allows the Tailscale range `100.64.0.0/10` by default.
- **LAN only.** Use the runner's name or address on the local network, and give it a fixed
  address (a DHCP reservation) so the SSH config keeps working. On Windows the firewall rule
  allows the local subnet by default.

On Linux and macOS testor adds no firewall rule: if the runner filters inbound traffic, allow
TCP 6767 from your workstation (`sudo ufw allow from 100.64.0.0/10 to any port 6767`, or the
macOS firewall's prompt for `beam.smp`).

A laptop runner should not sleep on AC power: on Windows, set the lid action to "Do nothing";
on macOS, turn off sleep on the power adapter (`sudo pmset -c sleep 0`); on Linux,
`HandleLidSwitchExternalPower=ignore` in `/etc/systemd/logind.conf`.

## 5. Antivirus on Windows

Microsoft Defender scans every file a snapshot upload or a build writes, which can make an
`npm ci` several times slower. `-DefenderExclusion` excludes the workspace folder only. Some
third-party antivirus products also sandbox new executables a build produces (native addons,
test binaries); if builds fail with "Permission denied" on their own output, that is the
first thing to check.

## 6. Install testor

From the workstation (see [workstation.md](workstation.md)):

```sh
task testor:check    # setup.ps1 -Check, over SSH
task testor:deploy   # builds the release on the runner and starts it
```

`deploy` uploads `orchestrator/` and `runner/` to `~/test-run/.testor/src`, builds the release
there and installs a service:

| OS      | Service                                                                                  |
| ------- | ---------------------------------------------------------------------------------------- |
| Windows | scheduled task **Testor**: at boot, whether or not anyone is logged on (S4U: no stored password), restarted if it fails, never stopped on battery; firewall rule **Testor (TCP 6767)** for `ALLOW_FROM` |
| Linux   | systemd user unit **testor.service** (`systemctl --user status testor`), restarted if it stops; lingering is enabled so it runs at boot without a login (it asks for `sudo loginctl enable-linger` when it cannot do it itself) |
| macOS   | launchd agent **dev.testor** (`~/Library/LaunchAgents`), kept alive; it runs while the user is logged in, so turn on automatic login for a runner nobody sits at |

Redeploying swaps the new release in after it is built, so the dashboard is down for a few
seconds. `task testor:uninstall` removes the service and keeps the data.

### Without Elixir: a prebuilt release

From 0.3.0 every GitHub release carries the orchestrator built for Windows (x64), Linux (x64)
and macOS (arm64), and the runner's scripts. On the runner, with only PowerShell 7:

```sh
curl -fsSLO https://github.com/izaccavalheiro/testor/releases/latest/download/install.ps1
pwsh install.ps1 -FromRelease latest            # or a version: -FromRelease 0.3.0
```

The installer downloads the archive for the machine and `run.ps1`, refuses them unless they
match the release's `SHA256SUMS`, and, with the [GitHub CLI](https://cli.github.com) on the
PATH, unless their provenance attestation shows they were built by this repository's release
workflow (`-RequireAttestation` makes that check mandatory). It installs the same service as
`deploy`, with the same options (`-Bind`, `-AllowedHosts`, ...), in `~/test-run/.testor` or
`-TestorHome`.

### In a container

`orchestrator/Dockerfile` builds an image that runs as an unprivileged user on a read-only
root file system; tagged releases publish it as `ghcr.io/izaccavalheiro/testor`. See
[examples/compose](../examples/compose/README.md).

## Troubleshooting

| Symptom                                      | Look at                                                   |
| -------------------------------------------- | --------------------------------------------------------- |
| `task testor:deploy` says testor did not answer | `task testor:logs` (`~/test-run/.testor/testor.log`); on macOS also `testor.stderr.log` |
| the dashboard does not load from the workstation | `task testor:status`: health from the runner itself, then from the workstation; then the firewall |
| `pwsh: command not found` over SSH          | PowerShell 7 is not on the PATH of non-interactive SSH sessions: install it system-wide, or link it into `/usr/local/bin` |
| `mix` not found when deploying (Linux)      | Elixir installed in an interactive shell's PATH only: use mise or asdf (their shims are found), or a system package |
| a program installed after sshd started is not found (Windows) | the Taskfiles append the registry PATH to each session; restart `sshd` to refresh it for good |
| a run stays "running" after its terminal closed | it is marked aborted within 3 s of its PowerShell exiting |
