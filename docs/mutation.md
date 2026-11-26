# Mutation testing

testor reads the results of mutation testing tools that write the open
[mutation-testing-report schema](https://github.com/stryker-mutator/mutation-testing-elements/tree/master/packages/report-schema)
(StrykerJS, Stryker.NET, Stryker4s and others): a run's score, its killed and surviving
mutants, and its HTML report are shown with the run, signed with it, and can gate a release.

## Hand the report over

A run names its report files with `run.ps1 -Reports` (or `$env:TESTOR_REPORTS`, separated by
`;`). They are copied to `<home>/reports/<run>/` when the run ends, if the run wrote them (a
stale report from an earlier run is not kept), 20 at most, 50 MB each.

```yaml
# Taskfile.yml of a project, with taskfiles/remote.yml included as `runner`
mutation:
  cmds:
    - task: runner:sync
      vars: { PRESERVE: "reports/stryker-incremental.json .stryker-tmp" }
    - task: runner:exec
      vars:
        KIND: mutation
        CMD: npx stryker run --incremental
        REPORTS: reports/mutation/mutation.json
        ARTIFACTS: reports/mutation
```

An agent's `agent.json` says the same with a command object (a plain string still works):

```json
"commands": {
  "mutation": {
    "command": "npx stryker run --incremental",
    "reports": ["reports/mutation/mutation.json"],
    "artifacts": ["reports/mutation"],
    "preserve": ["reports/stryker-incremental.json", ".stryker-tmp"]
  }
}
```

Without a report, testor reads the summary Stryker prints in the log ("Final mutation score
of 87.50", Stryker.NET's "The final mutation score is 87.50 %", the "All files" row of the
clear-text table): the score and totals, no mutants.

## What testor shows

- The **record** gets a summary: `mutation.score` ((killed + timeout) / (killed + timeout +
  survived + no coverage)), `coveredScore` (leaving out mutants no test reached), the count of
  each status, and where it came from (`report` or `log`). It is part of what testor signs
  (`Testor.Attestation`), and the report files are among the attestation's subjects.
- The **run's page** shows the score, a table per file, the surviving mutants (file, line,
  mutator, original and replacement, as text) and a link to the HTML report when the run kept
  it as an artifact (`reports/mutation/mutation.html`, served sandboxed).
- While the run runs, StrykerJS's progress line (`Mutation testing 42% ... 12/30 tested (3
  survived, 1 timed out)`) and Stryker.NET's (`Testing mutant 12 / 30 | K 8 | S 3 | T 1`) give a
  live bar (`mutationProgress`).
- `GET /api/runs/<id>` and `GET /api/v1/runs/<id>` carry the details (`mutation.files`,
  `mutation.survivors`, at most 2,000); MCP's `get_run` has the summary, fenced as untrusted.
- A badge: `GET /api/v1/projects/<p>/badge.svg?metric=mutation`.
- The tests that cover each source file (schema 2's `coveredBy` and `testFiles`) are kept in
  `<home>/reports/<run>.tests.json`, for impact analysis.

## Gate on it

```json
"gates": {
  "web-release": { "project": "web", "kinds": ["test", "mutation"],
                   "minMutationScore": 75, "maxSurvivors": 20 }
}
```

`GET /api/v1/gates/web-release?commit=<sha>` then also needs the mutation run's signed summary
to reach 75% and leave at most 20 mutants alive.

## Keep incremental caches between runs

Stryker's incremental mode reuses the results of mutants whose code and tests did not change;
its file must survive the next sync.

| Tool | Cache | |
| ---- | ----- | - |
| StrykerJS | `reports/stryker-incremental.json` (`--incremental`), `.stryker-tmp` | `PRESERVE: "reports/stryker-incremental.json .stryker-tmp"` |
| Stryker.NET | `StrykerOutput` (`--since`, `--with-baseline`) | `PRESERVE: "StrykerOutput"` |

- `remote.yml`'s sync keeps `PRESERVE` paths (relative to the project) and `KEEP` entries,
  which may now be paths too (`reports/stryker-incremental.json`), not only names.
- An agent keeps a command's `preserve` paths in `<home>/cache/<project>/` for isolated
  workspaces: copied in before the run, back after it.
- **A clean run**: `CLEAN=1` for `remote.yml`, or a job with `"clean": true`
  (`POST /api/v1/jobs`), drops the preserved paths first. It is data: the agent decides what
  it deletes, from its own `agent.json`.

## Security

A report is untrusted data: size- and count-capped, parsed in a task with a time limit, its
strings capped and shown as text, and no path inside it is ever opened. Reports reach testor
only from the run's own folder or its job's token, like its other files.
