---
sidebar_position: 5
title: Artifacts and reports
description: Keep coverage, HTML reports, JUnit XML, videos and any file a run writes, and open them from the dashboard.
---

# Artifacts and reports

Name what to keep with `ARTIFACTS` in a task: space-separated files and folders relative to the
project, wildcards allowed.

```yaml title="Taskfile.yml"
tasks:
  coverage:
    cmds:
      - task: runner:sync
      - task: runner:exec
        vars:
          KIND: coverage
          CMD: "npm run test:coverage"
          ARTIFACTS: "coverage playwright-report reports/*.md junit.xml"
```

When the run ends, `run.ps1` copies each one that the run wrote into the run's artifact
folder, at its path in the project. A folder counts when any file in it is new (reports copy
their assets with their original dates). Also kept, without naming them:

- **videos** (`.webm`, `.mp4`) under the [screenshot folders](screenshots.md), such as
  Playwright's `video: "retain-on-failure"`;
- anything the command writes to **`$env:TESTOR_ARTIFACT_DIR`** while it runs.

## On the dashboard

The run page lists its artifacts:

| Kind | Shown as |
| ---- | -------- |
| `report` | a folder with an `index.html` (coverage, Playwright's and Vitest's HTML reports): one entry that opens the report |
| `video` | a player that can seek (served by byte ranges) |
| `image`, `html`, `text` | opened in the browser |
| `file` | a download (JUnit XML, archives, ...) |

The **Artifacts** page (`#/artifacts`) lists every run's, filterable by project.

## Safety

Reports are web pages with scripts, written by your tests' tools. testor serves them with
`Content-Security-Policy: sandbox`: they run with an opaque origin, so they cannot call the
dashboard's API, read its storage, or act with your credentials. They can still load their own
data files. With authentication on, links to them are [signed](authentication.md#signed-links).

## Limits

| Setting (`config.json`) | Default | Effect |
| ----------------------- | ------- | ------ |
| `artifacts.maxRunMB` | 256 | per run: artifacts are copied in the order named until this is reached; the rest are listed in the record's `artifactsSkipped` and in a warning |
| `artifacts.maxAgeDays` | 7 | older artifact folders are deleted |
| `artifacts.maxTotalMB` | 2048 | then the oldest go until all fit |

## Caveats

- Only artifacts the run **wrote** are kept: a `coverage/` folder left from an earlier run is
  ignored. If a tool skips writing when nothing changed, the run keeps nothing.
- Name generated outputs, not sources: `ARTIFACTS: "src"` copies nothing unless the run wrote
  into `src/`.
- Paths are relative to the project root; quoting is not needed, and not supported, inside
  `ARTIFACTS`.
- Wildcards are PowerShell's (`*`, `?`, `[a-z]`), matched one folder level at a time: there is
  no recursive `**`. `test-results/*/trace.zip` matches `test-results/<test>/trace.zip`; to keep
  everything under a folder, name the folder.
