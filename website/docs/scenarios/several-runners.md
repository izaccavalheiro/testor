---
sidebar_position: 10
title: Several runners - Windows, Linux and macOS
description: Run a project's checks on every operating system from one Taskfile, each runner with its own testor.
---

# Several runners: Windows, Linux and macOS

**The situation.** Your tool ships for all three desktop OSes. You have a Windows mini PC, a
Linux box and a Mac mini, and want `task test:all` to check all of them.

## Install testor on each

Include `testor.yml` once per runner, under different namespaces:

```yaml title="~/Taskfile.yml"
version: "3"
includes:
  testor-win:   { taskfile: ~/git/testor/taskfiles/testor.yml, vars: { RUNNER: win-runner } }
  testor-linux: { taskfile: ~/git/testor/taskfiles/testor.yml, vars: { RUNNER: linux-runner } }
  testor-mac:   { taskfile: ~/git/testor/taskfiles/testor.yml, vars: { RUNNER: mac-runner } }
```

```sh
task testor-win:deploy testor-linux:deploy testor-mac:deploy
```

Each runner has its own dashboard: `http://win-runner:6767`, `http://linux-runner:6767`,
`http://mac-runner:6767`.

## One project, three runners

```yaml title="Taskfile.yml"
version: "3"
includes:
  win:   { taskfile: ~/git/testor/taskfiles/remote.yml, internal: true, vars: { RUNNER: win-runner } }
  linux: { taskfile: ~/git/testor/taskfiles/remote.yml, internal: true, vars: { RUNNER: linux-runner } }
  mac:   { taskfile: ~/git/testor/taskfiles/remote.yml, internal: true, vars: { RUNNER: mac-runner } }

tasks:
  test:win:
    cmds: [{ task: win:sync }, { task: win:npm-ci }, { task: win:exec, vars: { KIND: test, CMD: "npm test" } }]
  test:linux:
    cmds: [{ task: linux:sync }, { task: linux:npm-ci }, { task: linux:exec, vars: { KIND: test, CMD: "npm test" } }]
  test:mac:
    cmds: [{ task: mac:sync }, { task: mac:npm-ci }, { task: mac:exec, vars: { KIND: test, CMD: "npm test" } }]

  test:all:
    desc: The tests on every OS, in parallel
    deps: [test:win, test:linux, test:mac]
```

`deps` run in parallel; Task prefixes or interleaves their output (`--output=prefixed` keeps it
readable). Each runner records its own run.

## The rare command that differs

Commands are PowerShell 7 everywhere, so most are identical. For the exceptions:

```yaml
CMD: |
  if ($IsWindows) { npm run test:win } elseif ($IsMacOS) { npm run test:mac } else { npm test }
```

## Caveats

- **Three dashboards**, three user lists, three histories, when each runner runs its own testor.
  For one view, run one testor and put an [agent](../features/jobs-and-agents.md) on each other
  machine (`"upload": true`): their runs all reach it, each signed by its agent. A hub across
  several testors is on the [roadmap](../project/roadmap.md).
- **macOS** runs testor as a launchd agent in the user's session: turn on automatic login for a
  Mac nobody sits at. Its device stats are coarser (no per-core CPU, combined disk I/O).
