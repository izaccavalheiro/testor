# Workstation and projects

The workstation can run any OS. It needs `ssh`, `tar`, `git` and [Task](https://taskfile.dev)
3.x; the Taskfiles use nothing else (no `sed`, no `base64` binary). Clone testor somewhere
stable (the examples use `~/git/testor`); the Taskfiles are used from there.

| Workstation | Notes                                                                             |
| ----------- | --------------------------------------------------------------------------------- |
| Linux       | GNU tar, OpenSSH: nothing to add                                                  |
| macOS       | the built-in bsdtar and OpenSSH work; `brew install go-task`                      |
| Windows     | the built-in OpenSSH client (`ssh.exe`) and `tar.exe`, Git for Windows, and Task (`winget install Task.Task`); Task runs the commands with its own shell, so no WSL is needed |

## Managing testor

Include `taskfiles/testor.yml` from a Taskfile of your own, such as `~/Taskfile.yml` (Task
finds it from any directory under your home that has no Taskfile of its own):

```yaml
version: "3"
includes:
  testor:
    taskfile: ~/git/testor/taskfiles/testor.yml
    vars:
      RUNNER: my-runner            # an SSH host
      # PORT: "6767"
      # WORKSPACES: test-run       # under the runner user's home
      # ALLOW_FROM: "100.64.0.0/10,LocalSubnet"
```

| Task               | Does                                                           |
| ------------------ | -------------------------------------------------------------- |
| `testor:check`     | `setup.ps1 -Check` on the runner                               |
| `testor:test`      | the orchestrator's ExUnit tests, on the runner                 |
| `testor:deploy`    | upload, build the release, install the task and firewall rule, restart |
| `testor:status`    | the scheduled task, and health from the runner and from here   |
| `testor:logs`      | the end of the orchestrator's log                              |
| `testor:uninstall` | remove the task and the rule (the data stays)                  |

`testor:test` and `testor:smoke` go through the runner's `run.ps1` once testor is installed
there: they show on the dashboard as runs of the project `testor` (`PROJECT` changes it), the
test run with its HTML coverage report. The others maintain testor itself and are no
project's sessions.

## Running a project on the runner

Include `taskfiles/remote.yml` from the project's Taskfile, `internal` so its building blocks
do not show in `task --list`, and write the project's tasks with it:

```yaml
version: "3"

includes:
  runner:
    taskfile: ~/git/testor/taskfiles/remote.yml
    internal: true
    vars: { RUNNER: my-runner }

tasks:
  lint:
    desc: Type-check and lint on the runner
    cmds:
      - task: runner:sync
      - task: runner:npm-ci
      - task: runner:exec
        vars: { KIND: lint, CMD: "npm run typecheck; npm run lint" }

  test:
    desc: Run the tests on the runner; Vitest filters after --
    cmds:
      - task: runner:sync
      - task: runner:npm-ci
      - task: runner:exec
        vars: { KIND: test, CMD: "npm test -- {{.CLI_ARGS}}" }

  check:
    desc: lint and test, with one upload
    cmds:
      - task: lint
      - task: test
```

| Task            | Does                                                                         |
| --------------- | ---------------------------------------------------------------------------- |
| `runner:sync`   | uploads the working tree to `~/test-run/<project>`; runs once per `task` call, so `check` uploads once |
| `runner:npm-ci` | `npm ci` when `package-lock.json` changed since the last install (or `node_modules` is missing) |
| `runner:exec`   | runs `CMD` in the snapshot, in PowerShell 7; with `KIND`, recorded by testor  |

Commands are PowerShell 7 on every runner (Windows, Linux, macOS): chain them with `;`. The
session stops at the first failing native command (`$PSNativeCommandUseErrorActionPreference`),
so `npm run a; npm run b` behaves like `npm run a && npm run b`. Use `$IsWindows`, `$IsLinux`
and `$IsMacOS` for the rare command that differs. `CMD` may span several lines and hold any
quotes: it reaches the runner base64-encoded.

`remote.yml` vars: `RUNNER` (required); `PROJECT` (the git root's folder name), `ROOT` (the git
root of the directory you ran `task` in), `WORKSPACES` (`test-run`), `HOME_DIR`
(`<WORKSPACES>/.testor`), `KEEP` (what a new snapshot does not delete: `node_modules .lockhash
target .venv`).

### Things to know

- **One run per project at a time.** Every task of a project uses the same snapshot folder; a
  second upload while a run is going rewrites its files. testor flags overlapping runs.
- **Paths.** On a Windows runner, build paths with `path.join` / `new URL(..., import.meta.url)`
  (or your language's equivalent), not by concatenating `/`.
- **Line endings.** The snapshot is your working tree as it is; a `.gitattributes` with
  `* text=auto eol=lf` keeps checks such as Prettier's consistent between machines.
- **Git inside the snapshot.** The snapshot has no `.git`. A check that needs one (`git
  ls-files`) can build a throwaway index first: `runner:exec` with
  `CMD: "git init -q; git add -A"`.
- **Screenshots.** Anything a run writes under `test-results/`, `__screenshots__/` or
  `screenshots/` is collected when it ends; `$env:SCREENSHOT_DIR` is a folder kept with the run
  for images saved while it runs. Playwright's `screenshot: "only-on-failure"` works as is.

## Git hooks

A pre-push hook can run the checks on the runner, so a push never waits on the workstation's
own toolchain:

```sh
#!/bin/sh
# .git/hooks/pre-push (or your hook manager's equivalent)
exec task check
```
