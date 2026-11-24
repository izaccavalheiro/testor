---
sidebar_position: 5
title: AI agents that fix failing tests
description: Give Claude Code or another MCP client read access to testor, so it finds why a run failed without reading the whole log.
---

# AI agents that fix failing tests

**The situation.** You use an AI coding agent. It can run `task test`, but a failing
end-to-end suite prints 20,000 lines; the agent either truncates the output and misses the
failure, or fills its context with noise. testor already knows which specs failed and can
return just the lines that matter.

## Connect the agent

```sh
task testor:token USER=ada DAYS=7 SCOPE=read
claude mcp add --transport http testor http://my-runner:6767/mcp \
  --header "Authorization: Bearer <token>"
```

(Without authentication, leave out the header.) A `read` token lets the agent look but not
cancel or delete.

## Tell it how to use it

Add to your project's agent instructions (`CLAUDE.md`, `AGENTS.md`):

```markdown
## Tests

Tests run on a remote runner: `task test` (Vitest filters after `--`).
When a run fails, do not read its whole output. Use the testor MCP tools:
`list_runs` (status: failed, limit: 1) for the run id, `get_run` for the failed spec
files, then `get_run_log` with `grep` set to the spec or "FAIL" and `context: 5`.
```

## What the agent gets

```text title="get_run_log with grep FAIL and context 2 (illustrative)"
120: ❯ tests/parser.test.ts (14 tests | 1 failed) 52ms
121:   × parses a Windows path 8ms
122:     → expected 'C:/work/a.ts' to be 'C:\\work\\a.ts'
...
```

`get_run` also gives absolute links to the failure screenshots; with authentication on they are
signed, so an agent that can fetch images can look at them.

## Waiting for someone else's run

`wait_for_run` blocks up to 10 minutes until a run ends, so an agent can react to a run a hook
or a colleague started: "wait for the running e2e run, then summarize its failures".

## Caveats

- MCP cannot start runs; the agent starts them through its shell and your SSH access. Keep that
  in mind when you decide what an agent may run.
- Tokens are bearer secrets: keep them out of committed files (`claude mcp add` stores them in
  your user configuration).
