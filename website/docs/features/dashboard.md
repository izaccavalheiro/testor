---
sidebar_position: 0.5
title: Dashboard tour
description: Every page of testor's dashboard and what it shows, in screenshots - runs, a run's specs, screenshots, artifacts, coverage and mutation score, the device, maintenance, the hub and approvals.
---

# Dashboard tour

testor's dashboard is one page at `http://<runner>:6767`: it opens on the list of runs and
updates live over server-sent events, with nothing to refresh. The header links its pages;
the dot at the right is green while the dashboard is connected, and it connects again by
itself after a restart.

These screenshots come from the dashboard's own end-to-end tests
(`scripts/dashboard-e2e.sh`), taken from a testor seeded with sample runs, so they show the
dashboard as it is in this version.

## Runs

![The runs page: tiles, the device strip, a run in progress and the latest result of each task](/img/dashboard/runs.png)

The front page answers "what is happening on this machine?":

- **Tiles**: what runs now, the last 24 hours (passed and failed, as a bar), the last run, and
  how much the screenshots, the artifacts and the disk hold against their limits
  ([retention](retention-and-maintenance.md)).
- **The device strip**: CPU, memory, GPU, disk and network, each with the last minutes as a
  sparkline. A click opens the [Device](#device) page.
- **Running now**: a card per run in progress with its command, the spec files done so far,
  the spec it is on, its own CPU and memory, its last lines, and **Cancel**, which ends its
  process tree after a confirmation ([run control](run-control.md)). Commands started outside
  `run.ps1` show as *unrecorded*.
- **Latest by task**: the last result of each project and task as a coloured chip; a click
  opens that run.

A toast in the corner says when a run starts and ends; a click opens it. The browser tab's
title counts the runs in progress.

### History

![The history: filters and one row per finished run](/img/dashboard/history.png)

Every finished run, newest first, filtered by project, type and status, or searched by
command, error or run id. A row shows the spec files that passed and failed, the line
coverage (☂) and the mutation score (🧬) when the run had them, its screenshots (📷) and
artifacts, and tags a [batch](jobs-and-agents.md) (*3 shards*) and each of its shards. A
click opens the run; going back returns to where the list was left.

## A run

![A run: its details, spec files with their screenshots](/img/dashboard/run.png)

A run's page has its details (the command, when it started and ended, its exit code, who
started it, its signed [attestation](signed-results.md), its folder), then its
[spec files](spec-results.md): failures first, each with its runner, tests, time and its
first screenshot. **Delete run** removes the run, its log, screenshots and artifacts after a
confirmation.

![A run's screenshots, matched to their spec files](/img/dashboard/run-screenshots.png)

[Screenshots](screenshots.md) are matched to the spec file their path names. A click opens
one full size; **Escape** or a click closes it.

![A screenshot opened full size](/img/dashboard/lightbox.png)

Below them come the run's [artifacts](artifacts.md) (reports open in a new tab, videos play
in the page) and its output, coloured: failures in red, passes in green. **full log** opens
all of it.

### Coverage, mutation testing and batches

![A failed unit run with its line, branch and function coverage per file](/img/dashboard/run-coverage.png)

A run that hands over a coverage report (lcov, Cobertura, Istanbul) shows its line, branch
and function coverage, and each file's.

![A mutation run: its score, each file and the surviving mutants](/img/dashboard/run-mutation.png)

A mutation-testing report (Stryker's schema) gives the score, killed, survived and uncovered
mutants per file, and each surviving mutant with its change.

![A batch: one bar per shard](/img/dashboard/run-batch.png)

A batch shows one bar per shard, as long as it took and coloured by its status, each linking
to its run ([sharding](../reference/sharding.md)).

### A run in progress

![A run in progress, its log streaming](/img/dashboard/run-live.png)

While a run is in progress its spec table grows as the runner prints results, its log
streams (it stays at the end unless you scroll up), and **Cancel run** ends it.

## Artifacts

![The artifacts page: the folder's use and every run's artifacts](/img/dashboard/artifacts.png)

Every run's [artifacts](artifacts.md), grouped by run and filtered by project, with how much
of its limit the folder uses. **Clean up now** applies the retention rules at once instead of
at the next cleanup.

## Screenshots

![The screenshots page: every image with its run and spec](/img/dashboard/screenshots.png)

Every screenshot kept, newest run first, each with its run, status and spec file; images
dropped in the folder by hand are shown too. Filter by project; a click opens one full size.

## Device

![The device page: system, CPU cores, memory, GPU, storage, network and processes](/img/dashboard/device.png)

The machine the tests run on ([device stats](device-stats.md)): the system, each CPU core,
memory, the GPU and its engines, volumes and disk activity, network adapters, and the busiest
processes, sorted by CPU or memory, each linked to the test run that started it.

## Maintenance

![The maintenance page after a scan](/img/dashboard/maintenance.png)

**Scan** measures what testing leaves behind on the machine: idle project snapshots, old
temporary files, tool caches, old Playwright browsers. Nothing is deleted until you choose
targets, press **Clean chosen** and confirm, and cleaning waits while a run is in progress
([retention and maintenance](retention-and-maintenance.md)).

## Hub

![The hub: other testors and their latest results](/img/dashboard/hub.png)

With a `hub.json`, the **Hub** page shows the latest result of each project and task on the
other testors, each linking back to its own dashboard; one that cannot be reached says why
([hub](hub.md)).

## Approvals

![What an AI agent asks, waiting for a person's approval](/img/dashboard/approvals.png)

When an AI agent asks, over [MCP](mcp-for-ai-agents.md), for a tool that needs a person's
approval (deleting or cancelling a run, say), the request waits at the top of every page with
the run it is about. **Approve** has testor do it as the agent; **Deny** drops it.

## On a phone, in the dark

![The runs page on a phone](/img/dashboard/phone-runs.png)

On a narrow screen the header wraps, the tiles stack two by two, and wide tables scroll
inside their panel. The dashboard follows the system's light or dark theme:

![The runs page in dark mode](/img/dashboard/dark.png)
