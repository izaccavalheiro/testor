---
sidebar_position: 10
title: MCP for AI agents
description: Connect Claude Code or any MCP client so agents can see what ran, read why it failed, wait for a run and cancel one.
---

# MCP for AI agents

testor is a [Model Context Protocol](https://modelcontextprotocol.io) server at
`POST http://<runner>:6767/mcp` (Streamable HTTP, stateless). An agent that edits your code can
run the tests through your Taskfile, then ask testor what happened instead of scrolling through
thousands of lines of output.

## Connect

```sh
# authentication off
claude mcp add --transport http testor http://my-runner:6767/mcp

# authentication on: a read-only token for 30 days
task testor:token USER=ada DAYS=30 SCOPE=read
claude mcp add --transport http testor http://my-runner:6767/mcp \
  --header "Authorization: Bearer <token>"
```

Any MCP client that speaks Streamable HTTP works the same way (protocol versions 2024-11-05
to 2025-11-25).

## Tools

| Tool | Scope | Use it to |
| ---- | ----- | --------- |
| `get_status` | read | see what runs now, sessions outside testor, disk space, the latest result per project and task |
| `list_runs` | read | find runs by status, project, type or text |
| `get_run` | read | get a run's record, every spec file, the failed ones, links to screenshots and artifacts |
| `get_run_log` | read | read the end of the output, or only lines matching `grep` with `context` lines around |
| `wait_for_run` | read | block until a run ends (up to 600 s) and get its result |
| `list_projects` | read | the latest run of every project and task with its recent history |
| `get_device` | read | the runner's hardware and current load |
| `cancel_run` | operate | stop a running run's process tree |
| `delete_run` | operate | remove a finished run and its files |

An agent only sees the tools its token's scopes allow: a `read` token cannot cancel or delete.

## A typical loop

1. The agent runs `task test` (it has a shell, and the Taskfile reaches the runner).
2. It calls `list_runs` with `status: failed, limit: 1`, then `get_run` for the failed specs.
3. It calls `get_run_log` with `grep: "FAIL"` (or the spec's name) and `context: 5`, which
   returns just the failing assertions, numbered.
4. It fixes the code and starts again; with `wait_for_run` it can also follow a run someone
   else started.

Screenshot and artifact links in results are absolute and, with authentication on, signed, so
an agent that can fetch URLs can look at a failure screenshot without credentials.

## Caveats

- MCP cannot start a run: commands reach the runner over SSH only. The agent needs a shell
  with your SSH access to run tasks.
- The server is stateless: no server-initiated notifications. Use `wait_for_run` to wait.
- Give agents `read` tokens unless they need to cancel runs, and short lifetimes.
- To keep an agent from acting alone, list tools in `approvals` (`config.json`): its
  `cancel_run` or `delete_run` then waits for someone else to approve it on the dashboard
  ([approvals](../reference/mcp.md#approvals)).

Full reference: [MCP server](../reference/mcp.md).
