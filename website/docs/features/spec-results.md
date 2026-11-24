---
sidebar_position: 2
title: Spec results without configuration
description: testor reads spec files and test counts from the normal output of Vitest, Playwright, pytest, go test and cargo test.
---

# Spec results without configuration

Projects keep their reporters. testor reads each line of output (ANSI codes removed) and
recognizes the per-file summaries the common test runners print by default:

| Runner | What it reads | Example |
| ------ | ------------- | ------- |
| **Vitest** | the default reporter's file lines, with or without a project label | ` ✓ tests/a.test.ts (12 tests) 34ms`, ` ❯ src/b.test.ts (3 tests \| 1 failed)` |
| **Playwright** | the `list` reporter | `  ok 3 [chromium] › e2e/auth.spec.ts:12:3 › signs in (1.2s)` |
| **pytest** | the default progress lines | `tests/test_api.py ..F.s   [ 40%]` |
| **go test** | package results | `ok   example.com/pkg 0.12s`, `FAIL example.com/pkg 0.3s` |
| **cargo test** | test binaries and their result line | `Running tests/x.rs (...)` then `test result: ok. 12 passed; ...` |

For each spec file it keeps the runner, tests, failures, skips, duration and status; the run
gets a summary (files and tests passed, failed and skipped) stored in its record.

## Using them

- The run page lists spec files, failed ones first, while the run is still going.
- **Running now** shows the spec file in progress and running counts.
- `GET /api/v1/runs/<id>` returns `specs`; MCP's `get_run` returns the failed ones separately,
  which is usually all an agent needs.

## Caveats

- **Parsing is best effort.** It reads text, so a custom reporter, a `--reporter=dot` or a
  silent mode gives no spec lines. The run itself, its status and its log are unaffected: the
  exit code decides passed or failed, never the parser.
- **Playwright** needs the `list` reporter (the default when not in CI). On Windows it prints
  `ok`/`x` instead of the check marks; both are read.
- A tool that changes its output format may stop being recognized; that is fixed in a patch
  release (see [what versions cover](../project/versioning.md#what-the-version-covers)).
- Want another runner (Jest, JUnit, RSpec, PHPUnit, .NET)? Contributions to `SpecParser` are
  welcome: one function and its tests.
