---
sidebar_position: 4
title: Troubleshooting
description: Symptoms, causes and fixes for the problems people run into most.
---

# Troubleshooting

Start with these two:

```sh
task testor:status     # the service, and health from the runner and from the workstation
task testor:logs       # the end of ~/test-run/.testor/testor.log
```

## Installing and reaching testor

| Symptom | Cause and fix |
| ------- | ------------- |
| `task testor:deploy` says testor did not answer | the release failed to start: `task testor:logs`; on macOS also `testor.stderr.log` |
| health answers on the runner but not from the workstation | a firewall. Windows: the rule allows `ALLOW_FROM` only (Tailscale and the local subnet by default). Linux: `ufw allow from 100.64.0.0/10 to any port 6767`. macOS: allow `beam.smp` |
| `pwsh: command not found` over SSH | PowerShell 7 is not on the PATH of non-interactive SSH sessions: install it system-wide or link it into `/usr/local/bin` |
| `mix` not found when deploying (Linux) | Elixir is only on an interactive shell's PATH: install with mise or asdf (their shims are found) or a system package |
| SSH asks for a password on Windows | an administrator's key belongs in `C:\ProgramData\ssh\administrators_authorized_keys`, with permissions for Administrators and SYSTEM only ([runner setup](../reference/runner-setup.md#3-authorize-the-workstations-key)) |
| a program installed after sshd started is not found (Windows) | the Taskfiles add the registry PATH to each session; restart `sshd` to refresh it for good |
| testor stops when you log out (Linux) | lingering is off: `sudo loginctl enable-linger $USER` |
| testor does not run after a reboot (macOS) | the launchd agent runs in the user's session: turn on automatic login |

## Runs

| Symptom | Cause and fix |
| ------- | ------------- |
| a run does not appear on the dashboard | the task's `runner:exec` has no `KIND`: without it the command runs unrecorded (it shows as a session) |
| a run stays "running" after its terminal closed | it is marked aborted within about 3 seconds of its PowerShell exiting; if not, check `task testor:logs` |
| no spec results | the test runner's output is not one testor reads (a `dot` reporter, a silent mode): see [spec results](../features/spec-results.md) |
| screenshots or artifacts missing | they were not written during the run (older files are ignored), not under a known folder, or over `artifacts.maxRunMB` (the run's warning says so) |
| a run has a warning about another run | two runs of the same project overlapped and shared a snapshot folder |
| `npm ci` is very slow on Windows | Defender scans every file: `setup.ps1 -DefenderExclusion` |
| a build fails with "Permission denied" on its own output (Windows) | antivirus sandboxing new executables; add an exclusion in that product |
| garbled characters in output | the command prints in a legacy code page; `run.ps1` sets UTF-8, but some programs ignore it (set the program's own encoding option) |

## Authentication

| Symptom | Cause and fix |
| ------- | ------------- |
| every request answers 401 after adding a user | expected: authentication is on now; the dashboard asks for the user name and password |
| 403 on cancel or delete | the user or token lacks the scope: `operate` for runs, `maintain` for deleting maintenance targets |
| 429 | 10 failed attempts from that address in 15 minutes; wait for `Retry-After` |
| everything but health answers an error, and the log says `auth.json` or the key cannot be read | testor fails closed: fix or restore the file (`auth.json` must be valid JSON; `jwt.key` 32 bytes) |
| a token stopped working | it expired, its user was revoked or removed, or the key was rotated |
| 403 on a `POST` from a script | it sent no Bearer token, no `X-Testor: 1` header and no JSON body, or another `Origin` |

## Still stuck?

Open an [issue](https://github.com/izaccavalheiro/testor/issues) with the version, both OSes,
what you ran and the log (remove anything private).
