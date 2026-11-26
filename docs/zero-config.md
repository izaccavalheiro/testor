# Zero-config, sizing and spot agents

## A proposal for agent.json

```sh
pwsh runner/agent.ps1 -Detect ~/src/shop      # or: pwsh runner/detect.ps1 ~/src/shop
```

It prints a proposed `agent.json` entry for the project (on stdout, as JSON) and what it found (on
stderr). It **only reads files**: it runs nothing from the project (no `npm`, no scripts),
writes nothing and applies nothing. Commands are the owner's decision: review the proposal and
copy what you want into `agent.json`.

| Found | Proposed |
| ----- | -------- |
| `package.json` and its lockfile (npm, pnpm, yarn, bun) | `install` (the lockfile's install), `lint` and `typecheck` from its scripts |
| Vitest (`vitest` or `vitest.config.*`) | `test`: `vitest run` with JUnit output as a report, `select` (files, `-t`), `affected` (`vitest related --run`); `watch` (native) |
| Jest | `test`: `jest --ci`, `select`, `affected` (`--findRelatedTests`); `watch` |
| Playwright (`@playwright/test`, `playwright.config.*`) | `e2e`: `playwright test`, `select` (files, `-g`), its report and results as artifacts; the `browser` label |
| Stryker (`@stryker-mutator/core`, `stryker.conf.*`) | `mutation`: `stryker run --incremental`, its report, the incremental file as `state`, a memory guard; the `mutation` label |
| Python (`pyproject.toml`, `setup.cfg`, `requirements*.txt`, `pytest.ini`, `tox.ini`) | `test`: pytest with JUnit output, `select` (files, `-k`); `affected` with pytest-testmon; `coverage` with pytest-cov; `watch` (ptw, else restart) |
| Go (`go.mod`) | `test` (`go test ./...`, `-run`), `race` |
| Rust (`Cargo.toml`) | `test`: cargo-nextest when `.config/nextest.toml` exists, else `cargo test`; `target` preserved |
| .NET (`*.sln`, `*.slnx`, `*.csproj`) | `test`: `dotnet test` with a TRX report, `--filter`; `mutation` with `stryker-config.json` |

Every entry gets `"snapshots": true`, `"limits": "auto"`, labels and a timeout per task. A folder
without project files of its own is looked into one level down: each subfolder with one becomes a
project with its `workspace`.

## Sizing

testor keeps, per project and task, the p50 and p95 duration and the p95 peak memory of the last
30 runs (`memory.peakMB`: run.ps1 records the peak of the command's process tree, or the
container's from `memory.peak`).

- `"shards": "auto"` with `"target": "10m"` makes a batch of one shard per target's worth of the
  p95 duration: at least 2, at most 64, and no more than the slots of the agents seen in the last
  minute. A task that fits the target alone runs as one job.
- With profiles in config.json, a job gets the smallest profile whose memory holds the p95 peak
  with a fifth to spare as `suggestedProfile`; `"profile": "auto"` adds that profile's labels.

  ```json
  { "execution": { "profiles": {
      "unit-light": { "memoryMB": 1024, "labels": ["unit"] },
      "mutation-heavy": { "memoryMB": 8192, "labels": ["mutation"] } } } }
  ```

`get_capacity` (MCP) shows the agents seen per label, their free slots, the queue, and the wait
estimated from recent leases.

## Spot agents and preemption

On SIGTERM (a Kubernetes eviction, a spot instance's notice), the agent ends its command's tree,
saves the task's declared [state](snapshots.md#incremental-state) (Stryker's incremental file),
sends what the run wrote, and finishes the job as `preempted`. testor queues it again without
spending an attempt (`preemptions` counts them, at most `execution.maxPreemptions`, 5), and the
retry resumes from the saved state. Only the agent holding the lease can finish a job, so a
preemption cannot forge a result. The agent then stops taking jobs and exits.

The Helm chart gives agents `terminationGracePeriodSeconds` (`agents.terminationGracePeriodSeconds`,
60) and, with `agents.podDisruptionBudget.enabled`, a PodDisruptionBudget per profile
(`maxUnavailable: 1`). Spot capacity is the cluster's; for example a profile on spot nodes:

```yaml
agents:
  profiles:
    - name: mutation-spot
      labels: [linux, mutation]
      mode: job                       # a Job per run: a preempted pod ends, KEDA starts another
      tolerations:                    # Karpenter / EKS
        - { key: karpenter.sh/capacity-type, value: spot, effect: NoSchedule }
      nodeSelector: { karpenter.sh/capacity-type: spot }
      # GKE Spot: nodeSelector: { cloud.google.com/gke-spot: "true" }
      # AKS Spot: tolerations: [{ key: kubernetes.azure.com/scalesetpriority, value: spot, effect: NoSchedule }]
```
