---
sidebar_position: 4
title: Checks in git hooks
description: Run pre-commit and pre-push checks on the runner, so a push never waits on your workstation's toolchain.
---

# Checks in git hooks

**The situation.** A pre-push hook runs lint and the test suite. On your laptop it takes four
minutes and the fans spin. On the runner it takes the same time, but your machine stays free,
and the result is on the dashboard for anyone to see.

## Plain git hooks

```sh title=".git/hooks/pre-push"
#!/bin/sh
exec task check
```

```sh
chmod +x .git/hooks/pre-push
```

`task check` uploads the working tree as it is, which for a pre-push hook is what you are about
to push (plus uncommitted changes: commit or stash them first if that matters).

## With Husky or another hook manager

Point the hook at the same task:

```sh title=".husky/pre-push"
task check
```

If the repository is shared and not everyone has a runner, keep the hook in your own untracked
hook folder, or make the task fall back to local checks when no runner is configured:

```yaml title="Taskfile.yml"
tasks:
  check:
    cmds:
      - task: '{{if .TESTOR_RUNNER}}remote-check{{else}}local-check{{end}}'
  remote-check:
    cmds: [{ task: lint }, { task: test }]          # the runner tasks
  local-check:
    cmds: ["npm run lint", "npm test"]
```

## A fast pre-commit

Run only the quick checks before a commit, and the slow ones before a push:

```yaml
tasks:
  pre-commit: { cmds: [{ task: lint }] }
  pre-push:   { cmds: [{ task: lint }, { task: test }] }
```

## Caveats

- **Never bypass with `--no-verify` out of habit**; if the runner is down, the hook fails
  loudly (`ssh: connect to host ...`), which is what you want.
- Formatting tools that **rewrite** files cannot run on the runner (it works on a copy): run
  `npm run format` locally, stage, and let the runner check.
- Two hooks running at once (a pre-push while a test task runs) are overlapping runs of the same
  project; see [overlapping runs](../features/run-control.md#overlapping-runs).
