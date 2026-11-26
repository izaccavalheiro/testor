# Sharding

A big run (a mutation run, a long end-to-end suite) can be split across agents and merged back
into one signed result.

```sh
curl -u ada -H 'content-type: application/json' https://testor.example.com/api/v1/jobs \
  -d '{"project": "shop", "kind": "mutation", "snapshot": "sha256:...", "shards": 8}'
```

`"shards": N` (2 to 64) makes a **batch**: a parent job and N shard jobs, each with
`shard: {index, total}` and the parent's ref or snapshot, labels and timeout. The shards lease at
once, on different agents or in free [slots](handoff.md#slots-and-workspaces) of one, each in a
workspace of its own; one that loses its agent is tried again alone, up to
`execution.maxAttempts`. `GET /api/v1/jobs/<parent>` shows the shards (`shardJobs`), and
cancelling the parent cancels them all.

## What a shard's command gets

Data, never command text:

- `TESTOR_SHARD_INDEX` (from 1) and `TESTOR_SHARD_TOTAL`;
- with a weighted plan, its files: appended to an `argv` command (or as its `select` says), or
  in the file `TESTOR_SELECT_FILES` names (also `TESTOR_SHARD_FILES`) for a string command.

| Tool | agent.json |
| ---- | ---------- |
| Vitest, Playwright | `"command": "npx vitest run --shard=$env:TESTOR_SHARD_INDEX/$env:TESTOR_SHARD_TOTAL"` |
| Jest | `"command": "npx jest --shard=$env:TESTOR_SHARD_INDEX/$env:TESTOR_SHARD_TOTAL"` |
| cargo-nextest | `"command": "cargo nextest run --partition count:$env:TESTOR_SHARD_INDEX/$env:TESTOR_SHARD_TOTAL"` |
| pytest (planned files) | `"argv": ["python", "-m", "pytest"]` |
| Stryker (planned files) | `"command": "npx stryker run --mutate (Get-Content $env:TESTOR_SHARD_FILES) -join ','"` |
| `go test` (packages) | `"argv": ["go", "test"]` with packages as the planned files |

## Weighted plans

A snapshot batch is planned by `Testor.Shards`: LPT bin-packing (the heaviest file first, onto
the lightest shard) over

- the snapshot's test files (`*.test.*`, `*.spec.*`, `*_test.*`, `test_*.py`), each weighing its
  p75 duration over the project's last 20 runs of the task, an unknown one the median;
- or, for a task whose last run had a mutation report, that report's files, each weighing its
  mutants.

The plan is kept with the batch (`plan`), so a retried shard runs the same files. A shard that
would get no file makes the batch fall back to index and total only.

## The merged run

When the last shard ends, testor merges their runs into one run of the batch
(`Testor.Reports.Merge`), signed like any other:

- the spec table: the shards' (a CTRF report of their results, `reports/<id>/shards.ctrf.json`);
- mutation: the files merged, the totals summed and the score computed again as one run would
  (a file two shards mutated is listed in `overlaps`);
- coverage: per file, the best shard's (testor keeps percentages, not lines), the totals averaged
  over the files and marked `approximate`;
- duration: the wall clock from the first start to the last end; `batch.cpuMs` the sum.

The parent passes when every shard passed; it fails when one failed or has no run, and is
cancelled when it was. The merged record lists each shard (`batch.shards`: job, run, status,
duration and the SHA-256 of its attestation), so its signature binds theirs. Shard runs carry
`shard` and are left out of release gates and commit statuses; the merged run is what they read.

The dashboard shows a batch's run with a bar per shard (its time and status, a link to its
run), and marks shards' runs in the list. A shard whose agent is stopped (SIGTERM: an eviction, a
spot notice) ends as preempted and runs again alone, without spending an attempt; one whose agent
vanishes comes back when its lease runs out. `scripts/shard-e2e.sh` stops an agent mid-shard.

Queued shards count in `testor_jobs`, so KEDA scales agents for them; heavy kinds go to their
[profile](heavy-jobs.md)'s agents by labels.
