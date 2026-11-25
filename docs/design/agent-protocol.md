# Agent protocol

Status: steps 1 and 2 done ([jobs](../jobs.md): a local agent in 0.4, agents on other machines
in 0.5); steps 3 and 4 proposed. Builds on: signed attestations, cooperative cancel, the actor record,
separate accounts (0.3).

## Problem

Commands reach a runner only over SSH, in the session of the person who started them. That
rules out runners behind NAT without a VPN, queues, scheduled runs, ephemeral runners
(containers, Kubernetes Jobs, serverless), and a hub that sees every runner.

## Shape

A **controller** (testor as it is, plus a queue) and **agents** (a small process on each
runner, or a pod per run). Agents connect out; the controller never connects to them.

```text
agent ──(HTTPS/WebSocket, mTLS or agent token)──▶ controller
  register {labels: os, arch, gpu, ...; version; capacity}
  ◀── lease {job, deadline}            renew every 10 s; a lost lease returns the job to the queue
  ── events {log chunks with offsets, specs, files}   the same shapes as /api/v1 events
  ── result {DSSE envelope signed with the agent's key}
  ◀── cancel {job}                      the agent ends the run's tree (as run.ps1 does today)
```

- **Jobs** are `{project, kind, command from the project's allow-list, source: {repository,
  commit} or an uploaded snapshot digest, artifacts, timeout}`. A job never carries a free
  command from the API: the allow-list lives in the repository (`.testor.yml`) at that commit.
- **Leases** make delivery at-least-once and runs idempotent by job id; an agent that dies is
  noticed by its lease, not by a pid.
- **Isolation per job**: a fresh workspace (copy-on-write of a dependency cache), a separate
  account or a container, no access to the agent's key.
- **Results are signed by the agent** (its key, registered with the controller), so the
  controller stores evidence it did not have to produce itself: the attestation format of
  [attestation.md](../attestation.md) with the agent as signer.

## Executors

The agent runs a job through an executor: `process` (today's run.ps1 semantics, a separate
account), `container` (Docker/Podman, read-only root, no network unless allowed), `kubernetes`
(a Job per run, the agent as a controller in the cluster; KEDA scales agents on queue depth),
`ssh` (today's path, kept), and `worker` (Cloudflare Workers, Lambda) for JavaScript suites
that need no file system.

## Security

- Execution is off until `execution.enabled`, needs the `execute` scope, and only runs
  allow-listed commands at a commit; tokens for agents carry only `agent`.
- An agent can only report on jobs it leased. Its key is pinned at registration; a result
  signed by another key is refused.
- Snapshots uploaded by people are content-addressed and size-limited; secrets reach a job
  only from the secrets broker ([identity.md](identity.md)), masked in its logs.

## Order of work

1. **Done.** Queue and leases in the controller (in-process queue, the files store), the agent
   as a `process` executor on the controller's machine, SSH unchanged. The agent's own
   configuration holds the commands; jobs only name a project and a task.
2. **Done.** Agents on other machines: run.ps1 records into the agent's own home and the agent
   sends the run (record, log chunks at offsets, files) over HTTPS; the job's lease watches
   it. Result signing stays testor's (it signs what it received), not yet the agent's.
3. Signed agent results: the agent's key, registered with testor, signs what it sends.
4. Container and Kubernetes executors, the Helm chart's agent.
5. Hub view across controllers.
