---
sidebar_position: 1
title: Live runs
description: Follow every run as it happens - output line by line, the spec file in progress, and progress counts.
---

# Live runs

Open `http://<runner>:6767`. **Running now**, at the top of the dashboard, shows every run in
progress with its project, type (the task's name, such as `test` or `lint`), command, elapsed
time, the spec file currently running, counts of passed and failed tests, and the last lines of
its output, refreshed at most once a second.

Click a run to open its page. The **Output** panel streams the log as the runner prints it,
with ANSI colours removed; spec files are listed with their status as they finish, and
screenshots and artifacts appear when the run ends.

## How it stays live

- The dashboard holds one server-sent events connection (`GET /events`); a run page holds a
  second one for that run (`GET /events/runs/<id>`). Both start with a snapshot of the current
  state, then send changes.
- A dropped connection (a Wi-Fi hiccup, the laptop waking up) reconnects by itself after 3
  seconds and starts again from a fresh snapshot, so nothing is shown twice or missed.
- Log events carry byte offsets, so lines published while the page was loading its snapshot are
  never duplicated.

## Your terminal is unchanged

testor never sits between the command and your terminal's view of it. Output goes to stdout,
errors to stderr, and the exit code is the command's own. A script that pipes `task test` into
`grep`, or a pre-push hook that checks its exit code, behaves exactly as without testor.

## Opening a run from elsewhere

Every run has a stable id, `yyyyMMdd-HHmmss-<6 hex>` in UTC. The run page's address contains
it, so you can paste it into a chat; with authentication on, the reader needs an account.
Programs follow the same run with `GET /api/v1/runs/<id>/events` or MCP's `wait_for_run`.

## Caveats

- The run page loads at most the last **256 KB** of the log in its snapshot (it says so when it
  truncates); the whole log stays on disk and `GET /api/v1/runs/<id>/log` returns any tail.
- Very chatty output (hundreds of thousands of lines) is fine for the runner but heavy for a
  browser tab; prefer the reporter's summary mode for such suites.
