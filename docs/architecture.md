# Architecture

testor has three parts: a wrapper that records runs (`runner/run.ps1`), an orchestrator that
follows and serves them (`orchestrator/`), and the Taskfiles that send work from the
workstation (`taskfiles/`). They meet in files, not in a protocol: the wrapper writes a run's
record and log, the orchestrator reads them. A run is recorded whether or not the orchestrator
is up, and the orchestrator picks up whatever happened while it was down.

## A run, end to end

1. `task test` on the workstation runs `runner:sync`: `git ls-files` lists the working tree
   (tracked and untracked files, minus what `.gitignore` excludes), `tar` packs it and `ssh`
   unpacks it in `~\test-run\<project>` on the runner, after deleting the previous snapshot's
   files except dependencies and build caches (`node_modules`, `target`, ...).
2. `runner:exec` opens one SSH session (PowerShell 7) in that folder and runs the command
   through `run.ps1 -Project <project> -Kind <task> -Body { <command> }`.
3. `run.ps1` writes `runs\<id>.json` (`status: running`, with the session's pid), runs the
   command, and copies every line to `logs\<id>.log` while passing stdout to stdout and stderr
   to stderr. It sets the console to UTF-8 for the duration: Windows decodes a program's
   output with the console code page once PowerShell handles it.
4. The orchestrator's `Store` sees the new record within 300 ms and starts a `RunTracker`,
   which tails the log every 250 ms, feeds new lines to the `SpecParser` and publishes them.
5. When the command ends, `run.ps1` copies the images it produced into `screenshots\<id>\`
   and rewrites the record with `endedAt`, `status`, `exitCode` and `durationMs`. Its own
   failures are only warnings; the command's error is rethrown, so the SSH session, and the
   `task` on the workstation, exit as they would without testor.
6. The store sees the final record, stores the spec summary in it, and publishes the run's
   end; the tracker reads the last lines and stops.

If the SSH session dies (a closed laptop lid, a killed terminal), `run.ps1` never writes the
end: the tracker notices the pid is gone and settles the run as `aborted`. Cancelling from the
dashboard kills the session's process tree (`taskkill /T`) and settles it as `cancelled`.

## The run record

`runs\<id>.json`, where `<id>` is `yyyyMMdd-HHmmss-<6 hex>` (UTC), so ids sort by time:

| Field         | Written by   | Meaning                                                          |
| ------------- | ------------ | ---------------------------------------------------------------- |
| `id`          | run.ps1      | the run's id                                                     |
| `project`     | run.ps1      | the project (the snapshot folder's name)                         |
| `kind`        | run.ps1      | the run's type: the task's name (`test`, `lint`, ...)            |
| `command`     | run.ps1      | the command, whitespace collapsed                                |
| `pid`         | run.ps1      | the PowerShell session running it                                |
| `workdir`     | run.ps1      | the folder it ran in                                             |
| `startedAt`   | run.ps1      | ISO 8601, UTC                                                    |
| `status`      | both         | `running`, `passed`, `failed`; the orchestrator adds `aborted` and `cancelled` |
| `endedAt`, `durationMs`, `exitCode`, `error` | run.ps1 (or the orchestrator when it settles a run) | how it ended |
| `screenshots` | run.ps1      | how many images were kept                                        |
| `summary`     | orchestrator | spec files and tests passed, failed, skipped                     |
| `warning`     | orchestrator | set when another run of the same project overlapped              |

## Orchestrator processes

```text
Testor.Supervisor
├── EventRegistry       pub/sub: "global" and {"run", id} topics
├── TrackerRegistry     one name per tracked run
├── TaskSupervisor      PowerShell queries run here, never in a GenServer
├── TrackerSupervisor   ── RunTracker (one per running run)
├── Store               run index in ETS; scans runs\, settles, publishes
├── Sessions            pwsh sessions in the workspace that run.ps1 did not start
├── Stats               disk space of the data drive, screenshots folder size, last cleanup
├── Janitor             retention: runs by count and age, screenshots by age and size
├── Device              the device sampler (a PowerShell port) and its history
└── Bandit              HTTP: the page, the JSON API, the SSE streams
```

Reads go straight to ETS, so a busy dashboard never queues behind the store. Everything that
asks Windows something (PowerShell, `tasklist`) runs in a task or a port, never blocking a
process that others call.

## Live updates

The browser opens `GET /events` and receives a `snapshot` of everything, then events as they
happen (see [api.md](api.md)). A run page opens `GET /events/runs/<id>`: a snapshot with the
end of the log up to byte offset *n*, then `log` events with `from`/`to` offsets, so lines
published between the subscription and the snapshot are dropped rather than shown twice. A
dropped connection reconnects by itself and starts again from a fresh snapshot.

## Spec files from output

Projects keep their reporters. The `SpecParser` reads, line by line and with ANSI codes
removed:

| Runner     | Lines it reads                                                                 |
| ---------- | ------------------------------------------------------------------------------ |
| Vitest     | ` ✓ tests/a.test.ts (12 tests) 34ms`, ` ❯ src/b.test.ts (3 tests \| 1 failed)`  |
| Playwright | `  ok 3 [chromium] › e2e/auth.spec.ts:12:3 › signs in (1.2s)` (`ok`/`x` on Windows) |
| pytest     | `tests/test_api.py ..F.s   [ 40%]`                                              |
| go test    | `ok   example.com/pkg 0.12s`, `FAIL example.com/pkg 0.3s`                        |
| cargo test | `Running tests/x.rs (...)` followed by `test result: ok. 12 passed; ...`        |

A screenshot belongs to the spec file whose name (without `.spec.ts`, `.test.js`, ...) its
path contains: Playwright names its result folders after the spec.

## Device stats

`Device` keeps one PowerShell running `priv/sysinfo.ps1` as an Erlang port and sends it one
command per line (`static`, `sample light`, `sample full <pids>`); each answer is one JSON
line. Rates come from raw performance counters and the previous sample: the formatted
counters take a second per query, and `Get-Counter` paths are localized.

| Sample | Every                          | Holds                                                            |
| ------ | ------------------------------ | ---------------------------------------------------------------- |
| full   | 3 s, while a dashboard is open | light, plus GPU engines and memory, volumes, battery, top processes, each run's process tree |
| light  | 15 s, otherwise                | CPU (total and per core), memory, disk and network throughput     |
| static | at start, then hourly          | OS, machine, CPU model, memory modules, GPUs, physical disks      |

A full sample costs around half a second of one core, so it is taken only while someone looks.
The last 360 points feed the sparklines.

## Retention

The janitor runs at start, every `cleanupIntervalMinutes` and on demand. It keeps the newest
`runs.maxRuns` runs, none older than `runs.maxAgeDays`; then deletes screenshot folders older
than `screenshots.maxAgeDays` and the oldest ones until the folder fits
`screenshots.maxTotalMB`. A running run is never touched. Override the defaults in
`<home>\config.json`:

```json
{ "screenshots": { "maxAgeDays": 7, "maxTotalMB": 1024 },
  "runs": { "maxRuns": 500, "maxAgeDays": 30 },
  "cleanupIntervalMinutes": 30 }
```

## Folders on the runner

| Path (defaults)                 | What                                                         |
| ------------------------------- | ------------------------------------------------------------ |
| `~\test-run\<project>`          | a project's snapshot, where its commands run                 |
| `~\test-run\.testor\run.ps1`    | the wrapper the Taskfiles call                               |
| `~\test-run\.testor\runs\`, `logs\`, `screenshots\` | the data                                 |
| `~\test-run\.testor\src\`       | the uploaded sources, with `deps` and `_build` kept between deploys |
| `~\test-run\.testor\app\`       | the release the scheduled task `Testor` runs                 |
| `~\test-run\.testor\testor.log` | the orchestrator's log                                       |

`TESTOR_WORKSPACES`, `TESTOR_HOME` and `TESTOR_PORT` change them for the orchestrator;
`WORKSPACES`, `HOME_DIR` and `PORT` for the Taskfiles.
