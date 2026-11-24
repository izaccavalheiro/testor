# HTTP and SSE API

testor listens on port 6767 (`TESTOR_PORT`). Responses are JSON unless noted. There is no
authentication (see the README's security section); `POST` and `DELETE` need the header
`X-Testor: 1`.

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
| `stats`         | `{disk: {free, total}, screenshots: {count, bytes, oldest}, lastCleanup}` |
| `device`        | `{sample, point}`: a device sample and its history point              |
| `device_static` | the static device facts (at start and hourly)                         |

### `GET /events/runs/:id`

One run. First event:

- `snapshot`: `{run, specs[], screenshots[], log, logBytes, truncated}`: `log` is the end of
  the output (up to 256 KB) as text, up to byte `logBytes`

Then:

| Event         | Data                                                                    |
| ------------- | ----------------------------------------------------------------------- |
| `log`         | `{text, from, to}`: new lines, at byte offsets `from`..`to` of the log  |
| `specs`       | `[{file, runner, tests, failed, skipped, durationMs, status}]`          |
| `run`         | the run record (when it ends or is settled)                             |
| `screenshots` | `[{path, url, bytes, takenAt, spec}]` (when it ends)                    |
| `removed`     | `{id}`: the run was deleted                                             |

Both streams send a comment every 15 s and ask the browser to reconnect after 3 s if the
connection drops; a reconnection starts with a fresh snapshot.

```sh
curl -N http://my-runner:6767/events
```

## JSON

| Request                       | Returns                                                         |
| ----------------------------- | --------------------------------------------------------------- |
| `GET /api/health`             | `{ok, app, version, elixir, otp, uptimeMs, os_pid, home}`       |
| `GET /api/state`              | the `/events` snapshot                                          |
| `GET /api/runs/:id`           | the `/events/runs/:id` snapshot                                 |
| `GET /api/runs/:id/log?tail=N`| the last `N` bytes of the output (default 512 KB) as `text/plain`; headers `X-Log-Size`, `X-Log-Truncated` |
| `GET /api/screenshots`        | every screenshot, newest first, with `runId`, `project`, `kind`, `status`, `spec` |
| `GET /api/device`             | `{static, sample, history[]}`                                   |
| `GET /shots/<run>/<path>`     | a screenshot (image)                                            |
| `POST /api/runs/:id/cancel`   | kills a running run's process tree; the settled record (409 if it is not running) |
| `DELETE /api/runs/:id`        | deletes a finished run, its log and screenshots (409 while it runs) |
| `POST /api/cleanup`           | runs the janitor; `{at, reason, removed: {runs, screenshotFolders, looseFiles, bytes}}` |

```sh
curl -s http://my-runner:6767/api/state | jq '.history[0]'
curl -s -X POST -H 'X-Testor: 1' http://my-runner:6767/api/runs/<id>/cancel
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

`point` (history): `{t, cpu, mem, gpu, diskRead, diskWrite, diskActive, netRx, netTx}`.
