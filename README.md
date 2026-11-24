# testor

Run your test suites on another machine over SSH, and watch them live from any browser.

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
- **Control.** Cancel a run from the dashboard (its whole process tree is killed). A run whose
  SSH session died is marked aborted. Two runs of the same project at once (they would share
  one snapshot folder) are flagged.
- **Device stats.** OS, machine, CPU, memory, GPU, volumes and disk throughput, network,
  battery, the top processes, and the CPU and memory of each test run's process tree, with
  sparklines.
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
   curl -fsSLO https://raw.githubusercontent.com/izaccavalheiro/testor/main/runner/setup.ps1
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
| `docs/`                  | [architecture](docs/architecture.md), [runner setup](docs/runner-setup.md), [workstation and projects](docs/workstation.md), [HTTP and SSE API](docs/api.md) |

## Security

testor has no authentication: anyone who can reach its port can read logs, delete runs and
cancel them. On Windows the installer's firewall rule opens the port only to the Tailscale
range (`100.64.0.0/10`) and the local subnet (`ALLOW_FROM` changes that); on Linux and macOS,
restrict it with the system's firewall if the network is not yours. State-changing requests
need an `X-Testor: 1` header, which a cross-site form cannot send. SSH is the only way
commands reach the runner, and testor runs as the installing user (on Windows with a limited
token).

## License

[MIT](LICENSE)
