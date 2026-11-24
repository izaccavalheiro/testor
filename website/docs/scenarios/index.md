---
sidebar_position: 0
title: Scenarios
slug: /scenarios
description: Real setups, end to end - what to configure, the Taskfile to write, and what to watch out for.
---

# Scenarios

Each scenario is a complete setup that works with testor as it is today: the machines, the
Taskfile, the settings, and the caveats that matter for it.

## By what you test

| Scenario | You will set up |
| -------- | --------------- |
| [Test on Windows from Linux or macOS](windows-from-linux.md) | a Node.js/TypeScript project checked on Windows, with lint, tests and coverage reports |
| [End-to-end tests with Playwright](playwright-e2e.md) | browsers on the runner, failure screenshots, videos and the HTML report on the dashboard |
| [Rust, Go and Python projects](polyglot.md) | `cargo test`, `go test` and pytest on the runner, with caches kept between runs |

## By how you work

| Scenario | You will set up |
| -------- | --------------- |
| [Checks in git hooks](git-hooks.md) | pre-commit and pre-push hooks that run on the runner |
| [AI agents that fix failing tests](ai-agent-triage.md) | Claude Code (or any MCP client) reading failures through testor |
| [Scripts, CI and chat notifications](ci-and-notifications.md) | waiting for a run from a script, a nightly run, a message when a run fails |

## By where it runs

| Scenario | You will set up |
| -------- | --------------- |
| [A spare machine over Tailscale](home-lab-tailscale.md) | an old laptop or mini PC as an always-on runner, reachable from anywhere |
| [A runner shared by a team](team-runner.md) | users and roles, per-person snapshots, tokens for CI |
| [A runner in the cloud](cloud-vm-runner.md) | a Linux VM with TLS in front, or reached only through Tailscale |
| [Several runners: Windows, Linux and macOS](several-runners.md) | one Taskfile that runs a project's checks on every OS |
