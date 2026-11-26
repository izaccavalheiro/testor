---
sidebar_position: 12.5
title: Hub
description: One board across several testors (teams, sites, runners), each project's latest result with a link back.
---

# Hub

When a team has several testors (a Windows farm, a Linux lab, another site), one of them can
show the board of all: each testor's projects with their latest result, how long ago it was
asked, and a link to the run on that testor. It appears as **Hub** on the dashboard.

List the others in `hub.json`, in the secrets folder of the testor that shows them:

```json
{ "intervalSeconds": 15,
  "testors": [
    { "name": "windows-farm", "url": "https://testor-win.example.com", "token": "eyJ...",
      "labels": ["windows", "gpu"] },
    { "name": "lab", "url": "http://lab-runner:6767", "tokenEnv": "LAB_TESTOR_TOKEN",
      "labels": ["linux"], "allowHttp": true } ] }
```

- **Tokens**: a read token of a user on each testor (`task testor:token USER=hub SCOPE=read`),
  best limited to the projects the hub shows; `tokenEnv` reads it from a variable instead.
- **Transport**: `https`, with the certificate checked; `http` only on loopback, or with
  `allowHttp` on a private network (Tailscale, a LAN), where the token travels in clear.
- **Freshness**: every testor is asked every `intervalSeconds` (15, at least 5), at most 10
  seconds each; one that does not answer shows why, and the others are not held up.
- **Who sees what**: the hub's own users see the projects their access allows, as everywhere
  else. `GET /api/v1/hub?label=windows` is the board as JSON, of the testors with a label.

Several testors sharing one home and database ([several testors](../reference/jobs.md#several-testors))
are one testor to the hub: list one of them.
