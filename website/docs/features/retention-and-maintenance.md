---
sidebar_position: 8
title: Retention and disk maintenance
description: How old runs, screenshots and artifacts are cleaned up, and how to reclaim the disk space testing leaves behind.
---

# Retention and disk maintenance

## Retention: testor's own data

The **janitor** runs at start, every 30 minutes and on demand (`POST /api/v1/cleanup`, or **Clean up
now** on the dashboard). In order, it:

1. keeps the newest `runs.maxRuns` runs (500) and deletes runs older than `runs.maxAgeDays` (30),
   with their logs;
2. deletes screenshot folders older than `screenshots.maxAgeDays` (7), then the oldest until the
   total fits `screenshots.maxTotalMB` (1024);
3. does the same for artifact folders (`artifacts.maxAgeDays` 7, `artifacts.maxTotalMB` 2048).

A running run is never touched, and an empty screenshot or artifact folder is left alone for an
hour (its run may not have been seen yet). Change any value in `~/test-run/.testor/config.json`;
see [configuration](../operations/configuration.md#configjson).

## Maintenance: everything else testing leaves

Testing fills the disk outside testor's folder too: each project snapshot keeps its
`node_modules` or `target`, and tools keep download and build caches. The **Maintenance** page
(`#/maintenance`) measures a fixed list of targets:

| Target | What | Suggested when |
| ------ | ---- | -------------- |
| `snapshot:<project>` | a project's snapshot folder | no run of it started for `snapshotIdleDays` (14) |
| `temp` | entries of the user's temporary folder older than `tempMinAgeDays` (7) | always listed |
| `cache:npm`, `cache:pip`, `cache:go`, `cache:cargo` | the tools' caches (their environment variables honoured) | listed with their size |
| `browsers:playwright` | Playwright browser builds a newer build of the same browser replaces | when one exists |

Deleting is **off by default**. Turn it on in `config.json`:

```json
{ "maintenance": { "enabled": true } }
```

Then pick targets, confirm, and testor deletes them in the background, reports what it freed
and what it could not delete, and measures again.

## Safety rules

- Cleaning takes the **scan's id and target ids**, never paths, so a request cannot name an
  arbitrary folder.
- It is refused while a recorded run or a PowerShell session in the workspace is running, and if
  the scan is not the latest.
- A snapshot's `.lockhash` is deleted first, so a half-deleted snapshot reinstalls its
  dependencies on the next run instead of using a broken `node_modules`.
- Sizes are measured without following symbolic links.
- It needs the `maintain` scope (role `admin`) when authentication is on.
- testor runs as the runner's user without elevation: system folders, browsers' own caches and
  installed programs are out of its reach by design.
