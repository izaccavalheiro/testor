---
sidebar_position: 6
title: Caveats and limits
description: What testor does not do (yet), the trade-offs of its design, and what to know before relying on it.
---

# Caveats and limits

testor is deliberately small: two dependencies, files instead of a database, SSH instead of an
agent protocol. That keeps it easy to install and reason about, and comes with limits. This page
lists them honestly; many are on the [roadmap](project/roadmap.md).

## Design limits

| Limit | Why | What to do |
| ----- | --- | ---------- |
| **One run per project at a time** | every task of a project shares one snapshot folder; a second upload rewrites files under a running one | chain tasks (`task check`), or use a different `PROJECT` per person or branch; overlaps are flagged |
| **No queue or scheduler** | commands reach the runner over SSH when you start them; testor only records | cron or a timer runs nightly suites ([scenario](scenarios/ci-and-notifications.md)); a queue is planned for 0.5 |
| **The API cannot start runs** | a security choice: only SSH keys can run code | start runs through the Taskfile; opt-in triggers are planned, behind their own scope |
| **One dashboard per runner** | each runner's testor reads its own files | one browser tab per runner, or `/api/v1` to combine them; a hub is planned for 0.4 |
| **Runs need the workstation's SSH session** | the command runs in that session; when it dies, the run is aborted | keep the workstation awake, or start long runs from a machine that is |
| **No parallelism control** | everything started runs at once | the Device page shows contention; split suites across runners |

## Platform

- **PowerShell 7 on every runner.** Commands are PowerShell, not bash, even on Linux and macOS.
  `;` chains commands and stops at the first failure; `$IsWindows`, `$IsLinux`, `$IsMacOS` handle
  differences. A bash script is still one command away: `bash ./ci.sh`.
- **Windows runners need an administrator account** for the installer (scheduled task, firewall
  rule). The service itself runs with a limited token.
- **macOS runs testor in the user's session** (a launchd agent): automatic login is needed for an
  unattended Mac, and its device statistics are coarser.
- **Linux needs systemd** for the service (user units with lingering).
- **Erlang/OTP 27+ and Elixir 1.18+ on the runner** to build the release; prebuilt archives that
  remove this requirement are planned for 0.3.

## Data

- **Files, not a database.** Runs, logs and artifacts are files under the testor home; listing is
  instant for the default 500 runs, and the index lives in memory. Tens of thousands of runs
  would need a larger `runs.maxRuns` and more memory; a database option is planned for 0.6.
- **Retention deletes.** Defaults keep runs 30 days (500 at most) and screenshots and artifacts
  7 days. Raise them before relying on old evidence.
- **The run page loads the last 256 KB of a log**; the API returns any tail of the full log.
- **Snapshots have no `.git`**: checks that need git build a throwaway index (`git init -q; git add -A`).

## Detection is heuristic

- **Spec results** come from the text of the output; custom or silent reporters give none. The
  exit code alone decides whether a run passed.
- **Screenshots and artifacts** are files changed since the run started (with a 2-second
  margin). A tool that keeps old modification times is missed; artifact wildcards do not recurse
  (`**`).
- **Aborted runs** are detected by the session's process disappearing, so a run whose SSH
  connection hangs without closing stays "running" until the connection times out.

## Security

- **Plain HTTP.** Use Tailscale or a TLS proxy anywhere you do not trust the network.
- **Authentication is off by default** so a private setup works at once; turn it on before
  anyone else can reach the port.
- **Local users only**, per runner; no single sign-on yet (planned for 0.7).
- **Behind a proxy**, list it in `TESTOR_TRUSTED_PROXIES` and its public name in
  `TESTOR_ALLOWED_HOSTS`, or rate limiting and audit see the proxy's address and its name is refused
  ([details](operations/reverse-proxy-tls.md#things-to-know-behind-a-proxy)).
- **Authentication off answers private addresses only** (`TESTOR_ANONYMOUS=any` to change it).
- **The runner's user runs everything.** Anyone with an SSH key runs code as that user and can
  read every project's snapshot on the runner.

## Versions

testor is **0.x**: breaking changes are possible in minor releases, always listed under
**Breaking** in the changelog; patch releases are always safe. See
[versioning](project/versioning.md).
