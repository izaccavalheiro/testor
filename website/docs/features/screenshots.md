---
sidebar_position: 4
title: Screenshots
description: Images a run writes are kept with it, matched to their spec file and previewed on the dashboard.
---

# Screenshots

When a run ends, `run.ps1` keeps every image (`.png`, `.jpg`, `.jpeg`, `.webp`, `.gif`) the run
wrote under a folder named:

- `test-results/` (Playwright),
- `__screenshots__/` (Vitest browser mode, visual snapshots),
- `screenshots/`,
- `.vitest-attachments/`,

anywhere in the project (except inside `node_modules`, `target`, `.git`, `.venv` and
`playwright-report`). "Wrote" means changed since the run started, so old images in those folders are
not picked up again.

A command can also save images while it runs to **`$env:SCREENSHOT_DIR`**, a folder kept with the
run.

## On the dashboard

- The run page shows its screenshots, each attached to the **spec file** whose name it
  contains (Playwright names its result folders after the spec).
- The **Screenshots** page (`#/shots`) is a gallery of every run's, filterable by project.

## With Playwright

Nothing to configure for the common setup:

```ts title="playwright.config.ts"
export default defineConfig({
  reporter: "list",                       // spec lines for testor
  use: { screenshot: "only-on-failure", video: "retain-on-failure" },
});
```

Failure screenshots land in `test-results/` and are kept; videos are kept as
[artifacts](artifacts.md).

## Retention

Screenshot folders older than **7 days** are deleted, then the oldest until the total fits in
**1024 MB** (`screenshots.maxAgeDays`, `screenshots.maxTotalMB`). See
[retention](retention-and-maintenance.md).

## Caveats

- New files are found by modification time, with a 2-second margin for file systems that
  store times to the second (FAT: two). A tool that preserves old timestamps when it writes
  images will have them ignored; write them to `$env:SCREENSHOT_DIR` instead.
- Screenshots are copied when the run ends, not while it runs (`$env:SCREENSHOT_DIR` aside).
  An aborted run keeps none.
