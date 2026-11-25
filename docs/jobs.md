# Jobs and agents

Runs usually reach a runner over SSH, started from a workstation (`task test`). **Jobs** are
runs asked for through the API (by CI, a script, a person) and taken by an **agent**, a small
program on the runner (`runner/agent.ps1`) that runs them through `run.ps1`, so they are
recorded, streamed, signed and kept like any other run. SSH keeps working as before.

Jobs are off until you turn them on, and need authentication.

## How it works

```text
CI or a person ──POST /api/v1/jobs {project, kind}──▶ testor ──queue──┐
                                                                       │ lease (long poll)
agent on the runner ◀──────────────────────────────────────────────────┘
  └─ runs agent.json's command for project/kind through run.ps1 ──▶ the run, recorded as usual
  └─ heartbeat every 10 s (renews the lease, hears a cancel) ── finish {exitCode}
```

- **A job never carries a command.** It names a project and a task (`kind`); the agent looks
  the command up in its own `agent.json` and refuses anything not there. Whoever owns the
  runner decides what can run on it; the API, or anyone holding the `execute` scope, only
  chooses among those commands.
- **Leases.** An agent holds a job for `execution.leaseSeconds` (30) and renews it with each
  heartbeat. A job whose agent stops answering goes back to the queue, up to
  `execution.maxAttempts` (3) tries, then is `expired`.
- **One job per project at a time**, so two runs never share a project's snapshot folder.
- **Labels.** A job may ask for labels (`windows`, `gpu`); an agent takes it only when it has
  all of them.
- **A git ref.** A job may name a branch, tag or commit; an agent whose project has
  `"git": true` checks it out (fetch, then a detached checkout) before running.
- **Cancel.** `POST /api/v1/jobs/:id/cancel` cancels a queued job at once; a running one is
  cancelled the usual way (the run ends its own process tree) and the agent hears it at its
  next heartbeat.

Today an agent runs on the same machine as testor, writing its runs into testor's home.
Agents on other machines, which send their runs' output to testor over the network, are the
next step of the [agent protocol](design/agent-protocol.md).

## Turning it on

1. In `<home>/config.json`: `{"execution": {"enabled": true}}` (`leaseSeconds` and
   `maxAttempts` are optional).
2. An agent user and its token, with authentication on:

   ```sh
   read -rs TESTOR_PASSWORD; export TESTOR_PASSWORD
   task testor:user USER=runner-agent ROLE=agent
   task testor:token USER=runner-agent DAYS=30 SCOPE=agent > agent.token
   ```

3. On the runner, next to `agent.ps1` (installed in the testor home with `run.ps1` from 0.4.0,
   by `task testor:deploy` and `install.ps1 -FromRelease`), an `agent.json`:

   ```json
   { "server": "http://127.0.0.1:6767",
     "tokenFile": "agent.token",
     "labels": ["windows"],
     "projects": {
       "my-app": { "workspace": "~/test-run/my-app", "git": false,
                   "commands": { "test": "npm test", "lint": "npm run lint" } } } }
   ```

   and start it, as the account tests run as: `pwsh ~/test-run/.testor/agent.ps1 -Config agent.json` (`-Once`
   takes one job and exits). Keep it running with the system's scheduler (a scheduled task,
   a systemd unit) like the service.

4. Queue a job (a token with the `execute` scope: admins have it):

   ```sh
   curl -s -H "authorization: Bearer $TOKEN" -H 'content-type: application/json' \
     -d '{"project": "my-app", "kind": "test", "labels": ["windows"], "ref": "main"}' \
     http://my-runner:6767/api/v1/jobs
   ```

   `GET /api/v1/jobs/<id>` follows it: `queued`, `leased`, `running`, then `passed`, `failed`,
   `cancelled` or `expired`, with `runId`, the run it produced.

## A job

| Field | Meaning |
| ----- | ------- |
| `id` | `job-<time>-<random>` |
| `project`, `kind` | what to run: names (letters, digits, `_ . -`) the agent maps to a command |
| `labels` | labels the agent must have |
| `ref` | git branch, tag or commit to check out first |
| `status` | `queued`, `leased`, `running`, `passed`, `failed`, `cancelled`, `expired` |
| `requestedBy`, `agent` | who asked for it, which agent holds it |
| `attempts`, `leaseUntil` | tries so far, when the current lease ends (Unix seconds) |
| `runId`, `exitCode`, `error` | the run it produced, how it ended, why it failed |
| `createdAt`, `leasedAt`, `startedAt`, `endedAt` | when |

The run records `job` (its job's id) and an `actor` naming the agent and who asked.
