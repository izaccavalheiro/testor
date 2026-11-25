# Architecture

testor has three parts: a wrapper that records runs (`runner/run.ps1`), an orchestrator that
follows and serves them (`orchestrator/`), and the Taskfiles that send work from the
workstation (`taskfiles/`). They meet in files, not in a protocol: the wrapper writes a run's
record and log, the orchestrator reads them. A run is recorded whether or not the orchestrator
is up, and the orchestrator picks up whatever happened while it was down.

## A run, end to end

1. `task test` on the workstation runs `runner:sync`: `git ls-files` lists the working tree
   (tracked and untracked files, minus what `.gitignore` excludes), `tar` packs it and `ssh`
   unpacks it in `~/test-run/<project>` on the runner, after deleting the previous snapshot's
   files except dependencies and build caches (`node_modules`, `target`, ...).
2. `runner:exec` opens one SSH session in that folder and runs the command in PowerShell 7
   through `run.ps1 -Project <project> -Kind <task> -Body { <command> }`.
3. `run.ps1` writes `runs\<id>.json` (`status: running`, with the session's pid), runs the
   command, and copies every line to `logs\<id>.log` while passing stdout to stdout and stderr
   to stderr. It sets the console to UTF-8 for the duration: Windows decodes a program's
   output with the console code page once PowerShell handles it.
4. The orchestrator's `Store` sees the new record within 300 ms and starts a `RunTracker`,
   which tails the log every 250 ms, feeds new lines to the `SpecParser` and publishes them.
5. When the command ends, `run.ps1` copies the images it produced into `screenshots\<id>\`,
   and the artifacts the task named (`-Artifacts`, from `ARTIFACTS` in `remote.yml`) and the
   videos it produced into `artifacts\<id>\`, then rewrites the record with `endedAt`, `status`, `exitCode` and `durationMs`. Its own
   failures are only warnings; the command's error is rethrown, so the SSH session, and the
   `task` on the workstation, exit as they would without testor.
6. The store sees the final record, stores the spec summary in it, and publishes the run's
   end; the tracker reads the last lines and stops.

If the SSH session dies (a closed laptop lid, a killed terminal), `run.ps1` never writes the
end: the tracker notices the pid is gone and settles the run as `aborted`.

Cancelling asks the run first: testor writes `cancel/<id>`, which a thread of `run.ps1` watches
for; the run's own session then ends its process tree (`taskkill /T` on Windows; on Unix every
descendant `ps` lists is killed with a system call, the run's PowerShell last), so testor never
needs to kill processes of
another account. When the process is still there after 5 seconds (a `run.ps1` from before
0.3), testor kills the tree itself, after checking the pid is neither testor nor a process
started after the run. Either way the run is settled as `cancelled`.

When a run is finalized, testor signs what it observed (an in-toto statement in a DSSE
envelope, Ed25519) into `attestations/<id>.dsse.json`: see [attestation.md](attestation.md).

## Remote scripts

Every remote step is a PowerShell script: a shared prelude (stop on errors, UTF-8 output,
the workspace path; on Windows, the machine PATH that sshd's sessions miss) followed by the
step. The Taskfile encodes it with go-task's `b64enc` and runs

```text
ssh <runner> "pwsh -NoProfile -NonInteractive -Command '&([scriptblock]::Create([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(\"<base64>\"))))'"
```

The single quotes survive both kinds of login shell a runner may have (a POSIX shell on Linux
and macOS, PowerShell on Windows), so nothing depends on quoting rules, and the workstation
needs no tool beyond `ssh`, `git` and `tar`. `sync` pipes the snapshot into the same session,
where `tar` reads it from stdin.

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
| `artifacts`, `artifactsBytes` | run.ps1 | how many artifact files were kept, and their size     |
| `artifactsSkipped` | run.ps1 | artifacts not kept because they would pass `artifacts.maxRunMB`     |
| `summary`     | orchestrator | spec files and tests passed, failed, skipped                     |
| `warning`     | orchestrator | set when another run of the same project overlapped              |

## Orchestrator processes

```text
Testor.Supervisor
├── EventRegistry       pub/sub: "global" and {"run", id} topics
├── TrackerRegistry     one name per tracked run
├── TaskSupervisor      PowerShell queries run here, never in a GenServer
├── Auth.Guard          verified credentials (briefly) and failed attempts by address
├── TrackerSupervisor   ── RunTracker (one per running run)
├── Store               run index in ETS; scans runs\, settles, publishes
├── Sessions            pwsh sessions in the workspace that run.ps1 did not start
├── Stats               disk space of the data drive, screenshots and artifacts folder sizes, last cleanup
├── Janitor             retention: runs by count and age, screenshots by age and size
├── Device              device stats (Windows: a PowerShell port; Linux, macOS: Elixir) and their history
├── Maintenance         measures and, when asked, deletes what testing leaves on the runner
└── Bandit              HTTP: authentication, the page, the JSON APIs, the SSE streams, MCP
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
| Vitest     | ` ✓ tests/a.test.ts (12 tests) 34ms`, ` ❯ src/b.test.ts (3 tests \| 1 failed)`; verbose: ` ✓ tests/a.test.ts > adds 3ms` (counted per file, unless the file has its own line) |
| Playwright | `  ok 3 [chromium] › e2e/auth.spec.ts:12:3 › signs in (1.2s)` (`ok`/`x` on Windows) |
| pytest     | `tests/test_api.py ..F.s   [ 40%]`                                              |
| go test    | `ok   example.com/pkg 0.12s`, `FAIL example.com/pkg 0.3s`                        |
| cargo test | `Running tests/x.rs (...)` followed by `test result: ok. 12 passed; ...`        |

A screenshot belongs to the spec file whose name (without `.spec.ts`, `.test.js`, ...) its
path contains: Playwright names its result folders after the spec.

## Device stats

On Windows, `Device` keeps one PowerShell running `priv/sysinfo.ps1` as an Erlang port and
sends it one command per line (`static`, `sample light`, `sample full <pids>`); each answer is
one JSON line. Rates come from raw performance counters and the previous sample: the formatted
counters take a second per query, and `Get-Counter` paths are localized.

On Linux and macOS, `Testor.Device.Unix` samples in a task, in the same shape: Linux reads
`/proc` and `/sys` (CPU per core from `/proc/stat`, processes from `/proc/<pid>/stat`, disks
from `/proc/diskstats`; `nvidia-smi` and `lsblk` when present); macOS asks `sysctl`,
`vm_stat`, `ps`, `netstat`, `iostat`, `df` and `pmset`. A value a platform cannot give is null,
and the dashboard leaves it out.

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
`screenshots.maxTotalMB`, and does the same for artifact folders (`artifacts.*`). A running
run is never touched. Override the defaults in `<home>\config.json` (any key may be left out):

```json
{ "screenshots": { "maxAgeDays": 7, "maxTotalMB": 1024 },
  "artifacts": { "maxAgeDays": 7, "maxTotalMB": 2048, "maxRunMB": 256 },
  "runs": { "maxRuns": 500, "maxAgeDays": 30 },
  "cleanupIntervalMinutes": 30,
  "maintenance": { "enabled": false, "tempMinAgeDays": 7, "snapshotIdleDays": 14 } }
```

## Artifacts

A task names what to keep with `ARTIFACTS` (space-separated paths relative to the project,
wildcards allowed); `run.ps1` receives them as `-Artifacts`. At the end of the run it copies
each one the run wrote (a folder counts when any of its files is new: reports copy their
assets with the original dates) into `artifacts\<id>\`, at its path in the project, in order
until `artifacts.maxRunMB` is reached; the rest is listed in the record's `artifactsSkipped`
and in a warning. Videos (`.webm`, `.mp4`) under the screenshot folders are kept the same way,
and a command may write into `$env:TESTOR_ARTIFACT_DIR` directly.

The dashboard lists a run's artifacts with every folder that holds an `index.html` (coverage,
Playwright's and Vitest's HTML reports) as one report. `/artifacts/...` serves them with
`Content-Security-Policy: sandbox`, so a report's scripts run with an opaque origin and cannot
reach the API with the `X-Testor` header; `Access-Control-Allow-Origin: *` lets them fetch
their own data files. Videos are served by byte ranges, so they seek.

## Maintenance

Testing fills the runner's disk outside testor's folder too: every project snapshot keeps its
dependencies and build caches, and the tools keep download and build caches. `Maintenance`
measures, on demand and in a task, a fixed list of targets:

| Target                | What                                                                      |
| --------------------- | ------------------------------------------------------------------------- |
| `snapshot:<project>`  | a snapshot folder in the workspaces; suggested when no run of the project started for `snapshotIdleDays` |
| `temp`                | entries of the user's temporary folder older than `tempMinAgeDays` (on Unix only the user's own) |
| `cache:npm`, `cache:pip`, `cache:go`, `cache:cargo` | the npm cache (`_cacache`), pip's cache, the Go build cache, Cargo's downloaded crates (their environment variables are honoured) |
| `browsers:playwright` | Playwright browser builds a newer build of the same browser replaces       |

Sizes are measured without following symbolic links. Cleaning takes the scan's id and target
ids, never paths; it is refused unless `maintenance.enabled` is true, while a recorded run or a
PowerShell session in the workspaces is running, and when the scan is not the last one. It
deletes in a task (a snapshot's `.lockhash` first, so a half-deleted snapshot reinstalls its
dependencies), reports what it freed and what it could not delete, and scans again. Browser
caches, installed programs and system folders are out of its reach by design: testor runs as
the user, without elevation.

## Folders on the runner

| Path (defaults)                 | What                                                         |
| ------------------------------- | ------------------------------------------------------------ |
| `~/test-run/<project>`          | a project's snapshot, where its commands run                 |
| `~/test-run/.testor/run.ps1`    | the wrapper the Taskfiles call                               |
| `~/test-run/.testor/runs/`, `logs/`, `screenshots/`, `artifacts/` | the data                   |
| `~/test-run/.testor/cancel/`, `attestations/` | cancel requests to runs, signed attestations of finished runs |
| `~/test-run/.testor/src/`       | the uploaded sources, with `deps` and `_build` kept between deploys |
| `~/test-run/.testor/app/`       | the release the service runs                                 |
| `~/test-run/.testor/testor.log` | the orchestrator's log                                       |

`TESTOR_WORKSPACES`, `TESTOR_HOME` and `TESTOR_PORT` change them for the orchestrator;
`WORKSPACES`, `HOME_DIR` and `PORT` for the Taskfiles.
