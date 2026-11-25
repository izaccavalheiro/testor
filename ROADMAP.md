# Roadmap

testor's goal: **the test orchestrator anyone can run, for free, on a spare machine at home or
a fleet in the cloud**. It stays MIT-licensed, has no paid tier and sends no telemetry.

This page is a plan, not a promise. Each milestone is a minor release under
[Semantic Versioning](VERSIONING.md); the order may change with what users need. Discuss an item,
or propose one, in a [GitHub issue](https://github.com/izaccavalheiro/testor/issues).

Two principles hold through every milestone:

- **The terminal stays unchanged.** Output, stderr and exit codes reach the caller exactly as
  without testor.
- **Nothing starts a command without an explicit opt-in.** Today only SSH runs commands on a
  runner. Any feature that lets the API start work (queues, triggers, cloud runners) arrives
  off by default, behind a scope of its own, and is documented with its threat model.

## Where testor is

| Release | Theme | Status |
| ------- | ----- | ------ |
| 0.1.0 | One runner over SSH: live dashboard, history, spec parsing, screenshots, device stats; Windows, Linux, macOS | released |
| **0.2.0** | Integrations and trust: `/api/v1` with OpenAPI, the MCP server for AI agents, authentication (roles, scopes, JWT, signed links, audit), artifacts, disk maintenance, the documentation site, semantic versioning | released |
| **0.3.0** | Secure by default, install anywhere: DNS rebinding and exposure defences, symbolic-link safety, verified cancels and cooperative cancel, limits; tests in a separate account; signed run attestations and a signed audit trail; prebuilt and verified installs, the container image, the Helm chart; built-in TLS, Prometheus metrics, webhooks; masked secrets, fenced MCP output, flaky specs | released |
| **0.4.0** | Jobs: runs queued through the API (scope `execute`, opt-in) and taken by an agent on the runner (`runner/agent.ps1`) by lease, with labels, a git ref, one job per project at a time, retries and cancelling; the first step of the agent protocol | released |

## Next milestones

Designs for the larger pieces are in [docs/design](docs/design/README.md).

### 0.4: agents and queues (opt-in)

- The [agent protocol](docs/design/agent-protocol.md): runners that connect out to a
  controller, take jobs by lease and sign their results; a `process` executor first, SSH kept.
  **Steps 1 and 2 are in:** [jobs](docs/jobs.md), run by an agent on testor's machine or on
  another one that sends its runs over HTTPS; next, container and Kubernetes executors.
- A per-project queue, so a second run of a project waits instead of overwriting the snapshot
  the first one uses; per-run workspaces.
- API-triggered runs: an `execute` scope, commands limited to a project's allow-list at a
  commit, off unless `execution.enabled`. Scheduled runs from the same allow-list.

### 0.5: many runners, cloud native

- A **hub**: the board and history across controllers and agents, filters by runner label.
- Container and Kubernetes executors (a Job per run), the chart's agent, KEDA on queue depth.
- [Storage, queue and event ports](docs/design/ports.md): SQLite or PostgreSQL for the index,
  S3-compatible object storage for files, RabbitMQ, NATS or SQS for jobs.
- OpenTelemetry traces of runs.

### 0.6: teams

- [Identity](docs/design/identity.md): OpenID Connect sign-in, asymmetric tokens (JWKS),
  projects and teams, workload identity and a secrets broker.
- Release gates on signed attestations; check runs on pull requests from webhooks.

## 1.0: stable

1.0.0 is released when the public surfaces in [VERSIONING.md](VERSIONING.md) have been used
without breaking changes for two minor releases: `/api/v1`, the MCP tools, the run record, the
configuration files and the Taskfiles' variables. From then on, a breaking change waits for a
major release, with a deprecation period before it.

## Not planned

- A hosted service run by the project: testor is software you run yourself.
- A replacement for CI services: testor runs the checks of people working on code, on machines
  they choose, and can feed CI (`/api/v1`) but does not replace a merge gate.
- Building or packaging projects beyond running their commands.
