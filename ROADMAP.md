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
| **0.5.0** | Agents on other machines: an agent with `"upload": true` keeps its own home and sends each run to testor over HTTPS (record, log chunks at offsets, screenshots and artifacts); remote runs are live, parsed, signed and cancellable like local ones | released |
| **0.6.0** | Agents in containers and Kubernetes: the agent image, the Helm chart's agents with KEDA autoscaling on queued jobs, repositories cloned on demand; spec results from Vitest 5 (its verbose reporter) | released |
| **0.7.0** | Runs signed by their agent: ECDSA P-256 keys pinned on first lease, an in-toto attestation per remote run checked byte for byte against the files received, verifiable with OpenSSL | released |
| **0.8.0** | Teams and identity: per-project access and a role per project; EdDSA tokens with a published JWKS; single sign-on with OpenID Connect; secrets for jobs from Vault, cloud secret managers and SOPS, resolved on the runner and masked; identity tokens for jobs (testor as an OIDC issuer for cloud credentials); isolated workspaces; scheduled jobs; OpenTelemetry traces joined to CI's; the agent image for arm64 | released |
| **0.9.0** | Delivery: release gates on signed results (for pipelines and OPA), commit statuses on GitHub and GitLab pull requests, approvals of AI agents' actions, DORA metrics, status badges and a Backstage guide | released |
| **0.10.0** | Storage: signed runs archived to S3-compatible storage (encrypted, optionally locked; SigV4 without a dependency), the job queue in PostgreSQL shared by several testors | released |
| **0.11.0** | Several testors serving one team: one shared home and one PostgreSQL, claims for what must happen once, shared approvals, an audit trail per testor; the Helm chart's replicas | released |
| **0.12.0** | The hub: one board across several testors (each project's latest result, a link back), filtered by label | released |
| **0.13.0** | The whole plan after 0.12, in one release: Terraform and ACME, mutation testing, universal result formats, heavy jobs, SQS and NATS queues, object storage (S3 and PostgreSQL, snapshots, incremental state), `testor run` handoff, sharding and impact analysis, MCP offload tools, the profiler, sizing and spot preemption | released |
| **0.14.0** | A batch's shards on the dashboard; the Helm chart published with the release; fixes from 0.13.0's release (a large snapshot's lease, slots preempted on SIGTERM) | released |
| **0.15.0** | Runs in Azure Blob Storage (Shared Key or Entra workload identity, SAS links, tested against Azurite): the last item of the plan after 0.12 | released |

## Next milestones

The milestones planned after 0.12 (0.13.0 to 0.21.0, one per theme) all shipped together in
0.13.0. What is left is 1.0: the public surfaces ([VERSIONING.md](VERSIONING.md)) used for two
minor releases without a breaking change.

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
