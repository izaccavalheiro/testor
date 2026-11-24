---
sidebar_position: 6
title: Scripts, CI and chat notifications
description: Wait for a run from a script, schedule a nightly run, and post a message when a run fails - with today's API.
---

# Scripts, CI and chat notifications

testor has no built-in scheduler or webhooks yet (both are on the
[roadmap](../project/roadmap.md)). Everything below uses what exists: Task, SSH, cron, and the
`/api/v1` event stream.

## A nightly full run

On any machine that has the Taskfile and SSH access (the workstation, or a small always-on box),
schedule the task with cron (or a systemd timer, or Windows Task Scheduler):

```cron
# every night at 02:30, the full suite on the runner
30 2 * * * cd ~/src/my-app && git pull -q && /usr/local/bin/task e2e >/dev/null 2>&1
```

The run is recorded under its type, so the **Latest by task** board shows last night's result
next to today's.

## Notify a chat when a run fails

A small script follows the global event stream and posts each failed run to a webhook
(Slack, Discord, Mattermost, Teams and Matrix bridges accept a JSON `text`):

```sh title="notify.sh"
#!/bin/sh
# needs curl and jq; TOKEN with scope read, WEBHOOK the chat's incoming webhook
curl -sN -H "authorization: Bearer $TOKEN" http://my-runner:6767/api/v1/events |
while IFS= read -r line; do
  case "$line" in
    "event: run") event=run ;;
    data:*) if [ "$event" = run ]; then
        echo "${line#data: }" | jq -c 'select(.status == "failed")' | while read -r run; do
          text=$(echo "$run" | jq -r '"testor: \(.project) \(.kind) failed (\(.id))"')
          curl -s -X POST -H 'content-type: application/json' \
            -d "$(jq -n --arg t "$text" '{text: $t}')" "$WEBHOOK" >/dev/null
        done
      fi; event= ;;
  esac
done
```

Run it as a service next to testor or anywhere that can reach it. A `run` event is sent each
time a run's record changes, so a run can appear more than once in the stream; remember the
ids you already posted if your chat must not see duplicates.

## Wait for a run from a script

```sh
id=$(curl -s -H "authorization: Bearer $TOKEN" \
  "http://my-runner:6767/api/v1/runs?project=my-app&kind=e2e&status=running&limit=1" | jq -r '.data[0].id')
until status=$(curl -s -H "authorization: Bearer $TOKEN" "http://my-runner:6767/api/v1/runs/$id" | jq -r .run.status) \
      && [ "$status" != running ]; do sleep 5; done
echo "$id: $status"
```

## Using testor from CI

A CI job can run a project's checks on your own hardware (a GPU, a Mac) through the same
Taskfile, if the CI machine can reach the runner over SSH (a self-hosted CI agent on your
network, or a Tailscale GitHub Action with an auth key). The job's log stays the CI's; the
run also appears on testor's dashboard with its screenshots and reports.

## Caveats

- Polling or following events needs a `read` token; keep it in the CI's secret store.
- The event stream is for the moment the script runs: events that happened while it was down
  are not replayed, but the snapshot at connection has the latest history if you need to catch
  up.
