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

## Next milestones

### 0.3: install anywhere

Make a runner take minutes, without an Elixir toolchain on it.

- Prebuilt release archives for Windows, Linux and macOS on every GitHub release (the release
  workflow builds them from 0.2.0), and `install.ps1 -FromRelease <version>` to install one.
- An OCI container image of the orchestrator for Linux runners and for hosting the dashboard
  apart from the runner, reading the testor home from a volume; a Compose example.
- `task testor:upgrade` with a check that the installed version is older, and a documented
  rollback.
- Installer options for the service's environment (`-Bind`, extra variables), kept across
  redeploys on every OS.
- The dashboard shows testor's own version and links to the release notes.

### 0.4: many runners

One place to see every machine.

- A **hub** mode: one testor collects runs from several runners (each runner's testor pushes or
  the hub pulls over `/api/v1`), with runner labels (`os`, `arch`, `gpu`, free-form).
- The board and history across runners; filters by runner and label.
- `remote.yml` picks a runner by label (`RUNNER_LABELS: windows gpu`) among the ones the
  workstation can reach.

### 0.5: queues and scheduling (opt-in)

- A per-project queue, so a second run of a project waits instead of overwriting the snapshot
  the first one uses (today such overlaps are only flagged).
- Optional API-triggered runs: a new `execute` scope, commands limited to the ones a project's
  allow-list declares, off unless `execution.enabled`. SSH stays the default path.
- Scheduled runs (nightly suites) from the same allow-list.
- Notifications: webhooks on run end, with a payload in the `/api/v1` run shape.

### 0.6: cloud native

- **Ephemeral runners**: a run in a fresh container or Kubernetes pod (Linux), its artifacts
  kept by the hub; a Helm chart for the hub.
- Pluggable storage: the run index in SQLite or PostgreSQL, logs and artifacts in
  S3-compatible object storage, next to today's files-on-disk default.
- Observability: Prometheus `/metrics` (runs, durations, failures, device load) and
  OpenTelemetry traces of runs.
- Built-in TLS (certificates from files or ACME), so a proxy is optional.

### 0.7: teams

- OpenID Connect sign-in (GitHub, Google, Microsoft Entra ID, Keycloak, ...), mapped to roles.
- Projects and teams: who sees and operates which project's runs.
- Flaky-test detection: specs that fail and pass on the same commit, trends per spec.

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
