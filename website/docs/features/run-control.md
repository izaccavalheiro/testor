---
sidebar_position: 6
title: Cancel, aborted and overlapping runs
description: Stop a run's whole process tree, and how testor detects runs whose session died or that ran over each other.
---

# Cancel, aborted and overlapping runs

## Cancel

The **Cancel** button on a running run (or `POST /api/v1/runs/<id>/cancel`, or MCP's
`cancel_run`) kills the run's whole process tree, not just the shell:

- on Windows, `taskkill /T /F` on the PowerShell session `run.ps1` runs in;
- on Linux and macOS, every descendant `ps` lists is stopped first (so none can fork more), then
  killed.

The run is settled as `cancelled`, and the `task` in your terminal ends with an error, as it
would after `Ctrl+C`. The dashboard calls it **Cancel run** on a run's page; **Running now** has
a **Cancel** button on each run. With authentication on, cancelling needs the `operate` scope.

## Aborted

If the SSH session dies (laptop lid closed, Wi-Fi lost, terminal killed), the command dies with
it and `run.ps1` never writes the run's end. The tracker notices the session's process is
gone and settles the run as **aborted** within about 3 seconds. Nothing is left running on the
runner.

:::tip Long suites from a laptop
If your workstation sleeps during long runs, start them with `nohup task test &` on a machine
that stays awake, or keep the laptop on power with the lid open. A queue that survives the
workstation going away is on the [roadmap](../project/roadmap.md).
:::

## Overlapping runs

Every task of a project shares one snapshot folder on the runner. If a second `task` uploads
while a run is going, it rewrites files under the first. testor flags both runs with a
**warning** on the dashboard and in the record. It does not prevent it: run one task of a
project at a time, or chain them (`task check` with `lint` then `test` uploads once).

## PowerShell sessions outside testor

`runner:exec` without `KIND`, or an interactive `ssh my-runner`, runs PowerShell in the workspace
without a record. The dashboard lists these **sessions** (pid, start, project, command) so you
know something is running that is not a recorded run. Maintenance refuses to clean while one
runs.
