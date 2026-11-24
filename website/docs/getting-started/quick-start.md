---
sidebar_position: 1
title: Quick start
description: Prepare a runner, install testor on it, and run a project's tests there from your workstation.
---

# Quick start

About 15 minutes, most of it installing software on the runner. You need:

| Where | What |
| ----- | ---- |
| **runner** | Windows 10/11, Linux with systemd, or macOS; an SSH server; PowerShell 7; Git; Erlang/OTP 27+ and Elixir 1.18+ (step 1 installs or checks them) |
| **workstation** | any OS with `ssh`, `git`, `tar` and [Task](https://taskfile.dev) 3.x |
| **network** | SSH from the workstation to the runner; [Tailscale](https://tailscale.com) optional |

## 1. Prepare the runner

At the runner, install PowerShell 7 if it is missing (on Windows, the setup script does it
from the built-in Windows PowerShell), then let `setup.ps1` report and install the rest:

```sh
# Linux, macOS
curl -fsSLO https://raw.githubusercontent.com/izaccavalheiro/testor/main/runner/setup.ps1
pwsh setup.ps1 -Check        # lists what is missing, changes nothing
pwsh setup.ps1               # installs it; add -Tailscale to install Tailscale too
```

```powershell
# Windows, in an elevated Windows PowerShell
Invoke-WebRequest https://raw.githubusercontent.com/izaccavalheiro/testor/main/runner/setup.ps1 -OutFile setup.ps1
powershell -ExecutionPolicy Bypass -File setup.ps1 -Check
powershell -ExecutionPolicy Bypass -File setup.ps1 -DefenderExclusion
```

Then authorize your workstation's SSH key on the runner. On Linux and macOS,
`ssh-copy-id runner-user@my-runner` does it. On Windows with an administrator account, the key
goes in `C:\ProgramData\ssh\administrators_authorized_keys`, with strict permissions: see
[runner setup](../reference/runner-setup.md#3-authorize-the-workstations-key).

:::tip Erlang and Elixir on Linux
Distribution packages are often too old (Ubuntu 24.04 ships Elixir 1.14). Use
[mise](https://mise.jdx.dev): `mise use -g erlang@27 elixir@1.18-otp-27`. The installed service
carries its own Erlang runtime, so it does not depend on mise afterwards.
:::

## 2. Reach it from the workstation

Add the runner to `~/.ssh/config`:

```sshconfig
Host my-runner
  HostName my-runner            # a Tailscale MagicDNS name, a LAN name or an address
  User runner-user
  IdentityFile ~/.ssh/id_ed25519
```

and check that PowerShell 7 answers over SSH:

```sh
ssh my-runner pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'   # 7.x
```

## 3. Install testor

Clone testor on the workstation and include its management tasks from your own
`~/Taskfile.yml` (Task finds it from any folder under your home that has no Taskfile):

```sh
git clone https://github.com/izaccavalheiro/testor ~/git/testor
```

```yaml title="~/Taskfile.yml"
version: "3"
includes:
  testor:
    taskfile: ~/git/testor/taskfiles/testor.yml
    vars: { RUNNER: my-runner }
```

```sh
task testor:check     # what the runner still lacks
task testor:deploy    # build the release on the runner, install the service, start it
```

`deploy` prints the dashboard's address when testor answers: `http://my-runner:6767`. Open it.

## 4. Run a project's tests there

In the project, include `remote.yml` and write its tasks:

```yaml title="Taskfile.yml"
version: "3"
includes:
  runner:
    taskfile: ~/git/testor/taskfiles/remote.yml
    internal: true
    vars: { RUNNER: my-runner }
tasks:
  test:
    desc: Run the tests on the runner; Vitest filters after --
    cmds:
      - task: runner:sync      # upload the working tree
      - task: runner:npm-ci    # npm ci when package-lock.json changed
      - task: runner:exec
        vars: { KIND: test, CMD: "npm test -- {{.CLI_ARGS}}" }
```

```sh
task test                      # everything
task test -- tests/math        # a filter, passed to the test runner
```

The run appears on the dashboard as it starts. To try it with the bundled example:

```sh
cd ~/git/testor/examples/node-project
TESTOR_RUNNER=my-runner task test
```

## 5. Optional: turn on authentication

On a network only you use, testor works without users. As soon as anyone else can reach port
6767, add one; authentication turns on with the first user:

```sh
read -rs TESTOR_PASSWORD; export TESTOR_PASSWORD   # 12 characters or more
task testor:user USER=ada ROLE=admin
```

See [Authentication](../features/authentication.md).

## Next

- [How it works](how-it-works.md)
- [Write your project's tasks](../reference/workstation.md#running-a-project-on-the-runner): lint, coverage, several commands
- [Scenarios](../scenarios/index.md): Playwright with screenshots, Rust and Go, pre-push hooks, a team runner, a cloud VM
