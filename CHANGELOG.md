# Changelog

Every notable change to testor. The format follows [Keep a Changelog](https://keepachangelog.com)
and testor follows [Semantic Versioning](https://semver.org): see [VERSIONING.md](VERSIONING.md)
for what a version number promises. Sections use **Breaking**, **Added**, **Changed**,
**Deprecated**, **Removed**, **Fixed** and **Security**.

## Unreleased

### Added

- **Per-project access**: a user (and their tokens) can be limited to projects
  (`"projects": ["web", "lib-*"]` in `auth.json`, `task testor:projects`, or
  `Testor.Auth.CLI.projects`). Another project's runs, jobs, logs, files, attestations and
  event streams answer `404`; lists, the dashboard's state, live streams and MCP's tools leave
  them out; what spans every project (maintenance, audit, metrics, sessions, agents' keys)
  answers `403`; jobs are queued and taken only for one's projects. A list that cannot be read
  fails closed. `/api/v1/auth/me` shows `projects`.
- **Tokens anyone can verify**: tokens are signed with Ed25519 (`EdDSA`, `kid` the key's
  JWK thumbprint) and the public keys are published at `GET /.well-known/jwks.json`, so a
  gateway, a hub or another service verifies a testor token without a secret.
  `Testor.Auth.CLI.roll_token_key` adds a new key while the previous one verifies its tokens
  until they expire; `TESTOR_TOKEN_KEY` shares one key across replicas.
- **Secrets for jobs**: a project in `agent.json` maps environment variables to where their
  values are (`env:`, `file:`, `vault:`, `aws:`, `gcp:`, `azure:`, `sops:`); the agent reads
  them on its machine for each job, so testor never sees them, and `run.ps1` masks them in the
  log. A secret that cannot be read fails the job naming the secret. The Helm chart's agents
  take `agents.env`, `agents.secretMounts`, `agents.vault` and `agents.serviceAccount` (cloud
  workload identity, Vault's Kubernetes login).
- `run.ps1` also masks each line of a secret that spans lines.
- **Identity tokens for jobs**: with `jobTokens` in `auth.json`, testor is an OpenID Connect
  issuer for its jobs (`/.well-known/openid-configuration`, RS256 keys in the JWKS): the agent
  holding a job gets a short token for it (`sub` = `project:<p>:kind:<k>`, `ref`, `job_id`...)
  that AWS, Google Cloud, Azure and Vault trade for short-lived credentials. A project's
  `identity` in `agent.json` writes it where the run's SDKs look (`AWS_WEB_IDENTITY_TOKEN_FILE`)
  and renews it; `vault.jwtRole` logs in to Vault with it. `Testor.Auth.CLI.roll_job_token_key`.

- **Single sign-on**: the dashboard signs people in with an OpenID Connect provider (`oidc` in
  `auth.json`): the code flow with PKCE, ID tokens checked against the provider's JWKS
  (RS256, ES256, EdDSA), groups mapped to a role and to projects, a session cookie
  (`HttpOnly`, `SameSite=Lax`, `Secure` over https) that is not a Bearer token. A visitor is
  sent to the provider; `/?basic` keeps the password sign-in for break-glass use. The
  dashboard shows who is signed in and signs out.

### Changed

- New tokens are EdDSA. HS256 tokens (all of those issued before) are still accepted until
  the next major version; `"tokens": {"acceptHs256": false}` refuses them,
  `"tokens": {"algorithm": "HS256"}` keeps issuing them. `rotate_key` now replaces the token
  keys too. Back up `token-keys.json` with `jwt.key`.

## 0.7.0 - 2026-11-25

### Added

- **Runs signed by their agent** (the agent protocol's third step): an agent makes an ECDSA
  P-256 key on its first start and presents it with each lease; testor pins the first key of
  each agent user and refuses another (`Testor.Auth.CLI.forget_agent_key` resets it). Each run
  an agent sends carries its own in-toto attestation (DSSE), which testor keeps only when its
  signature holds and its digests match the files received exactly. `agentAttested` on runs,
  `GET /api/v1/runs/:id/attestation?by=agent`, `GET /api/v1/agents`; verifiable with OpenSSL.
  Give each agent a user of its own.

## 0.6.0 - 2026-11-25

### Added

- **Agents in containers and Kubernetes**: the agent image `ghcr.io/izaccavalheiro/testor-agent`
  (`runner/Dockerfile`: PowerShell 7, git, unprivileged, read-only root), published with
  provenance; the Helm chart's `agents` (a Deployment of agent pods, their `agent.json`, and an
  optional KEDA `ScaledObject` scaling them on queued jobs); `testor_jobs{status}` in
  `/metrics`. A project in `agent.json` may name a `repository`, cloned for its first job.
  `scripts/container-e2e.sh` runs testor and an agent container through a job, in CI.

### Added

- **Vitest 5**: spec results from Vitest's verbose reporter (` ✓ tests/a.test.ts > adds 3ms`),
  counted per file. Vitest 5's default reporter prints only failed files when it is not on a
  terminal, as under testor: run it with `--reporter=verbose` to see every file. A file's own
  line keeps its totals, so its tests are never counted twice.

### Changed

- The example project uses Vitest 5 with `--reporter=verbose`; its audit is clean (the
  advisories in tinypool and Vitest 3 are gone).

## 0.5.0 - 2026-11-25

### Added

- **Agents on other machines** (the agent protocol's second step): with `"upload": true`, an
  agent keeps a home of its own and sends each run to testor while it runs (its record, its log
  in chunks at offsets, then screenshots, artifacts and the final record), then deletes its
  copy. testor writes them into its home, so remote runs are live, parsed, signed and sent to
  webhooks like local ones. Agents only connect out. A remote run's job lease watches it (an
  agent that stops answering aborts its run), and cancelling reaches the agent at its next
  heartbeat. `PUT /api/v1/agent/jobs/:id/run`, `POST .../log?offset=`, `PUT .../files/...`;
  runs record `remote`.

## 0.4.0 - 2026-11-25

### Added

- **Jobs and agents** (opt-in, the first step of the agent protocol): `POST /api/v1/jobs`
  (scope `execute`) queues a run of a project's task; `runner/agent.ps1` takes jobs by lease,
  runs them through `run.ps1` with the commands of its own `agent.json` (a job never carries a
  command), sends heartbeats and reports the result. Leases, labels, a git ref to check out,
  one job per project at a time, retries when an agent disappears, cancelling. Off until
  `execution.enabled`, and only with authentication. Runs record their `job`. A new `agent`
  role; `admin` gains the `execute` scope. See docs/jobs.md.

## 0.3.1 - 2026-11-25

### Fixed

- `run.ps1` printed `testor: cancel watcher: The pipeline has been stopped.` on stderr at the end
  of every run: stopping its cancel watcher is not an error. The terminal is unchanged again; the
  smoke test now checks that a run's stderr holds nothing of testor's own.

## 0.3.0 - 2026-11-25

### Breaking

- **While authentication is off, only private addresses are answered**: loopback, RFC 1918,
  link-local, Tailscale's 100.64.0.0/10 and IPv6 unique-local, so a runner on a public address
  is no longer open to the internet. Health checks stay public. `TESTOR_ANONYMOUS=any` restores
  the previous behaviour; adding a user (`task testor:user`) is better.
- **Requests for an unknown host name are refused** (`421`): an IP address, `localhost` and
  the machine's own name are answered; any other name (a reverse proxy's public name, a
  Tailscale MagicDNS full name) must be listed in `TESTOR_ALLOWED_HOSTS`.

### Security

- DNS rebinding: the `Host` allow-list above. The `Origin` check alone did not stop it: after
  rebinding, a page's origin and the request's host are the attacker's name.
- Symbolic links and junctions are never followed: not by the file routes (a run could link
  its artifact folder to `jwt.key`), the directory walks (a link loop made them endless), run
  records and logs, nor by `run.ps1` when it copies screenshots and artifacts.
- Cancelling a run checks the process its record names first: never testor itself or a
  process above it, nor a process that started after the run (a reused pid); the run is then
  cancelled without killing anything, with a warning. A record whose pid was not a number
  crashed the store.
- Limits: at most 256 event streams, 16 per user or address (`503`); a log read is 8 MB at
  most (was 64 MB); password hashes run at most twice the schedulers at once (`503`); a user
  is refused after 30 failed passwords in 15 minutes from any addresses, while credentials
  already verified keep working.

### Added

- `TESTOR_TRUSTED_PROXIES`: reverse proxies whose `X-Forwarded-For` names the client, for rate
  limiting, the audit log and the anonymous-access check.
- `TESTOR_ALLOWED_HOSTS`, `TESTOR_ANONYMOUS`, and `TESTOR_SECRETS_DIR` (where `auth.json` and
  `jwt.key` live).
- `install.ps1 -Bind -AllowedHosts -TrustedProxies -Anonymous -SecretsDir` (and `BIND`,
  `ALLOWED_HOSTS`, ... on `task testor:deploy`): the service's environment, saved in
  `<home>/service.json` and kept by later deploys. The Linux unit adds `NoNewPrivileges` and
  `UMask=0077`.

- **Install without Elixir**: `install.ps1 -FromRelease <version|latest>` installs a prebuilt
  release after checking it against the release's `SHA256SUMS` and, with `gh`, its provenance
  attestation (`-RequireAttestation` to insist).
- **Container image** (`orchestrator/Dockerfile`, published as `ghcr.io/izaccavalheiro/testor`
  for linux/amd64 and linux/arm64 with provenance): unprivileged, read-only root, logs to
  stdout (`TESTOR_LOG=stdout`), `TESTOR_ANONYMOUS=loopback` until a user exists; a Compose
  example in `examples/compose`. `bin/testor eval 'Testor.Probe.check()'` is a health probe
  for images without an HTTP client.
- Releases carry `run.ps1`, `install.ps1` and `setup.ps1` (in `SHA256SUMS` and the provenance
  attestation) and an SPDX SBOM with its own attestation; the quick start downloads
  `setup.ps1` from a release instead of the `main` branch.
- An OpenSSF Scorecard workflow, and Dependabot for the image's base images.

- **Signed run attestations**: when a run is finalized, testor signs its record and the
  SHA-256 of its log, screenshots and artifacts (in-toto Statement v1 in a DSSE envelope,
  Ed25519, `signing.key` in the secrets folder). `GET /api/v1/runs/:id/attestation`,
  `GET /api/v1/attestation/key`; verifiable offline with OpenSSL (docs/attestation.md). Runs
  have `attested`.
- **Cooperative cancel**: cancelling writes `cancel/<id>` and `run.ps1` ends its own process
  tree, so the service never kills processes of another account; testor kills the tree itself
  only when the process is still there after 5 s (`run.ps1` from before 0.3).
- **Tests in a separate account**: documented (docs/security.md) and checked in CI in a
  container (`scripts/two-accounts`): the test account cannot read the secrets, change
  `run.ps1` or replace the testor home, and its runs are followed, signed, cancelled and
  deleted. `remote.yml` accepts absolute `WORKSPACES` and `HOME_DIR`.
- **Who started a run**: `run.ps1` records `actor` (the account and SSH client address the
  runner sees, and `TESTOR_ACTOR`, which `remote.yml` sets to `<user>@<workstation>` or `ACTOR`);
  in the API and on the run page.

- **Prometheus metrics** at `GET /metrics` (scope `read`): runs by status, the latest result,
  end and duration of every task, event streams, disk, stored bytes, CPU and memory.
- **Webhooks**: `run.finished` POSTed to the endpoints in `webhooks.json` (secrets folder),
  signed with HMAC-SHA256 over the timestamp and body, retried after 1, 10 and 60 s, HTTPS
  checked against the system's roots.
- **Tamper-evident audit trail**: `audit.jsonl`, an entry per state-changing request and failed
  sign-in, chained by SHA-256 and signed with the attestation key; `GET /api/v1/audit` (scope
  `maintain`) verifies it.
- **Built-in TLS**: `TESTOR_TLS_CERT` and `TESTOR_TLS_KEY` (installer `-TlsCert -TlsKey`,
  deploy `TLS_CERT TLS_KEY`) serve HTTPS only, with strong ciphers and HSTS.
- **Secrets masked in stored logs**: `run.ps1` writes `***` for the values of secret-looking
  environment variables and those named in `TESTOR_MASK`; the terminal is unchanged.
- **MCP output fenced as untrusted**: `get_run_log` wraps run output in
  `<untrusted-output>` with any fence inside defused, and the server's instructions tell agents
  to treat run data as data (prompt injection).

- **Flaky specs**: finished runs keep each spec file's outcome and `remote.yml` records the
  commit, branch and whether the tree had changes (`source`); `GET /api/v1/projects/:project/flaky`
  and the MCP tool `find_flaky_specs` list spec files that passed and failed on one clean commit.
- **Helm chart** (`deploy/helm/testor`): one replica on a persistent volume, hardened pod,
  NetworkPolicy, optional ingress, built-in TLS, admin user from a Secret, ServiceMonitor;
  linted and validated against Kubernetes' schemas in CI.
- Designs for the agent protocol, storage and queue ports, and identity (`docs/design`).

### Fixed

- `task testor:test` clears the runner's ExUnit `tmp` folder: a junction a failed test left
  there failed every later run.

## 0.2.0 - 2026-11-24

### Added

- **Versioned API** (`/api/v1`): runs filtered and paged, a run's log searched with context,
  projects, sessions, stats, device, screenshots, artifacts, maintenance, cancel and delete;
  described by `GET /api/v1/openapi.json` (OpenAPI 3.1). The dashboard's routes are unchanged.
- **MCP server** (`POST /mcp`, Streamable HTTP, stateless): tools `get_status`, `list_runs`,
  `get_run`, `get_run_log`, `wait_for_run`, `list_projects`, `get_device`, `cancel_run`,
  `delete_run`, filtered by the caller's scopes.
- **Authentication**, off until `auth.json` lists a user: HTTP Basic and HS256 JWT bearer
  tokens (`POST /api/v1/auth/token`, client credentials), roles `viewer`/`operator`/`admin`
  granting the scopes `read`/`operate`/`maintain`, PBKDF2-SHA256 passwords, revocation and key
  rotation, rate limiting of failed attempts, signed expiring links for screenshots and
  artifacts, an audit log of state-changing requests. Managed with `task testor:user` and
  `task testor:token` (or `Testor.Auth.CLI` through the release). `TESTOR_BIND` sets the
  listening address.
- **Artifacts**: `ARTIFACTS` in a task (`remote.yml`; `run.ps1 -Artifacts`) keeps the files and
  folders a run writes (coverage, HTML reports, Markdown, JUnit XML, ...) with the run, up to
  `artifacts.maxRunMB` per run; Playwright's videos and `$env:TESTOR_ARTIFACT_DIR` are kept too.
  Run pages list them (reports as one entry, videos with a player), an Artifacts page lists
  every run's, and the janitor limits them by age and size (`artifacts.*`). They are served
  sandboxed (`Content-Security-Policy: sandbox`), with byte ranges.
- **Maintenance**: a Maintenance page and `/api/maintenance` measure what testing leaves on the
  runner (idle project snapshots, old temporary files, the npm, pip, Go and Cargo caches, old
  Playwright browsers) and delete the targets chosen and confirmed, when `maintenance.enabled`
  is set in `config.json` and nothing runs.
- **Documentation site** (`website/`, Docusaurus): concepts, guides for every feature, real
  deployment scenarios, caveats, configuration and operations, the reference pages from
  `docs/`, the roadmap; published to GitHub Pages from `main`.
  Production builds of the site load the Monoid analytics tracker; its origin is the only
  one the site's Content Security Policy allows besides its own.
- **Semantic versioning** ([VERSIONING.md](VERSIONING.md)): the public surfaces a version covers,
  Conventional Commits checked on pull requests, `scripts/release.mjs` (`next`, `bump`, `check`,
  `notes`, `lint-commits`), and a release workflow that builds and attests per-OS archives and
  publishes the GitHub release from a `v*` tag.
- Project files: `CONTRIBUTING.md`, `SECURITY.md`, `CODE_OF_CONDUCT.md`, `ROADMAP.md`, issue and
  pull request templates.
- Tests: integration tests that run the whole server, 100% line coverage enforced (platform
  adapters excepted), a smoke test that covers the API, MCP, cancelling a process tree and
  authentication; `task testor:ci`, `task testor:smoke` and `task testor:format` run them on
  the runner.

### Changed

- State-changing requests are also accepted with a JSON body or a Bearer token instead of
  `X-Testor: 1`, and refused from another `Origin`.
- `GET /api/health` reports versions and paths only to callers with the `read` scope.
- The janitor leaves a run's empty screenshot or artifact folder alone for an hour, so a run
  the store has not seen yet keeps it.

### Fixed

- The store forgets a run whose record disappears even when a scan failed halfway, and does
  not write back the record of a run that was deleted while its tracker settled it.
- Vitest spec lines with a project label (`|unit| tests/a.test.ts`) are parsed.
- `install.ps1` exits 0 when it succeeds.

## 0.1.0

The first release. Runners can be Windows, Linux or macOS machines, and the workstation any of
them: commands run in PowerShell 7 everywhere and reach the runner base64-encoded.

### Added

- **Orchestrator** (Elixir/OTP, Bandit + Plug): follows the runs `run.ps1` records, parses spec
  results from their output (Vitest, Playwright, pytest, go test, cargo test), and streams runs,
  logs and progress to the dashboard over server-sent events. Cancels runs (process tree),
  settles aborted ones, flags overlapping runs of one project, cleans up old runs and
  screenshots.
- **Dashboard**: running runs with live progress and log tails, history with filters, a board of
  the latest result per project and task, run pages with streaming output, spec files and
  screenshots, a screenshots gallery, and device stats (OS, CPU per core, memory, GPU, storage,
  network, battery, top processes, per-run CPU and memory).
- **Runner**: `run.ps1` (records a run, output and exit code unchanged), `install.ps1` (release,
  installed as a scheduled task on Windows, a systemd user service on Linux, a launchd agent on
  macOS), `setup.ps1` (prepares or checks a machine).
- **Taskfiles**: `testor.yml` (manage testor from the workstation), `remote.yml` (run a
  project's checks on the runner).
