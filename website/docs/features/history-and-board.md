---
sidebar_position: 3
title: History and the board
description: Every run kept and searchable, and the latest result of each project and task at a glance.
---

# History and the board

## Latest by task

The **Latest by task** board has one tile per project and task type (`my-app · test`,
`my-app · lint`, ...) with its latest status and the statuses of the runs before it. It
answers "is everything green?" at a glance, and shows a flaky task as a mixed row.

## History

**History** lists every finished run, newest first: project, type, command, status, exit
code, duration, spec summary, screenshots. Filter by project, type and status, or search the
command, an error or an id. Delete a run (its log, screenshots and artifacts go with it).

Statuses:

| Status | Meaning |
| ------ | ------- |
| `running` | in progress |
| `passed` | the command exited with 0 |
| `failed` | the command exited with anything else, or threw |
| `cancelled` | someone cancelled it from the dashboard, the API or MCP |
| `aborted` | its SSH session died before it ended (see [run control](run-control.md)) |

A run that overlapped with another run of the same project carries a **warning**: the second
upload may have changed files under the first one.

## From programs

```sh
# the five latest failures of a project
curl -s "http://my-runner:6767/api/v1/runs?project=my-app&status=failed&limit=5" | jq '.data[] | {id, kind, startedAt}'

# the latest result of every project and task
curl -s http://my-runner:6767/api/v1/projects | jq '.data[] | {project, kind, status: .latest.status}'
```

`/api/v1/runs` pages with `limit` and `before` (the `next` value of the previous page).

## How long runs are kept

By default the newest **500** runs, none older than **30 days**: see
[retention](retention-and-maintenance.md).
