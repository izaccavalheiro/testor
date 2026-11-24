---
sidebar_position: 2
title: How it works
description: The three parts of testor, how a run travels from your terminal to the dashboard, and why it is built this way.
---

# How it works

testor has three parts, and they meet in **files**, not in a protocol:

| Part | Where | Does |
| ---- | ----- | ---- |
| **Taskfiles** (`taskfiles/`) | workstation | upload the working tree over SSH and run commands on the runner |
| **`run.ps1`** | runner | wraps a command: writes its record and log, passes output through unchanged, keeps screenshots and artifacts |
| **the orchestrator** (`orchestrator/`) | runner, as a service | reads those files, follows runs as they happen, and serves the dashboard, the API and MCP |

Because the wrapper writes and the orchestrator reads, **a run is recorded even when the
orchestrator is down**, and the orchestrator catches up with whatever happened when it starts.
Restarting or upgrading testor never loses a run.

## The life of a run

1. **Sync.** `runner:sync` lists your working tree as git sees it (tracked and untracked
   files, minus what `.gitignore` excludes), packs it with `tar` and unpacks it on the runner in
   `~/test-run/<project>`. Dependencies and build caches (`node_modules`, `target`, `.venv`)
   survive between uploads, so they are not reinstalled every time.
2. **Exec.** `runner:exec` opens one SSH session in that folder and runs the command in
   PowerShell 7 through `run.ps1`, which writes `runs/<id>.json` with `status: running`.
3. **Follow.** Within 300 ms the orchestrator sees the new record and starts a tracker for
   it, which reads the log every 250 ms, recognizes spec results and pushes new lines to every
   open dashboard over server-sent events.
4. **End.** When the command exits, `run.ps1` keeps the screenshots and artifacts the run
   wrote and completes the record with the status, exit code and duration. The exit code is
   passed back over SSH, so `task test` fails or succeeds exactly as it would locally.

If the SSH session dies before that (a laptop lid closed, a terminal killed), the record never
gets its end: the tracker notices the session's process is gone and marks the run **aborted**
within seconds.

## Why PowerShell 7 everywhere?

A project's tasks are written once and run on any runner. Every remote step is a PowerShell 7
script sent **base64-encoded**, so it survives whatever login shell the runner has (bash, zsh
or PowerShell) without quoting rules, and the workstation needs nothing beyond `ssh`, `git`
and `tar`. The script stops at the first failing command, so `npm run lint; npm test` behaves
like `&&`.

## Why Elixir?

The orchestrator follows many files and many browser connections at once, and must never stall
because Windows is slow to answer a query. The BEAM gives it cheap processes (one per running
run, one per stream), supervision that restarts what fails, and a release that bundles its own
runtime: the service needs nothing installed once it is built. Its only dependencies are Bandit
(HTTP) and Plug.

## What is stored, and where

Everything lives in plain files under the runner user's home:

| Path | What |
| ---- | ---- |
| `~/test-run/<project>/` | the project's snapshot, where its commands run |
| `~/test-run/.testor/runs/` | one JSON record per run |
| `~/test-run/.testor/logs/` | one log per run, as the command printed it |
| `~/test-run/.testor/screenshots/`, `artifacts/` | what each run kept |
| `~/test-run/.testor/config.json`, `auth.json` | retention, maintenance and users |
| `~/test-run/.testor/app/` | the installed release |

There is no database to back up or migrate. See [Architecture](../reference/architecture.md)
for the run record's fields and the orchestrator's processes.

## The three ways in

| Interface | For | Reference |
| --------- | --- | --------- |
| the dashboard | people, in a browser | [features](../features/live-runs.md) |
| `/api/v1` (JSON, SSE, OpenAPI 3.1) | scripts, CI, bots | [HTTP API](../reference/api.md) |
| `/mcp` (Model Context Protocol) | AI agents such as Claude Code | [MCP server](../reference/mcp.md) |

None of them can start a command. Commands reach the runner over SSH only, so whoever can run
code there is whoever has an SSH key, exactly as before testor was installed.
