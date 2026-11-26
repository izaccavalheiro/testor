# Heavy jobs

Mutation testing, browser end-to-end suites and large builds need limits: they must end, must
not take the agent down with them, must use the CPUs a container really has, and should land on
agents sized for them.

## Timeouts

- `agent.json`: a command object's `"timeout": "45m"` (or seconds, `90s`, `2h`).
- A job may ask for less: `"timeout": "10m"` in `POST /api/v1/jobs`, capped by the agent's own;
  `execution.defaultTimeout` in config.json gives jobs one when they name none.
- `run.ps1 -TimeoutSeconds` (or `TESTOR_TIMEOUT_SECONDS`), and `TIMEOUT=45m` in `remote.yml`.

Past it, the command's process tree is ended as a cancel ends it and the run is recorded
`failed` with `reason: "timeout"` (exit code 124 if the command's own was 0).

## Limits a container has

On Linux the agent reads its cgroup (v2, else v1) through .NET: every run gets `TESTOR_CPUS`
(the CPU quota, rounded up) and `TESTOR_MEMORY_MB`. Use them in commands:

| Tool | Flag |
| ---- | ---- |
| Jest, Vitest | `--maxWorkers=$env:TESTOR_CPUS` |
| StrykerJS | `--concurrency $env:TESTOR_CPUS` |
| pytest-xdist | `-n $env:TESTOR_CPUS` |
| Playwright | `--workers=$env:TESTOR_CPUS` |
| Gradle | `--max-workers=$env:TESTOR_CPUS` |
| dotnet test | `-m:$env:TESTOR_CPUS` |

With `"limits": "auto"` on a project the agent also sets, when not already set, `GOMAXPROCS`,
`CARGO_BUILD_JOBS`, `DOTNET_PROCESSOR_COUNT`, `PYTEST_XDIST_AUTO_NUM_WORKERS` and
`NODE_OPTIONS=--max-old-space-size` (three quarters of the memory, per CPU). testor's device
stats show the cgroup's limits (`limits`), its memory in use, peak and OOM kills.

## Memory guard

`"memoryGuard": { "warn": 80, "stop": 92 }` on a command or project (`MEMORY_GUARD=80,92` in
`remote.yml`, `run.ps1 -MemoryGuard 80,92`): every second `run.ps1` measures the share of memory
in use, the cgroup's against its limit on Linux, else the run's process tree against the
machine's. At `warn` a line goes to the log; at `stop` the tree is ended and the run recorded
`failed` with `reason: "memory"`, before the kernel's OOM killer takes the agent.

## Agents sized for the work

- Heavy kinds ask for a label (`"labels": ["mutation"]`) that only agents sized for them have.
- `"exclusive": true` on a command marks a job nothing may share an agent with (agents take one
  job at a time today; with several slots this becomes a lock).
- The Helm chart's `agents.profiles`: one Deployment per profile, with its own labels,
  resources (`ephemeral-storage` too), `/dev/shm` (`shmSize`, for browsers), workspace size
  (`workspaceSizeLimit`) and KEDA scaling on its own queue,
  `testor_jobs{status="queued",label="<its last label>"}`. `mode: job` makes it a KEDA
  ScaledJob: a Kubernetes Job per run, whose agent takes one job (`-Once`) and ends with it;
  KEDA creates the pods, so nothing that runs test code may create pods.

## SSH runs: a queue, or a workspace each

- Runs started by `remote.yml` take the project's lock on the runner (`<home>/locks/`): a second
  one waits, shown as waiting on the dashboard. `LOCK=0` turns it off.
- `ISOLATE=copy`: each run gets a copy of the snapshot of its own (`<home>/isolated/ssh-*`),
  with the `KEEP` folders linked rather than copied, deleted when it ends, so runs of one
  project overlap safely. Copies left by a killed session are swept after a day.

## A container executor

`"executor": { "container": { "image": "node@sha256:...", "network": "none" } }` on a project
runs each command in that container with Docker (or `tools.container`: `podman`): a read-only
root, the workspace mounted at `/work`, `/tmp` a tmpfs, no network unless `"bridge"`,
`--cpus` and `--memory` from the limits, no capabilities. No token or key of the agent goes in;
only the job's secrets, by name. The image must be pinned by digest; `shell` (default
`["sh", "-c"]`) runs the command. This gives hard limits on hosts without cgroups for processes
(Windows and macOS with Docker Desktop).

## Security

Timeouts and limits are numbers, parsed and bounded, never put in a command line; environment
variables are set, not interpolated. The executor's image, network and mounts come from
`agent.json`, never from a job; it is never privileged and mounts nothing but the workspace.
