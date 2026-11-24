---
sidebar_position: 8
title: A runner shared by a team
description: Share one runner between several people with users and roles, separate snapshots per person, and tokens for automation.
---

# A runner shared by a team

**The situation.** Your team has one machine with a GPU (or the only Mac). Everyone wants to
run their checks there, see each other's results, and nobody should be able to wipe the disk
by accident.

## Accounts: SSH and testor

- **SSH** decides who can run commands. Everyone connects as the runner's testor user, each
  with their own key in its `authorized_keys`, so a key can be removed when someone leaves.
- **testor users** decide who can see and act on the dashboard, the API and MCP:

```sh
read -rs TESTOR_PASSWORD; export TESTOR_PASSWORD
task testor:user USER=lead  ROLE=admin      # can also clean the disk
task testor:user USER=ana   ROLE=operator   # can cancel and delete runs
task testor:user USER=bruno ROLE=operator
task testor:user USER=pm    ROLE=viewer     # reads the board
task testor:user USER=ci    ROLE=viewer
task testor:token USER=ci DAYS=30 SCOPE=read
```

## One snapshot per person

Every task of a project uploads into `~/test-run/<project>`. If Ana and Bruno both run
`my-app`, the second upload rewrites the first one's files mid-run. Give each person their own
project name:

```yaml title="Taskfile.yml"
includes:
  runner:
    taskfile: ~/git/testor/taskfiles/remote.yml
    internal: true
    vars:
      RUNNER: team-runner
      PROJECT: 'my-app-{{.USER | default .USERNAME}}'   # my-app-ana, my-app-bruno
```

Each person gets their own snapshot, dependencies and history entries; the board shows one
row per person and task. The cost is disk space: one `node_modules` per person (the
Maintenance page shows idle snapshots).

## The audit trail

Every cancel, delete, cleanup and maintenance action is logged with the user and address:

```text
audit: ana from 100.64.0.7: POST /api/v1/runs/20261124-142233-a1b2c3/cancel -> 200
```

`task testor:logs` shows the end of the log.

## Caveats

- **The runner's capacity is shared.** testor runs whatever is started, in parallel; two heavy
  suites at once are slower for both. The Device page shows who is using what (per-run CPU
  and memory). A queue is on the [roadmap](../project/roadmap.md).
- **Shared OS account**: commands of every person run as the same user and can read each other's
  snapshots. Use separate runners (or OS accounts with their own testor on their own port) when
  that matters.
- **Users are per runner**: two runners have two user lists.
