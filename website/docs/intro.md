---
slug: /
sidebar_position: 1
title: What is testor?
description: testor runs your test suites on another machine over SSH and streams them live to a dashboard, an HTTP API and AI agents.
---

# What is testor?

**testor** is a free, open-source test orchestrator. It turns any machine you can reach over
SSH (a spare laptop, a mini PC, a Mac on a shelf, a virtual machine in a cloud) into a test
runner for the code you are editing, and records every run so you, your scripts and your AI
agents can follow it live.

You keep working where you are. `task test` uploads a snapshot of your working tree,
uncommitted changes included, and runs the command on the runner. Its output reaches your
terminal exactly as if it ran locally: same lines, same stderr, same exit code. Meanwhile
testor, a small Elixir service on the runner, streams the run to a dashboard: the log line by
line, spec files passing and failing as they finish, screenshots, reports, and the machine's
CPU, memory, GPU and disks.

```text
 workstation (any OS)                           runner (Windows, Linux or macOS)
 ┌──────────────────────────┐   SSH (Tailscale   ┌───────────────────────────────────────────┐
 │ editor, git              │   or LAN)          │ sshd → PowerShell 7                       │
 │ task test ───────────────┼──── snapshot ─────▶│  ~/test-run/<project>   (working tree)    │
 │                          │◀─── output, exit ──┤  run.ps1 → runs/, logs/, screenshots/     │
 │                          │                    │                 ▲ reads                   │
 │ browser, scripts, agents ◀── HTTP + SSE :6767 ┤  testor (Elixir: Bandit + Plug)           │
 └──────────────────────────┘                    └───────────────────────────────────────────┘
```

## Why run tests on another machine?

- **Test on the platform your users run.** Windows paths, line endings, file locking, a real
  GPU, macOS's file system: without leaving your own OS or keeping a second desk.
- **Keep your machine responsive.** A 20-minute end-to-end suite runs elsewhere while your
  editor, browser and language server keep the CPU.
- **Give idle hardware a job.** The old laptop in a drawer is a capable test runner.
- **See everything in one place.** Every run, from every project and every task, with its log,
  results, screenshots and reports, kept and searchable.

## What you get

| | |
| --- | --- |
| [Live runs](features/live-runs.md) | output streamed as it is printed; progress per spec file |
| [Spec results without configuration](features/spec-results.md) | Vitest, Playwright, pytest, `go test` and `cargo test`, read from their normal output |
| [History and board](features/history-and-board.md) | every run, filterable; the latest result of each project and task |
| [Screenshots](features/screenshots.md) and [artifacts](features/artifacts.md) | images, videos, HTML reports, coverage, JUnit XML kept with the run |
| [Run control](features/run-control.md) | cancel a run's whole process tree; aborted and overlapping runs detected |
| [Device stats](features/device-stats.md) | CPU per core, memory, GPU, disks, network, battery, per-run resource use |
| [Retention and maintenance](features/retention-and-maintenance.md) | old data cleaned up; the runner's disk reclaimed on demand |
| [HTTP API](features/http-api.md) | `/api/v1` with an OpenAPI 3.1 document, and server-sent events |
| [MCP server](features/mcp-for-ai-agents.md) | AI agents list runs, read why one failed, wait for one, cancel one |
| [Authentication](features/authentication.md) | users, roles, scopes, JWT tokens, signed links, audit log |

## How it compares

testor is not a CI service. CI decides whether a commit may merge; testor runs the checks of
people while they work, on machines they choose, and shows the results as they happen. It
complements CI: the same commands run in both, and testor's API can feed CI or a chat bot.

| | testor | a hosted CI service | running tests locally |
| --- | --- | --- | --- |
| tests your uncommitted changes | yes | no (needs a push) | yes |
| on another OS or hardware | yes, any machine with SSH | the provider's images | no |
| live log in a browser | yes | yes | no |
| cost | free, your hardware | per minute, or limited free tier | free |
| data leaves your network | no | yes | no |

## Free, for everyone

testor is MIT-licensed. There is no paid edition, no account to create and no telemetry. It
runs **on premises** (a machine on your desk or in your rack) or **in your cloud** (a VM you
already pay for); the [roadmap](project/roadmap.md) takes it further toward cloud-native
deployments: prebuilt images, many runners behind one hub, ephemeral runners on Kubernetes.

## Where next

- [Quick start](getting-started/quick-start.md): a runner and your first run, in about 15
  minutes.
- [How it works](getting-started/how-it-works.md): the pieces and the life of a run.
- [Scenarios](scenarios/index.md): real setups, end to end.
- [Caveats and limits](caveats.md): what to know before you rely on it.
