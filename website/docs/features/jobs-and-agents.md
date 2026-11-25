---
sidebar_position: 12
title: Jobs and agents
description: Start runs through the API and have agents run them on your machines, other networks, containers or Kubernetes, then send them back.
---

# Jobs and agents

Runs usually start from your workstation over SSH (`task test`). **Jobs** start them another
way: CI, a script or a person asks testor through the API, and an **agent** on a runner takes
the job and runs it through `run.ps1`, so it is recorded, streamed and kept like any other run.
Off until you turn it on, and only with authentication.

```text
POST /api/v1/jobs {project, kind} ──▶ testor's queue ──lease──▶ agent ──run.ps1──▶ the run
```

- **No commands in the API.** A job names a project and a task; the agent's own `agent.json`
  says which command that is, and refuses anything else.
- **Anywhere.** An agent on testor's machine writes its runs straight into testor's home; one
  on **another machine** (behind NAT, in another network, in a cloud) connects out over HTTPS and
  sends each run as it happens. The **agent image** and the Helm chart's **agents** run them in
  containers and Kubernetes, scaled by KEDA on queued jobs.
- **Leases, labels, refs.** Agents renew a lease while they run a job; a job whose agent
  disappears is tried again. Jobs can ask for labels (`windows`, `gpu`) and a git ref the agent
  checks out (or clones). One job per project runs at a time.
- **Isolated.** Each job can run in a git worktree or a copy of the workspace of its own,
  removed after, so one run never finds what another left.
- **Secrets.** A project's secrets come from Vault, AWS, GCP or Azure secret managers, SOPS
  files, the environment or files, read by the agent on its machine with its own identity;
  testor never sees them, and the run's log shows `***`.
- **Identity.** testor gives a job a short OpenID Connect token that AWS, Google Cloud,
  Azure or Vault trade for credentials scoped to its project: no cloud keys on the runner.
- **Signed by the agent.** A run an agent sends is signed with its own key, which testor pins:
  [signed results](signed-results.md).

Set it up: [jobs and agents (reference)](../reference/jobs.md).
