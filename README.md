# testor

[![CI](https://github.com/izaccavalheiro/testor/actions/workflows/ci.yml/badge.svg)](https://github.com/izaccavalheiro/testor/actions/workflows/ci.yml)
[![Docs](https://img.shields.io/badge/docs-izaccavalheiro.github.io%2Ftestor-1d4ed8)](https://izaccavalheiro.github.io/testor/)
[![SemVer](https://img.shields.io/badge/semver-2.0.0-blue)](VERSIONING.md)
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)

The free, open-source test orchestrator: run your test suites on another machine over SSH, and
watch them live from any browser, a script or an AI agent.

**Documentation: [izaccavalheiro.github.io/testor](https://izaccavalheiro.github.io/testor/)**
(quick start, every feature, real scenarios, caveats, configuration, the API and the roadmap).

testor turns a spare machine (an old laptop, a mini PC, a Mac on a shelf) into a test runner
for your workstation. Windows, Linux and macOS all work, on either side. You keep editing and
using git where you are; `task test` uploads a snapshot of your working tree to the runner and
runs the command there. **testor**, an Elixir application on the runner, records every run and
streams it to a dashboard over server-sent events. You can follow the log line by line, see
spec files pass or fail as the runner prints them, preview screenshots, cancel a run, and keep
an eye on the machine itself: CPU, memory, GPU, disks, network, battery and the processes each
test run started.

```text
 workstation (any OS)                           runner (Windows, Linux or macOS)
 ┌──────────────────────────┐   SSH (Tailscale   ┌───────────────────────────────────────────┐
 │ editor, git              │   or LAN)          │ sshd → PowerShell 7                       │
 │ task test ───────────────┼──── snapshot ─────▶│  ~/test-run/<project>   (working tree)    │
 │   (taskfiles/remote.yml) │◀─── output, exit ──┤  run.ps1 → runs/, logs/, screenshots/     │
 │                          │                    │                 ▲ reads                   │
 │ browser ◀────────────────┼── HTTP + SSE :6767 ┤  testor (Elixir: Bandit + Plug)           │
 └──────────────────────────┘                    └───────────────────────────────────────────┘
```

Why another machine? To test on the platform your users run (Windows paths, line endings,
file locking, a GPU) without leaving your own OS; to keep a long suite from slowing down your
editor; or to give an idle machine a job.

## What you get

- **Live runs.** Each run's output is streamed to the browser as it is printed, with the spec
  files parsed from it as they finish: Vitest, Playwright (list reporter), pytest, `go test`
  and `cargo test`, with no reporter configuration in your projects.
- **History.** Every run: project, type (the task's name), command, status, exit code,
  duration, spec results, screenshots. Filter, search, delete.
- **Screenshots.** Images a run writes under `test-results/`, `__screenshots__/`,
  `screenshots/` or to `$env:SCREENSHOT_DIR` are kept with the run, matched to their spec
  file and previewed. Old ones are cleaned up automatically, by age and by total size.
- **Artifacts.** Reports and other files a run writes (coverage, Playwright and Vitest HTML
  reports, Markdown, JUnit XML, ...), named with `ARTIFACTS` in the task, are kept with the run
  and opened from the dashboard, as are Playwright's videos. HTML reports run in a sandbox, so
  their scripts cannot use the dashboard's API. Kept by age and total size, like screenshots.
- **Maintenance.** The dashboard measures the space testing leaves on the runner (project
  snapshots no run used lately, old temporary files, the npm, pip, Go and Cargo caches, old
  Playwright browsers) and, once enabled in `config.json`, deletes the targets you choose and
  confirm, never while something runs.
- **Control.** Cancel a run from the dashboard (its whole process tree is killed). A run whose
  SSH session died is marked aborted. Two runs of the same project at once (they would share
  one snapshot folder) are flagged.
- **Device stats.** OS, machine, CPU, memory, GPU, volumes and disk throughput, network,
  battery, the top processes, and the CPU and memory of each test run's process tree, with
  sparklines.
- **API and MCP.** A versioned JSON API (`/api/v1`, with an OpenAPI 3.1 document) for scripts
  and CI, and an MCP server (`/mcp`) so AI agents can list runs, read why one failed (log
  search with context), wait for a run to end, and cancel one. See [docs/api.md](docs/api.md)
  and [docs/mcp.md](docs/mcp.md).
- **Security.** Off until you add a user; then HTTP Basic for the dashboard, JWT bearer tokens
  for programs, roles and scopes, signed file links, rate limiting, CSRF protection and an
  audit log. See [docs/security.md](docs/security.md).
- **Unchanged terminal.** Output, stderr and exit codes reach your terminal exactly as without
  testor; scripts that pipe or parse a task's output keep working.

## Requirements

| Where       | What                                                                                   |
| ----------- | -------------------------------------------------------------------------------------- |
| runner      | Windows 10/11, Linux (with systemd) or macOS; an SSH server; [PowerShell 7](https://learn.microsoft.com/powershell/scripting/install/installing-powershell); Git; Erlang/OTP 27+ and Elixir 1.18+. `runner/setup.ps1` installs or checks them. |
| workstation | any OS with `ssh`, `git`, `tar` and [Task](https://taskfile.dev) (`go-task`) 3.x; on Windows, the built-in OpenSSH client and `tar.exe` will do |
| network     | SSH from the workstation to the runner; [Tailscale](https://tailscale.com) is optional but makes it work from anywhere |

Commands run on the runner in PowerShell 7 on every OS, so a project's tasks are written
once. Scripts travel base64-encoded, whatever the runner's login shell (bash, zsh or
PowerShell).

## Quick start

1. **Prepare the runner.** Install PowerShell 7 if it is not there (on Windows, `setup.ps1`
   runs in the built-in Windows PowerShell and installs it), then:

   ```sh
   # A released setup.ps1 (from 0.3.0), checked against the release's checksums:
   curl -fsSLO https://github.com/izaccavalheiro/testor/releases/latest/download/setup.ps1
   curl -fsSLO https://github.com/izaccavalheiro/testor/releases/latest/download/SHA256SUMS
   sha256sum --ignore-missing -c SHA256SUMS   # or: gh attestation verify setup.ps1 --repo izaccavalheiro/testor
   pwsh setup.ps1 -Check        # what is missing; on Windows: powershell -ExecutionPolicy Bypass -File setup.ps1 -Check
   pwsh setup.ps1               # install it (add -Tailscale to install Tailscale too)
   ```

   Then authorize your workstation's SSH key: see [docs/runner-setup.md](docs/runner-setup.md).

2. **Reach it from the workstation.** Add a host to `~/.ssh/config` and check it:

   ```sshconfig
   Host my-runner
     HostName my-runner            # a Tailscale MagicDNS name, a LAN name or an address
     User runner-user
     IdentityFile ~/.ssh/id_ed25519
   ```

   ```sh
   ssh my-runner pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'   # 7.x
   ```

3. **Install testor.** Clone this repository on the workstation and include its Taskfile from
   your own `~/Taskfile.yml`:

   ```yaml
   version: "3"
   includes:
     testor:
       taskfile: ~/git/testor/taskfiles/testor.yml
       vars: { RUNNER: my-runner }
   ```

   ```sh
   task testor:check     # what the runner still lacks
   task testor:deploy    # build and start testor; open http://my-runner:6767
   ```

4. **Run a project's tests there.** In the project's `Taskfile.yml`:

   ```yaml
   version: "3"
   includes:
     runner:
       taskfile: ~/git/testor/taskfiles/remote.yml
       internal: true
       vars: { RUNNER: my-runner }
   tasks:
     test:
       cmds:
         - task: runner:sync      # upload the working tree
         - task: runner:npm-ci    # npm ci when package-lock.json changed
         - task: runner:exec
           vars: { KIND: test, CMD: "npm test -- {{.CLI_ARGS}}" }
   ```

   `task test` now runs on the runner and shows up on the dashboard. Try it with the example:
   `cd examples/node-project && TESTOR_RUNNER=my-runner task test`.

## Platforms

|                          | Windows                              | Linux                                  | macOS                                   |
| ------------------------ | ------------------------------------ | -------------------------------------- | --------------------------------------- |
| service                  | scheduled task, runs at boot without a login | systemd user service, lingering | launchd agent, runs while the user is logged in |
| firewall                 | rule added for `ALLOW_FROM`           | your own (ufw, firewalld)              | your own (System Settings)             |
| CPU per core, threads    | yes                                  | yes                                    | total only                              |
| GPU load                 | every adapter (performance counters) | NVIDIA (`nvidia-smi`)                  | model only                              |
| disk read/write          | yes                                  | yes                                    | combined I/O                            |
| battery                  | yes                                  | yes                                    | yes                                     |

CI builds, tests and smoke-tests the release on all three.

## Repository layout

| Path                     | What                                                                         |
| ------------------------ | ---------------------------------------------------------------------------- |
| `orchestrator/`          | testor itself: an Elixir/OTP application (Bandit, Plug), released with `mix release` |
| `orchestrator/priv/static/index.html` | the dashboard: one HTML file, no build step, no external requests |
| `orchestrator/priv/sysinfo.ps1` | the Windows device sampler, a long-lived PowerShell the orchestrator talks to |
| `orchestrator/lib/testor/device/unix.ex` | the Linux and macOS device sampler                               |
| `runner/run.ps1`         | wraps a command: records the run, tees its output, collects screenshots      |
| `runner/install.ps1`     | builds the release on the runner and installs it as a service                |
| `runner/setup.ps1`       | prepares a machine as a runner, or reports what is missing (`-Check`)        |
| `taskfiles/testor.yml`   | workstation tasks that manage testor on the runner                           |
| `taskfiles/remote.yml`   | workstation tasks a project includes to run its checks on the runner         |
| `examples/node-project/` | a Vitest project wired to a runner                                           |
| `scripts/smoke.ps1`      | an end-to-end check of a built release                                       |
| `scripts/release.mjs`    | versions: the next one from the commits, bump, check, release notes ([VERSIONING.md](VERSIONING.md)) |
| `docs/`                  | reference: [architecture](docs/architecture.md), [runner setup](docs/runner-setup.md), [workstation and projects](docs/workstation.md), [HTTP and SSE API](docs/api.md), [MCP](docs/mcp.md), [security](docs/security.md) |
| `website/`               | the [documentation site](https://izaccavalheiro.github.io/testor/) (Docusaurus); `docs/` and the root Markdown files are synced into it |

## Security

Authentication is off on a fresh install, so it works at once on a private network; add a user
and it is on:

```sh
read -rs TESTOR_PASSWORD; export TESTOR_PASSWORD
task testor:user USER=ada ROLE=admin      # viewer, operator or admin
task testor:token USER=ada SCOPE=read     # a Bearer token for an MCP client or CI
```

The dashboard then asks for the user name and password (HTTP Basic); programs use Basic or
JSON Web Tokens (HS256) from `POST /api/v1/auth/token`. Roles grant scopes (`read`, `operate`,
`maintain`); passwords are PBKDF2-SHA256 hashes; repeated failures are rate limited;
screenshots and artifacts are reached through signed, expiring links; state-changing requests
from other sites are refused; every change is logged with who made it. Plain HTTP: use it over
Tailscale (encrypted) or behind a TLS proxy with `TESTOR_BIND=127.0.0.1`. On Windows the
installer's firewall rule opens the port only to the Tailscale range and the local subnet
(`ALLOW_FROM`). Nothing in the API starts a command: SSH is the only way commands reach the
runner. Details: [docs/security.md](docs/security.md).

## Development

testor's own checks run on a runner too: `task testor:test` checks formatting, compiles with
warnings as errors and runs the ExUnit suite (unit tests, and integration tests that start the
whole server on a free port, record runs as `run.ps1` does and use it over HTTP, server-sent
events and MCP) with a **100% line coverage** gate. `task testor:smoke` builds a release and
checks it end to end with `scripts/smoke.ps1` (runs through `run.ps1`, the dashboard's and the
versioned API, MCP, cancelling a process tree, maintenance, device stats, authentication set
up with the release's CLI); `task testor:ci` runs both; `task testor:format` formats the sources
on the runner and copies them back. CI runs the same on Windows, Linux and macOS. The platform
adapters (`Testor.OS`, `Testor.Device`, `Testor.Device.Unix`), whose Windows, Linux and macOS
branches cannot all run on one machine, are left out of the coverage gate and checked end to
end by the smoke test on each OS.

## Versions and releases

testor follows [Semantic Versioning](https://semver.org). [VERSIONING.md](VERSIONING.md) says
which surfaces a version covers (the `/api/v1` API, MCP tools, run records, `run.ps1`, the
Taskfiles' variables, configuration files), how Conventional Commits decide the next version,
and how a release is cut from a tag. While testor is 0.x, patch releases are always safe and
breaking changes come only in minor releases, listed under **Breaking** in the
[changelog](CHANGELOG.md). Where it is going: [ROADMAP.md](ROADMAP.md).

## Contributing

Issues and pull requests are welcome: see [CONTRIBUTING.md](CONTRIBUTING.md) and the
[code of conduct](CODE_OF_CONDUCT.md). Report vulnerabilities privately ([SECURITY.md](SECURITY.md)).

## License

[MIT](LICENSE). Free for everyone: no paid edition, no account, no telemetry.
