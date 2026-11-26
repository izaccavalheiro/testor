# MCP server

testor is a [Model Context Protocol](https://modelcontextprotocol.io) server, so an AI agent
(Claude Code, Claude Desktop, any MCP client) can see what the runner ran, find out why a run
failed, and wait for a run to end.

- Endpoint: `POST http://<runner>:6767/mcp`, Streamable HTTP transport, stateless: each POST
  carries a JSON-RPC 2.0 message (or a batch) and is answered with `application/json`; no
  session id, no server-sent stream (`GET` answers 405).
- Protocol versions: `2025-11-25`, `2025-06-18`, `2025-03-26`, `2024-11-05`.
- Capabilities: `tools`.

## Connect

While authentication is off, no header is needed. Once it is on, give the client a token
(see [security.md](security.md)):

```sh
task testor:token USER=ada DAYS=30 SCOPE=read        # read-only agent
claude mcp add --transport http testor http://my-runner:6767/mcp \
  --header "Authorization: Bearer <token>"
```

## Tools

The tools listed are the ones the caller's scopes allow.

| Tool | Scope | Does |
| ---- | ----- | ---- |
| `get_status` | read | runs in progress with live progress, PowerShell sessions outside testor, disk space, the latest result of each project and task |
| `list_runs` | read | runs, newest first; filters `status`, `project`, `kind`, `query`; pages with `limit` and `before` |
| `get_run` | read | a run's record, every spec file, the failed ones, absolute links to screenshots and artifacts |
| `get_run_log` | read | the end of the output (`tail_bytes`), or only lines containing `grep` with `context` lines around, numbered |
| `wait_for_run` | read | waits up to `timeout_seconds` (600 at most) for a run to end and returns it |
| `list_projects` | read | the latest run of every project and task, with the statuses before it |
| `find_flaky_specs` | read | spec files that both passed and failed on one commit |
| `find_hotspots` | read | spec files that fail, take and are retried most over recent runs ([result formats](result-formats.md#hotspots)) |
| `get_device` | read | OS, CPU, memory, GPUs, disks and the latest load sample |
| `cancel_run` | operate | kills a running run's process tree |
| `delete_run` | operate | deletes a finished run with its log, screenshots and artifacts |
| `get_approval` | read | the state of an approval a tool asked for, and its result once done |

Results carry the data as JSON text and as `structuredContent`; a tool that fails answers
`isError: true` with the reason. Screenshot and artifact links are absolute and, while
authentication is on, signed, so the agent can fetch them without credentials.

## Approvals

An agent can be kept from acting alone: `approvals` in `config.json` lists the tools that need a
person's approval.

```json
{ "approvals": { "tools": ["delete_run", "cancel_run"], "ttlMinutes": 30 } }
```

Such a tool, called over MCP, does nothing yet: testor checks the agent's access, records the
request and answers with the approval's id, and the dashboard shows it to people (with
**Approve** and **Deny**; also `GET /api/v1/approvals?status=pending`,
`POST /api/v1/approvals/<id>/approve` or `/deny`, and the `approval` event).

- Someone **other than the agent's user**, holding the tool's scope on the run's project,
  decides.
- Once approved, testor calls the tool **as the agent**, checking its access again, and keeps
  the result; the agent reads it with `get_approval` (`done`, `failed`, `denied`, `expired`).
- A request not decided within `ttlMinutes` (30) expires and does nothing. Requests live in
  memory: a restart drops the pending ones.

## Example

```sh
curl -s http://my-runner:6767/mcp -H 'content-type: application/json' \
  -H "authorization: Bearer $TOKEN" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_run_log","arguments":{"id":"20261124-142233-a1b2c3","grep":"FAIL","context":3}}}'
```
