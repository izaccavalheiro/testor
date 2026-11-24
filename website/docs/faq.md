---
sidebar_position: 7
title: FAQ
description: Short answers to the questions people ask about testor.
---

# FAQ

## Is testor really free?

Yes. It is MIT-licensed, has no paid edition and no account, and sends no telemetry. You run it
on your own machines.

## Does it replace my CI?

No. CI decides whether a commit may merge, from a clean checkout. testor runs your checks while
you work, on uncommitted changes, on a machine you choose, and shows them live. Many people use
both: the same commands in CI and through testor.

## Do my projects need changes?

Only a `Taskfile.yml` that includes `remote.yml` (about ten lines). Test runners keep their
reporters; testor reads their normal output.

## Which test runners does it understand?

Spec results come from Vitest, Playwright (list reporter), pytest, `go test` and `cargo test`.
Any other command runs and is recorded just the same (log, status, duration, screenshots,
artifacts); only the per-file breakdown is missing.

## Does it work without Tailscale?

Yes. Anything that gives you SSH to the runner works: a LAN, a VPN, a cloud VM. Tailscale is
the simplest way to make it secure and reachable from anywhere.

## Can the runner and the workstation be the same OS?

Yes. A Linux workstation with a Linux runner is common when the point is to offload long suites
or use stronger hardware.

## Can I run testor in Docker or Kubernetes?

Not yet. Today it is installed as a service on the runner. A container image and cloud-native
runners are on the [roadmap](project/roadmap.md) (0.3 and 0.6).

## Can several people share a runner?

Yes, with a project name per person so snapshots do not collide, and users with roles. See
[a runner shared by a team](scenarios/team-runner.md).

## What happens if testor is down during a run?

Nothing is lost. `run.ps1` records the run in files whether or not the service is up; when it
starts, it reads them and catches up.

## What happens to a run if my laptop goes to sleep?

The SSH session drops, the command on the runner ends with it, and testor marks the run aborted
within seconds.

## Where are my results stored?

In files on the runner, under `~/test-run/.testor`. Nothing leaves the runner unless you fetch
it.

## Can an AI agent break things through MCP?

Only within its token's scopes. A `read` token can look but not cancel, delete or clean. No
MCP tool can start a command.

## How do I know what changed between versions?

The [changelog](project/changelog.md). [Versioning](project/versioning.md) explains what a
version number promises.

## How can I help?

Use it and report what breaks; add a parser for your test runner; pick a
[roadmap](project/roadmap.md) item. See [contributing](project/contributing.md).
