---
sidebar_position: 1
title: Test on Windows from Linux or macOS
description: Check a Node.js or TypeScript project on a Windows machine while you develop on Linux or macOS.
---

# Test on Windows from Linux or macOS

**The situation.** You develop a TypeScript library on Linux. Your users run it on Windows,
where paths use `\`, files stay locked while open and line endings differ. CI catches the
breakage after you push; you want to catch it while you work.

## Setup

- **Runner**: a Windows 10/11 machine with an administrator account, prepared with
  `setup.ps1 -DefenderExclusion` (Defender scanning every file of an `npm ci` can make it several
  times slower), Node.js installed (`winget install OpenJS.NodeJS.LTS`).
- **Workstation**: Linux with `ssh`, `git`, `tar`, Task; testor installed with
  `task testor:deploy`.

## The Taskfile

```yaml title="Taskfile.yml"
version: "3"

includes:
  win:
    taskfile: ~/git/testor/taskfiles/remote.yml
    internal: true
    vars: { RUNNER: win-runner }

tasks:
  lint:
    desc: Type-check, lint and check formatting on Windows
    cmds:
      - task: win:sync
      - task: win:npm-ci
      - task: win:exec
        vars: { KIND: lint, CMD: "npm run typecheck; npm run lint; npm run format:check" }

  test:
    desc: Run the tests on Windows; Vitest filters after --
    cmds:
      - task: win:sync
      - task: win:npm-ci
      - task: win:exec
        vars: { KIND: test, CMD: "npm test -- {{.CLI_ARGS}}" }

  coverage:
    desc: Coverage on Windows, the HTML report kept with the run
    cmds:
      - task: win:sync
      - task: win:npm-ci
      - task: win:exec
        vars: { KIND: coverage, CMD: "npm run test:coverage", ARTIFACTS: "coverage" }

  check:
    desc: lint and test, with one upload
    cmds: [{ task: lint }, { task: test }]
```

`task check` uploads once (`sync` runs once per `task` call), installs dependencies only when
`package-lock.json` changed, then lints and tests. Each step is a run on the dashboard, under
the types `lint` and `test`; the **Latest by task** board shows both.

## Make the tests Windows-proof

- Build paths with `node:path` (`path.join`) or `new URL("./fixtures/a.json", import.meta.url)`,
  never by concatenating `/`.
- Add a `.gitattributes` with `* text=auto eol=lf`: the snapshot is your working tree as it is,
  so Prettier sees the same line endings on both machines.
- Close file handles before deleting files in tests; Windows refuses to delete an open file.

## Things that need a `.git`

The snapshot has no `.git` folder. A check that calls `git ls-files` (a package-content check,
some lint rules) can build a throwaway index first:

```yaml
- task: win:exec
  vars: { KIND: privacy, CMD: "git init -q; git add -A; npm run check:package" }
```

## Caveats

- **One run per project at a time**: `task lint` in one terminal and `task test` in another
  share the snapshot folder; testor flags the overlap.
- **Antivirus**: some third-party products sandbox new executables a build produces (native
  addons). If a build fails with "Permission denied" on its own output, look there first.
- **Programs installed after sshd started** are not on sshd's PATH; the Taskfiles add the
  registry PATH to each session, and restarting `sshd` fixes it for good.
