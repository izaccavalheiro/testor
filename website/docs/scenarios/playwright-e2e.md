---
sidebar_position: 2
title: End-to-end tests with Playwright
description: Run Playwright on the runner and see failure screenshots, videos and the HTML report on the dashboard.
---

# End-to-end tests with Playwright

**The situation.** Your end-to-end suite takes 15 minutes and three browsers. Run locally, it
takes over your machine; in CI you only see a failure after pushing, and the screenshots are
buried in an artifact zip.

## Playwright configuration

```ts title="playwright.config.ts"
import { defineConfig } from "@playwright/test";

export default defineConfig({
  reporter: [["list"], ["html", { open: "never" }]], // list: spec lines for testor
  use: {
    screenshot: "only-on-failure",   // kept from test-results/, matched to the spec
    video: "retain-on-failure",      // kept as artifacts, playable with seeking
    trace: "retain-on-failure",      // in test-results/: name it to keep it
  },
});
```

## The task

```yaml title="Taskfile.yml"
tasks:
  e2e:
    desc: End-to-end tests on the runner
    cmds:
      - task: runner:sync
      - task: runner:npm-ci
      - task: runner:exec
        vars:
          KIND: e2e
          CMD: |
            npx playwright install --with-deps chromium firefox
            npx playwright test {{.CLI_ARGS}}
          ARTIFACTS: "playwright-report test-results/*/trace.zip"
```

`CMD` may span lines and hold any quotes: it reaches the runner base64-encoded.
`playwright install` is quick once the browsers are there.

## What you see

- **While it runs**: each spec line as Playwright prints it, failures counted live, the spec in
  progress.
- **When it ends**: failure screenshots under their spec file; videos with a player; the HTML
  report as one entry that opens in the browser (sandboxed, so its scripts cannot touch the
  dashboard); the traces as downloads for `npx playwright show-trace`.

## Keeping the disk in check

Playwright reports and videos are big. Tune the limits in `config.json`:

```json
{ "artifacts": { "maxRunMB": 512, "maxTotalMB": 8192, "maxAgeDays": 5 } }
```

Old browser builds pile up in Playwright's cache after upgrades; the
[Maintenance page](../features/retention-and-maintenance.md#maintenance-everything-else-testing-leaves)
lists them as `browsers:playwright`.

## Caveats

- Use the `list` reporter (alone or with others) for spec lines; `dot` and `line` give none.
- A headed browser on a Windows runner started as a scheduled service has no desktop; run
  headless (the default).
- On Linux, `--with-deps` installs system packages with `sudo`: run it once interactively, or
  give the runner's user the rights it needs.
