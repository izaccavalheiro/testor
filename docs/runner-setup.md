# Setting up the runner

The runner is a Windows 10/11 machine with an administrator account. Everything below happens
once, at the machine; after that the workstation reaches it over SSH only.

## 1. Run setup.ps1

In an elevated PowerShell (Windows PowerShell 5.1 is fine):

```powershell
Invoke-WebRequest https://raw.githubusercontent.com/izaccavalheiro/testor/main/runner/setup.ps1 -OutFile setup.ps1
powershell -ExecutionPolicy Bypass -File setup.ps1 -Check
powershell -ExecutionPolicy Bypass -File setup.ps1 -DefenderExclusion [-Tailscale]
```

`-Check` changes nothing and lists what is missing. Without it, the script installs what is
missing and leaves the rest alone:

| Item                    | How                                                                     |
| ----------------------- | ----------------------------------------------------------------------- |
| PowerShell 7, Git       | `winget` (`Microsoft.PowerShell`, `Git.Git`)                            |
| OpenSSH Server          | the Windows capability; service set to start automatically              |
| default SSH shell       | `HKLM:\SOFTWARE\OpenSSH\DefaultShell` = PowerShell 7                    |
| Erlang/OTP, Elixir      | `winget` (`Erlang.ErlangOTP`, `Elixir.Elixir`), added to the machine PATH |
| workspace folder        | `~\test-run` (`-Workspaces` changes it) and `~\test-run\.testor`        |
| `-DefenderExclusion`    | excludes the workspace folder from real-time scanning (see below)       |
| `-Tailscale`            | `winget` (`tailscale.tailscale`); then sign in with `tailscale up`      |

Restart the `sshd` service if its default shell changed. Install your projects' own
toolchains (Node.js, Rust, Go, Python, ...) as you would on any machine.

## 2. Authorize the workstation's key

For an account in the Administrators group, OpenSSH on Windows reads keys from one file for all
administrators, not from `~\.ssh\authorized_keys`:

```powershell
# elevated, on the runner; paste the workstation's ~/.ssh/id_ed25519.pub
Add-Content C:\ProgramData\ssh\administrators_authorized_keys "ssh-ed25519 AAAA... you@workstation"
icacls C:\ProgramData\ssh\administrators_authorized_keys /inheritance:r /grant "Administrators:F" /grant "SYSTEM:F"
```

The `icacls` line matters: sshd ignores the file if anyone else can write to it. Disable
password authentication in `C:\ProgramData\ssh\sshd_config` (`PasswordAuthentication no`) once
the key works.

testor needs an administrator account because the installer registers a scheduled task and a
firewall rule; SSH sessions of an administrator are elevated. The orchestrator itself runs
with a limited token.

## 3. Network: Tailscale (optional) or the LAN

- **Tailscale.** Install it on both machines and sign in to the same tailnet. MagicDNS gives the
  runner a name (`my-runner`) that works from anywhere, and the traffic is encrypted end to
  end. testor's firewall rule allows the Tailscale range `100.64.0.0/10` by default.
- **LAN only.** Use the runner's name or address on the local network. The firewall rule
  allows the local subnet by default. Give the runner a fixed address (a DHCP reservation)
  so the SSH config keeps working.

On a laptop, set the power plan so it does not sleep on AC power, and let it keep running with
the lid closed (Control Panel → Power Options → Choose what closing the lid does).

## 4. Defender

Microsoft Defender scans every file a snapshot upload or a build writes, which can make an
`npm ci` several times slower. `-DefenderExclusion` excludes the workspace folder only. Some
third-party antivirus products also sandbox new executables a build produces (native addons,
test binaries); if builds fail with "Permission denied" on their own output, that is the
first thing to check.

## 5. Install testor

From the workstation (see [workstation.md](workstation.md)):

```sh
task testor:check    # setup.ps1 -Check, over SSH
task testor:deploy   # builds the release on the runner and starts it
```

`deploy` uploads `orchestrator/` and `runner/` to `~\test-run\.testor\src`, builds the release
there, and installs:

- the scheduled task **Testor**: runs the release at boot, whether or not anyone is logged on
  (S4U logon: no stored password), restarted if it fails, never stopped for running on battery;
- the firewall rule **Testor (TCP 6767)**: inbound, for the addresses in `ALLOW_FROM`.

Redeploying swaps the new release in after it is built, so the dashboard is down for a few
seconds. `task testor:uninstall` removes the task and the rule and keeps the data.

## Troubleshooting

| Symptom                                      | Look at                                                   |
| -------------------------------------------- | --------------------------------------------------------- |
| `task testor:deploy` says testor did not answer | `task testor:logs` (`~\test-run\.testor\testor.log`)    |
| the dashboard does not load from the workstation | `task testor:status`: health from the runner itself, then from the workstation; then the firewall rule's addresses |
| a program installed after sshd started is not found | the Taskfiles append the registry PATH to each session; restart `sshd` to refresh it for good |
| odd characters in output                     | `run.ps1` switches the console to UTF-8; commands run without it use the console code page |
| a run stays "running" after its terminal closed | it is marked aborted within 3 s of its PowerShell exiting; a session sshd keeps alive is still running |
