# HTTP and SSE API

testor listens on port 6767 (`TESTOR_PORT`; `TESTOR_BIND` picks the address). Responses are
JSON unless noted. There are three interfaces over the same data:

- [`/api/v1`](#versioned-api-apiv1): the versioned API for scripts, CI and other programs,
  described by an OpenAPI 3.1 document;
- [`/mcp`](mcp.md): the MCP server, for AI agents;
- the dashboard's own routes (`/api/*`, `/events`), below.

## Authentication

Off until `auth.json` has a user ([security.md](security.md)). Then every request needs
HTTP Basic credentials or `Authorization: Bearer <token>`, except `GET /api/health`,
`GET /api/v1/health`, `GET /api/v1/openapi.json` and signed file links (`/s/...`). Without
credentials: `401` with `WWW-Authenticate: Basic realm="testor"` and `Bearer realm="testor"`;
without the scope a route needs: `403`; after 10 failures in 15 minutes: `429` and
`Retry-After`.

Scopes: `read` for every `GET`; `operate` for `POST` and `DELETE`;
`maintain` for `POST .../maintenance/clean`.

A `POST` or `DELETE` without a Bearer token needs the header `X-Testor: 1` or a JSON body
(`Content-Type: application/json`), and is refused with an `Origin` other than the server.

## Versioned API: `/api/v1`

`GET /api/v1/openapi.json` describes it. Collections answer `{"data": [...]}` (and `"next"`
where they page), errors `{"error": {"code", "message"}}`.

| Request | Returns |
| ------- | ------- |
| `GET /api/v1/health` | `{ok, app, version, auth}`, plus versions and paths with the `read` scope |
| `POST /api/v1/auth/token` | with Basic credentials: `{access_token, token_type: "Bearer", expires_in, scope}`. Body (JSON or form, optional): `grant_type=client_credentials`, `scope` (a subset of the user's), `expires_in` (seconds). Errors as OAuth 2.0: `{error, error_description}` |
| `GET /.well-known/jwks.json` | the public keys tokens are signed with (JSON Web Key Set, Ed25519), without credentials |
| `GET /api/v1/auth/me` | `{authEnabled, user, via, scopes, expiresAt}` |
| `GET /api/v1/runs?status=&project=&kind=&q=&limit=&before=` | runs, newest first: `{data, next}`; `next` is the `before` of the next page |
| `GET /api/v1/runs/:id` | `{run, specs, screenshots, artifacts, logBytes}` |
| `GET /api/v1/runs/:id/attestation` | the run's signed attestation (DSSE envelope of an in-toto statement; [attestation.md](attestation.md)); `404` until it is signed |
| `GET /api/v1/attestation/key` | the public key attestations are signed with: `algorithm`, `keyid`, `publicKey` (PEM) |
| `GET /api/v1/runs/:id/log?tail=&grep=&context=` | the end of the output as text; with `grep`, the matching lines (numbered) and `X-Log-Matches` |
| `GET /api/v1/runs/:id/events` | the run's event stream (as `/events/runs/:id`) |
| `POST /api/v1/runs/:id/cancel` | the cancelled run; `409` when it is not running |
| `DELETE /api/v1/runs/:id` | `{deleted}`; `409` while it runs |
| `GET /api/v1/events` | the global event stream (as `/events`) |
| `GET /api/v1/projects` | `{data: [{project, kind, runs, latest, recent}]}` |
| `GET /api/v1/sessions`, `/stats`, `/device`, `/screenshots`, `/artifacts` | as below |
| `POST /api/v1/cleanup` | runs the janitor |
| `GET /api/v1/maintenance`, `POST .../scan`, `POST .../clean` | as below |

```sh
TOKEN=$(curl -s -u ada -X POST http://my-runner:6767/api/v1/auth/token -d grant_type=client_credentials | jq -r .access_token)
curl -s -H "authorization: Bearer $TOKEN" 'http://my-runner:6767/api/v1/runs?status=failed&limit=5' | jq '.data[].id'
curl -s -H "authorization: Bearer $TOKEN" "http://my-runner:6767/api/v1/runs/$ID/log?grep=FAIL&context=3"
```

## Jobs and agents

| Endpoint | Scope | |
| -------- | ----- | - |
| `GET /api/v1/jobs?status=` | read | jobs, newest first |
| `GET /api/v1/jobs/:id` | read | one job |
| `POST /api/v1/jobs` | execute | queue `{project, kind, labels?, ref?}`: `201`, or `403` while `execution.enabled` is off |
| `POST /api/v1/jobs/:id/cancel` | execute | cancel a queued or running job |
| `POST /api/v1/agent/lease` | agent | `{labels, wait}`: the oldest job this agent can take (`200`), or `204` after `wait` seconds (25 at most) |
| `POST /api/v1/agent/jobs/:id/heartbeat` | agent | renew the lease: `{"cancel": bool}` |
| `POST /api/v1/agent/jobs/:id/finish` | agent | `{exitCode, error?}` |
| `PUT /api/v1/agent/jobs/:id/run` | agent | a remote agent's run record (run.ps1's): binds the run to the job |
| `POST /api/v1/agent/jobs/:id/log?offset=` | agent | append a chunk (1 MB at most) at the log's size; `409` with `X-Log-Size` otherwise |
| `PUT /api/v1/agent/jobs/:id/files/<screenshots or artifacts>/<path>` | agent | a screenshot or artifact of the run |
| `PUT /api/v1/agent/jobs/:id/attestation` | agent | the agent's signed attestation of the run (ECDSA P-256); checked against the files received |
| `GET /api/v1/agents` | read | agents and their pinned signing keys (`publicKey`, `keyid`, `pinnedAt`) |
| `GET /api/v1/runs/:id/attestation?by=agent` | read | the attestation the run's agent signed |

See [jobs.md](jobs.md).

## Prometheus metrics

`GET /metrics` (scope `read`) is the Prometheus text format: `testor_build_info`,
`testor_runs{status}`, `testor_jobs{status}` (`queued`: what an autoscaler scales agents on), `testor_last_run_success{project,kind}`,
`testor_last_run_timestamp_seconds`, `testor_last_run_duration_seconds`,
`testor_event_streams`, `testor_disk_free_bytes`, `testor_disk_size_bytes`,
`testor_stored_bytes{area}`, `testor_cpu_ratio`, `testor_memory_available_bytes`,
`testor_memory_total_bytes`. Scrape it with a Bearer token:

```yaml
scrape_configs:
  - job_name: testor
    authorization: { credentials_file: /etc/prometheus/testor.token }
    static_configs: [{ targets: ["my-runner:6767"] }]
```

## Webhooks

When a run ends, testor POSTs `{"event": "run.finished", "id", "sentAt", "run", "links"}` to
the endpoints in `webhooks.json` in the secrets folder:

```json
{"endpoints": [{"url": "https://ci.example.com/hooks/testor", "secret": "<32+ random characters>",
                "events": ["run.finished"], "projects": ["my-app"]}]}
```

`X-Testor-Signature: sha256=<hex>` is the HMAC-SHA256 of `<X-Testor-Timestamp>.<body>` with the
endpoint's secret; check it in constant time and refuse old timestamps. Deliveries without a
2xx answer are tried again after 1, 10 and 60 seconds. Endpoints are set by whoever can write
the secrets folder, never through the API.

## Audit trail

`GET /api/v1/audit?limit=100` (scope `maintain`): `{"entries": [...], "verified": {"ok": true,
"entries": N}}`, or `{"ok": false, "line": n, "reason": "chain" | "signature" | "malformed"}`
when the trail was changed. See [security.md](security.md#audit).

## The dashboard's routes

Kept as they are for the dashboard; errors are `{"error": "message"}`.

## Server-sent events

### `GET /events`

The dashboard's main stream. First event:

- `snapshot`: `{host, now, running[], history[], sessions[], stats, device, config, paths}`
  - `running[]` and `history[]`: run records (see [architecture.md](architecture.md#the-run-record)),
    newest first; running ones carry their live `summary`, `currentSpec`, `logTail`, `logBytes`
  - `device`: `{static, sample, history[]}` (see below)

Then, as things happen:

| Event           | Data                                                                  |
| --------------- | --------------------------------------------------------------------- |
| `run`           | a run record: a run started, ended or changed                        |
| `live`          | `{id, summary, currentSpec, logTail, logBytes}` of a running run, at most once a second |
| `run_removed`   | `{id}`                                                                |
| `sessions`      | `[{pid, startedAt, project, command}]`: PowerShell sessions in the workspace that run.ps1 did not start |
| `stats`         | `{disk: {free, total}, screenshots: {count, bytes, oldest}, artifacts: {runs, files, bytes}, lastCleanup}` |
| `maintenance`   | the maintenance state (see `GET /api/maintenance`), when a scan or a cleaning starts or ends |
| `device`        | `{sample, point}`: a device sample and its history point              |
| `device_static` | the static device facts (at start and hourly)                         |

### `GET /events/runs/:id`

One run. First event:

- `snapshot`: `{run, specs[], screenshots[], artifacts[], log, logBytes, truncated}`: `log` is
  the end of the output (up to 256 KB) as text, up to byte `logBytes`; `artifacts[]` is
  `[{path, kind, url, bytes, files, modifiedAt}]`, where `kind` is `report` (a folder with an
  `index.html`, whose `url` opens it), `video`, `image`, `html`, `text` or `file`

Then:

| Event         | Data                                                                    |
| ------------- | ----------------------------------------------------------------------- |
| `log`         | `{text, from, to}`: new lines, at byte offsets `from`..`to` of the log  |
| `specs`       | `[{file, runner, tests, failed, skipped, durationMs, status}]`          |
| `run`         | the run record (when it ends or is settled)                             |
| `screenshots` | `[{path, url, bytes, takenAt, spec}]` (when it ends)                    |
| `artifacts`   | `[{path, kind, url, bytes, files, modifiedAt}]` (when it ends)          |
| `removed`     | `{id}`: the run was deleted                                             |

Both streams send a comment every 15 s and ask the browser to reconnect after 3 s if the
connection drops; a reconnection starts with a fresh snapshot.

```sh
curl -N http://my-runner:6767/events
```

## JSON

| Request                       | Returns                                                         |
| ----------------------------- | --------------------------------------------------------------- |
| `GET /api/health`             | `{ok, app, version, auth}`; with the `read` scope also `elixir, otp, uptimeMs, os_pid, home` |
| `GET /api/state`              | the `/events` snapshot                                          |
| `GET /api/runs/:id`           | the `/events/runs/:id` snapshot                                 |
| `GET /api/runs/:id/log?tail=N`| the last `N` bytes of the output (default 512 KB) as `text/plain`; headers `X-Log-Size`, `X-Log-Truncated` |
| `GET /api/screenshots`        | every screenshot, newest first, with `runId`, `project`, `kind`, `status`, `spec` |
| `GET /api/artifacts`          | every run that kept artifacts, newest first: `[{runId, project, kind, status, startedAt, artifacts[]}]` |
| `GET /api/device`             | `{static, sample, history[]}`                                   |
| `GET /shots/<run>/<path>`     | a screenshot (image)                                            |
| `GET /s/<sig>/shots/...`, `GET /s/<sig>/artifacts/...` | the same through a signed link, without credentials (the URLs every answer gives while authentication is on) |
| `GET /artifacts/<run>/<path>` | an artifact: shown when browsers show its type, a download otherwise; honours a single `Range`; served with `Content-Security-Policy: sandbox allow-scripts allow-popups allow-downloads`, `X-Content-Type-Options: nosniff` and `Access-Control-Allow-Origin: *` |
| `POST /api/runs/:id/cancel`   | kills a running run's process tree; the settled record (409 if it is not running) |
| `DELETE /api/runs/:id`        | deletes a finished run, its log and screenshots (409 while it runs) |
| `POST /api/cleanup`           | runs the janitor; `{at, reason, removed: {runs, screenshotFolders, artifactFolders, looseFiles, bytes}}` |
| `GET /api/maintenance`        | `{enabled, settings, scanning, cleaning, scan, lastClean, error}`; `scan` is `{id, at, targets[]}`, a target `{id, kind, label, path, bytes, files, lastUsed, suggested, note}` |
| `POST /api/maintenance/scan`  | measures the targets in the background (202); the result comes as a `maintenance` event |
| `POST /api/maintenance/clean` | body `{scanId, targets: [id, ...]}`: deletes those targets of that scan in the background, then scans again (202). 403 while `maintenance.enabled` is off, 409 while a run, a session, a scan or a cleaning is in progress or when `scanId` is not the last scan, 400 for an id the scan does not have |

```sh
curl -s -u ada http://my-runner:6767/api/state | jq '.history[0]'
curl -s -u ada -X POST -H 'X-Testor: 1' http://my-runner:6767/api/runs/<id>/cancel
```

## Device samples

`static`: `{host, os: {name, version, build, architecture, installedAt, bootedAt, locale,
timezone, powershell}, machine: {manufacturer, model, bios}, cpu: {name, cores, threads, maxMHz,
l2KB, l3KB}, memory: {total, installed, modules[]}, gpus[], disks[]}`.

`sample`: `{at, full, cpu, cores[], processes, threads, queue, memory: {available, committed,
commitLimit, cache, pagesPerSec}, disk: {read, write, active}, network[]}`; a full sample adds
`gpu: {util, engines, dedicated, shared}`, `volumes[]`, `battery`, `handles`, `top[]` (the
busiest processes by CPU and by memory: `{pid, parent, name, cpu, mem, ws, threads, handles,
run}`) and `runs` (by run pid: `{processes, cpu, mem, top[]}`). Rates are per second, CPU in
percent of the whole machine, sizes in bytes.

Linux and macOS fill the same fields where they can and leave the rest null: `handles`; on
macOS `cores` (empty), `threads`, `queue`, `disk.read`/`write`/`active` (the combined
`disk.io` instead) and GPU load; GPU load on Linux only for NVIDIA GPUs. A Unix battery's
`status` is text (`charging`, `discharging`, ...) where Windows gives a `Win32_Battery` code.
`static.platform` is `linux` or `macos` (absent on Windows).

`point` (history): `{t, cpu, mem, gpu, diskRead, diskWrite, diskActive, netRx, netTx}`.
