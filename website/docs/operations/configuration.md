---
sidebar_position: 1
title: Configuration reference
description: Every setting of testor in one place - environment variables, config.json, auth.json, Taskfile variables and what run.ps1 gives a command.
---

# Configuration reference

Every setting below is part of testor's [public surface](../project/versioning.md#what-the-version-covers):
it keeps its meaning within a major version.

## Environment variables (the orchestrator)

The installer sets the first three for the service; the rest are optional.

| Variable | Default | Meaning |
| -------- | ------- | ------- |
| `TESTOR_WORKSPACES` | `~/test-run` | the folder that holds one snapshot folder per project |
| `TESTOR_HOME` | `<workspaces>/.testor` | testor's data: runs, logs, screenshots, artifacts, `config.json`, `auth.json`, the release |
| `TESTOR_PORT` | `6767` | the HTTP port |
| `TESTOR_BIND` | `0.0.0.0` | the address to listen on; `127.0.0.1` behind a proxy ([how to set it](reverse-proxy-tls.md#listen-on-localhost-only)) |
| `TESTOR_JWT_SECRET` | `<home>/jwt.key` | the token and signed-link key, 32 bytes or more, instead of the key file |
| `TESTOR_ALLOWED_HOSTS` | (none) | host names answered besides IP addresses, `localhost` and the machine's name: `testor.example.com`, `.example.com` (subdomains), `*` (no check). See [network exposure](../reference/security.md#network-exposure) |
| `TESTOR_TRUSTED_PROXIES` | (none) | addresses or CIDR ranges of reverse proxies whose `X-Forwarded-For` names the client |
| `TESTOR_ANONYMOUS` | `private` | who is answered while authentication is off: `private` (loopback, private, link-local, Tailscale), `loopback`, or `any` |
| `TESTOR_SECRETS_DIR` | `<home>` | where `auth.json`, `jwt.key`, `signing.key` and `webhooks.json` live |
| `TESTOR_TLS_CERT`, `TESTOR_TLS_KEY` | (none) | PEM certificate (with its chain) and key: with both, HTTPS only |
| `TESTOR_LOG` | `file` | `file` (`<home>/testor.log`) or `stdout` (containers) |

`task testor:deploy` sets `TESTOR_BIND`, `TESTOR_ALLOWED_HOSTS`, `TESTOR_TRUSTED_PROXIES`,
`TESTOR_ANONYMOUS` and `TESTOR_SECRETS_DIR` for the service from `BIND`, `ALLOWED_HOSTS`,
`TRUSTED_PROXIES`, `ANONYMOUS` and `SECRETS_DIR`; the runner keeps them in
`<home>/service.json` until a deploy changes them (`BIND=""` removes one).

## `config.json`

In the testor home (`~/test-run/.testor/config.json`). Any key may be left out; the file is read
again at each cleanup, and by `run.ps1` at each run.

```json
{
  "runs": { "maxRuns": 500, "maxAgeDays": 30 },
  "screenshots": { "maxAgeDays": 7, "maxTotalMB": 1024 },
  "artifacts": { "maxAgeDays": 7, "maxTotalMB": 2048, "maxRunMB": 256 },
  "cleanupIntervalMinutes": 30,
  "maintenance": { "enabled": false, "tempMinAgeDays": 7, "snapshotIdleDays": 14 }
}
```

| Key | Default | Meaning |
| --- | ------- | ------- |
| `runs.maxRuns` | 500 | runs kept, newest first |
| `runs.maxAgeDays` | 30 | runs older than this are deleted with their logs |
| `screenshots.maxAgeDays` / `maxTotalMB` | 7 / 1024 | screenshot folders by age, then oldest first until they fit |
| `artifacts.maxAgeDays` / `maxTotalMB` | 7 / 2048 | the same for artifact folders |
| `artifacts.maxRunMB` | 256 | the most one run may keep; the rest is listed as skipped |
| `cleanupIntervalMinutes` | 30 | how often the janitor runs |
| `maintenance.enabled` | `false` | whether the Maintenance page may delete targets (it always measures) |
| `maintenance.tempMinAgeDays` | 7 | temporary files younger than this are left alone |
| `maintenance.snapshotIdleDays` | 14 | a project snapshot is suggested for deletion after this long without a run |

## `auth.json`

Written by `task testor:user` and `Testor.Auth.CLI` (do not edit it by hand unless you must; it is
read again within a second):

| Key | Meaning |
| --- | ------- |
| `users.<name>.password` | a `$pbkdf2-sha256$<iterations>$<salt>$<hash>` string |
| `users.<name>.role` | `viewer`, `operator` or `admin` |
| `users.<name>.tokensValidAfter` | Unix time; tokens issued before it are refused (set by `revoke`) |
| `tokens.defaultTtlMinutes` | a token's lifetime when none is asked for (60) |
| `tokens.maxTtlDays` | the longest lifetime allowed (30) |
| `enabled` | `false` turns authentication off without removing users |

## `testor.yml` (managing testor)

| Variable | Default | Meaning |
| -------- | ------- | ------- |
| `RUNNER` | required | the SSH host of the runner |
| `PORT` | `6767` | the port the service listens on |
| `WORKSPACES` | `test-run` | the workspace folder, under the runner user's home |
| `HOME_DIR` | `<WORKSPACES>/.testor` | the testor home |
| `ALLOW_FROM` | `100.64.0.0/10,LocalSubnet` | Windows only: the firewall rule's remote addresses, comma-separated |

| Task | Variables |
| ---- | --------- |
| `testor:user` | `USER` (required), `ROLE` (`viewer`), password from the `TESTOR_PASSWORD` environment variable |
| `testor:token` | `USER` (required), `DAYS` (`30`), `SCOPE` (the user's, or a subset: `read`, `"read operate"`) |
| `testor:test` | arguments after `--` go to `mix test` |

## `remote.yml` (running a project)

| Variable | Default | Meaning |
| -------- | ------- | ------- |
| `RUNNER` | required | the SSH host |
| `PROJECT` | the git root's folder name | the snapshot folder and the run's project |
| `ROOT` | the git root of the folder `task` ran in | what `sync` uploads |
| `WORKSPACES`, `HOME_DIR` | as above | must match the runner's |
| `KEEP` | `node_modules .lockhash target .venv` | what a new snapshot does not delete |

`runner:exec` takes `CMD` (PowerShell 7, any number of lines), `KIND` (records the run under
this type; without it the command runs unrecorded) and `ARTIFACTS` (with `KIND`: files and
folders to keep).

## What a recorded command sees

| Variable | Meaning |
| -------- | ------- |
| `TESTOR_RUN_ID` | the run's id |
| `SCREENSHOT_DIR` | a folder kept with the run as screenshots |
| `TESTOR_ARTIFACT_DIR` | a folder kept with the run as artifacts |

## Files on the runner

| Path | What |
| ---- | ---- |
| `<home>/runs/`, `logs/`, `screenshots/`, `artifacts/` | the data |
| `<home>/run.ps1` | the wrapper the Taskfiles call |
| `<home>/app/` | the installed release |
| `<home>/src/` | the uploaded sources, with `deps` and `_build` kept between deploys |
| `<home>/testor.log` | the orchestrator's log (rotated at 1 MB, two files) |
| `<home>/jwt.key` | the signing key, readable by its owner only |
