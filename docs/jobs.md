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

An agent on testor's own machine writes its runs straight into testor's home. An agent on
**another machine** keeps its own home and sends each run to testor as it happens: see
[agents on other machines](#agents-on-other-machines).

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

## Agents on other machines

Give the agent a home of its own (a folder holding `run.ps1`: download it with `agent.ps1`
from a release, checking them against `SHA256SUMS`) and `"upload": true`:

```json
{ "server": "https://testor.example.com", "tokenFile": "agent.token", "upload": true,
  "home": "~/testor-agent", "labels": ["linux", "gpu"],
  "projects": { "my-app": { "workspace": "~/src/my-app", "git": true,
                            "commands": { "test": "npm ci; npm test" } } } }
```

`run.ps1` records the run in that home; the agent sends it to testor while it runs (the record
as it changes, the log in chunks every second) and at its end (screenshots, artifacts, then the
final record), then deletes its copy. testor writes them into its own home as `run.ps1` would,
so the run is live on the dashboard, its specs are parsed, it is signed and its webhooks are
sent like any other. A run on another machine has `remote` (the agent) and no `pid`: its job's
lease watches it, and a run whose agent stops answering is settled as `aborted`. Cancelling it
reaches the agent at its next heartbeat; the agent asks `run.ps1` to end it.

The agent only connects out (HTTPS to testor): the machine needs no inbound port, so it can sit
behind NAT, in another network or in a cloud.

Each run it sends is also **signed by the agent** with a key of its own, which testor pins to
the agent's user at its first lease: give every agent a user of its own (see
[signed by the agent](attestation.md#signed-by-the-agent)).

## Agents in containers and Kubernetes

`ghcr.io/izaccavalheiro/testor-agent` is the agent as an image (linux/amd64): PowerShell 7,
git, `run.ps1` and `agent.ps1`, unprivileged, fit for a read-only root file system. Build your
projects' image from it, with their tools:

```dockerfile
FROM ghcr.io/izaccavalheiro/testor-agent:0.6.0
USER root
RUN apt-get update && apt-get install -y --no-install-recommends nodejs npm && rm -rf /var/lib/apt/lists/*
USER 10001:10001
```

It reads `agent.json` from `$TESTOR_AGENT_CONFIG` (`/etc/testor-agent/agent.json`) and its token
from `$TESTOR_AGENT_TOKEN`; its home is `/home/agent` (a volume). A project with a
`repository` is cloned there for its first job.

The Helm chart runs them next to testor (`agents.enabled`): a Deployment of agent pods with the
chart's hardening, `agent.json` from `agents.projects`, and, with `agents.autoscaling.keda`, a
KEDA `ScaledObject` that scales them on `testor_jobs{status="queued"}` (from zero, when nothing
is queued). See [deploy/helm/testor](../deploy/helm/testor/README.md).
`scripts/container-e2e.sh` runs testor and an agent container on one network and a job through
them, as CI does.

## Secrets

A job's command often needs a secret: a registry token, a database password, a cloud key.
The agent hands them out: a project in `agent.json` maps the environment variables its
commands get to **where their values are**, and the agent reads them on its machine when it
takes a job. testor never sees them, a job cannot ask for others, and the run's log has `***`
in their place.

```json
{ "server": "https://testor.example.com", "tokenFile": "agent.token",
  "vault": { "address": "https://vault.example.com:8200", "kubernetesRole": "testor-agent" },
  "projects": {
    "my-app": { "workspace": "~/src/my-app",
                "commands": { "test": "npm ci; npm test" },
                "secrets": { "NPM_TOKEN": "vault:secret/data/ci/my-app#npm",
                             "DB_PASSWORD": "file:/run/secrets/db",
                             "SENTRY_DSN": "env:CI_SENTRY_DSN" } } } }
```

| Reference | From | How |
| --------- | ---- | --- |
| `env:NAME` | a variable of the agent's own environment | a Kubernetes Secret as `env`, a CI variable, a systemd `Environment=` |
| `file:PATH` | a file, without its last newline | a mounted Secret, Docker secrets (`/run/secrets`), systemd credentials |
| `vault:PATH#FIELD` | HashiCorp Vault or OpenBao, KV v1 or v2 | `VAULT_ADDR` or `vault.address`; a token from `VAULT_TOKEN` or `vault.tokenFile`, or a Kubernetes login (`vault.kubernetesRole`, the pod's service account token; `vault.authPath`, `vault.jwtFile`); `vault.namespace` or `VAULT_NAMESPACE` |
| `aws:ID[#FIELD]` | AWS Secrets Manager | the `aws` CLI and its credentials (an instance profile, IAM roles for service accounts) |
| `gcp:SECRET` | Google Secret Manager | `gcloud secrets versions access`: a name, or `projects/P/secrets/S[/versions/V]` (`latest` by default) |
| `azure:VAULT/NAME` | Azure Key Vault | the `az` CLI and its credentials (a managed identity, Azure workload identity) |
| `sops:FILE[#KEY]` | a file encrypted with SOPS | `sops --decrypt` and its keys (age, PGP, a cloud KMS) |

`#FIELD` picks a value of a secret that holds JSON. `"secretTools": {"aws": "/opt/aws/bin/aws"}`
gives a CLI's path when it is not on `PATH`. The CLIs use the machine's own identity, so the
agent needs no long-lived cloud keys: give the agent's pod or machine a workload identity that
may read those secrets only.

- **Masked.** The agent lists the variables in `TESTOR_MASK`; `run.ps1` writes their values
  (6 characters or longer, and each line of one that spans lines) as `***` in the log it keeps
  and sends, and in the run's error. The terminal of a run started by hand is unchanged.
- **Before the run.** A secret that cannot be read fails the job before anything runs, with
  an error naming the secret and its source, never a value; the CLIs' stderr is not kept.
- **For that run only.** The values are in the environment of the run's process and gone
  from the agent's once it starts. Names must be environment variable names, and not
  `TESTOR_*`.
- **Kubernetes.** The Helm chart's agents take `agents.env` (`valueFrom: secretKeyRef`),
  `agents.secretMounts` (Secrets mounted read-only), `agents.vault` and an
  `agents.serviceAccount` whose annotations give a cloud workload identity; see the
  [chart](../deploy/helm/testor/README.md).

Masking is a safety net, not a boundary: a test that encodes a secret (base64, reversed) and
prints it gets it past. Give jobs secrets meant for tests, scoped to what the tests need.

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
