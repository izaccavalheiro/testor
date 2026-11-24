---
sidebar_position: 9
title: HTTP API and events
description: Use testor from scripts, CI and bots with the versioned /api/v1, its OpenAPI 3.1 document and server-sent events.
---

# HTTP API and events

`/api/v1` is the stable API for programs. Its paths and answers are covered by
[semantic versioning](../project/versioning.md#what-the-version-covers): a breaking change
would come as `/api/v2`, next to it. `GET /api/v1/openapi.json` describes it as OpenAPI 3.1, so
you can generate a client or import it into Postman, Bruno or Insomnia.

## Common tasks

```sh
RUNNER=http://my-runner:6767
AUTH=(-H "authorization: Bearer $TOKEN")   # omit while authentication is off

# Is it up, and which version?
curl -s $RUNNER/api/v1/health

# What is running, and the last failures
curl -s "${AUTH[@]}" "$RUNNER/api/v1/runs?status=running" | jq '.data[] | {id, project, kind}'
curl -s "${AUTH[@]}" "$RUNNER/api/v1/runs?status=failed&limit=5" | jq '.data[].id'

# Why did it fail? Only the matching lines, with 3 lines of context
curl -s "${AUTH[@]}" "$RUNNER/api/v1/runs/$ID/log?grep=FAIL&context=3"

# Follow a run's events until it ends
curl -sN "${AUTH[@]}" "$RUNNER/api/v1/runs/$ID/events"

# Cancel it (scope operate)
curl -s "${AUTH[@]}" -X POST "$RUNNER/api/v1/runs/$ID/cancel"
```

## Getting a token

```sh
TOKEN=$(curl -s -u ci -X POST $RUNNER/api/v1/auth/token \
  -d grant_type=client_credentials -d scope=read -d expires_in=3600 | jq -r .access_token)
```

or, from the workstation, `task testor:token USER=ci DAYS=30 SCOPE=read`. See
[authentication](authentication.md).

## Conventions

- Collections answer `{"data": [...]}`, with `"next"` where they page.
- Errors answer `{"error": {"code", "message"}}` with a meaningful status: `401` without
  credentials, `403` without the scope, `404`, `409` (cancelling a run that is not running,
  deleting one that is), `429` after repeated failed logins.
- Every response has an `X-Request-Id`; API answers are `Cache-Control: no-store`.
- Clients must ignore fields they do not know: new fields are added in minor releases.

## Events

`GET /api/v1/events` (everything) and `GET /api/v1/runs/<id>/events` (one run) are
server-sent event streams: a `snapshot` first, then changes, with a comment every 15 seconds to
keep proxies from closing them. The [API reference](../reference/api.md#server-sent-events)
lists every event.

## The dashboard's routes

`/api/state`, `/api/runs/...` and `/events` serve the dashboard page and may change with it;
programs should use `/api/v1`, which carries the same data.

Full reference: [HTTP and SSE API](../reference/api.md).
