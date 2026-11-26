# Result formats

testor reads test results and coverage from report files, whatever the framework, besides the
console output it already parses (Vitest, Playwright, pytest, `go test`, `cargo test`). A run
hands them over like a mutation report: `run.ps1 -Reports`, `REPORTS` in `remote.yml`,
`reports` in an agent's command ([mutation testing](mutation.md#hand-the-report-over)).

## Test results

| Format | Written by | Spec file |
| ------ | ---------- | --------- |
| JUnit XML | Jest (jest-junit), Mocha, Maven Surefire, Gradle, pytest `--junitxml`, gotestsum, cargo-nextest, PHPUnit, dotnet's JUnit logger | a case's `file`, its suite's `file`, its `classname`, or its suite's name |
| TRX | `dotnet test --logger trx` | the test class |
| CTRF (JSON) | Playwright's, Jest's, Cypress's CTRF reporters and others | `filePath`, else the suite |
| TAP 13 and 14 | node:test, tap, bats | each top-level test point; its subtests are its cases |

- A run with any test report takes its **spec table** from its reports (several are merged),
  not from its log: `specsFrom: "reports"` in the record. When the log also printed spec
  results and they differ, the record keeps them as `logSummary`.
- Flaky detection (`/flaky`), release gates and the history work the same on these rows: a
  Jest suite with jest-junit shows per spec file, with durations and failure messages.
- CTRF's `retries` are kept (hotspots, below) and its `flaky` flag shown; testor's own flaky
  detection decides.

```yaml
# Jest with jest-junit (JEST_JUNIT_OUTPUT_FILE=reports/junit.xml)
test:
  cmds:
    - task: runner:sync
    - task: runner:exec
      vars: { KIND: test, CMD: "npx jest --ci --reporters=default --reporters=jest-junit", REPORTS: reports/junit.xml }
```

## Coverage

| Format | Written by |
| ------ | ---------- |
| LCOV (`lcov.info`) | c8, nyc, Jest, Vitest, cargo-llvm-cov, gcov |
| Cobertura XML | coverage.py, coverlet, JaCoCo converters, gocover-cobertura |
| Istanbul `coverage-summary.json` | the `json-summary` reporter |

The record gets `coverage` (lines, branches and functions %, and which format); the run's page
lists the least covered files. A gate takes `minCoverage` (lines %), and
`/api/v1/projects/<p>/badge.svg?metric=coverage` is a coverage badge. Per-line data stays in
the report file.

## Out: JUnit and CTRF

`GET /api/v1/runs/<id>/report.junit.xml` and `GET /api/v1/runs/<id>/report.ctrf.json` give a
run's spec table to another tool (a CI system's test tab): one suite per spec file, with its
cases when a report gave them.

## Hotspots

`GET /api/v1/projects/<p>/hotspots?kind=&limit=200` (and MCP's `find_hotspots`): over the last
runs, the spec files that fail most (and how often), take longest (mean and longest), and were
retried most. They come from what each record keeps, so they cost no log reading.

## Security

Every report is untrusted. XML with a `<!DOCTYPE` or `<!ENTITY` is refused before parsing (no
external entities, no entity expansion); parsing stops past 64 levels or 500,000 elements;
files are 50 MB at most and read in a task with a time limit; strings are capped and shown as
text. Exports are filtered by project access like the run.
