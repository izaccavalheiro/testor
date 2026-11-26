---
sidebar_position: 3
title: Upgrade, roll back and back up
description: Move to a new testor version safely, go back if needed, and keep a copy of the data.
---

# Upgrade, roll back and back up

## Which version am I running?

```sh
curl -s http://my-runner:6767/api/v1/health    # {"ok":true,"app":"testor","version":"0.2.0",...}
```

## Upgrade

testor is installed from your clone of the repository. Read the
[changelog](../project/changelog.md) first: any **Breaking** section says what to change. Then:

```sh
cd ~/git/testor
git fetch --tags
git checkout v0.2.0              # a release tag; or `git pull` on main for the latest
task testor:deploy
```

`deploy` builds the new release next to the running one, then swaps it in: the dashboard is
down for a few seconds, and runs in progress keep running (they are recorded by `run.ps1`, not by
the service). The Taskfiles in your clone are the new ones too: projects that include
`remote.yml` use them on their next `task`.

Patch releases (`0.2.0` → `0.2.1`) are always safe to take; minor releases before 1.0 may
contain breaking changes, listed in the changelog ([versioning](../project/versioning.md)).

## Roll back

Check out the previous tag and deploy again:

```sh
git checkout v0.1.0 && task testor:deploy
```

Data written by a newer version stays readable by an older one within the same major version,
unless the changelog says otherwise: run records only gain fields.

## Back up

Everything worth keeping is in the testor home (`~/test-run/.testor`):

| Keep | Skip |
| ---- | ---- |
| `runs/`, `logs/`, `screenshots/`, `artifacts/` | `app/`, `app.new/` (the release: rebuilt by deploy) |
| `config.json`, `auth.json` | `src/` (uploaded sources and build caches) |
| `jwt.key`, `token-keys.json`, `signing.key` (secrets: tokens, signed links and attestations depend on them) | `testor.log*` |

```sh
# on a Linux or macOS runner
tar -czf testor-backup.tgz -C ~/test-run/.testor runs logs screenshots artifacts config.json auth.json jwt.key token-keys.json signing.key
```

Restoring is copying them back and restarting the service. For runs kept off the machine,
encrypted and locked, set up [an archive to object storage](../reference/security.md#archive-to-object-storage):
every signed run is copied to an S3-compatible bucket as it ends. Project snapshots
(`~/test-run/<project>`) are not worth backing up: the next `sync` recreates them.

## Move to another machine

Prepare the new runner, `task testor:deploy` with the new `RUNNER`, stop its service, copy the
backup into its testor home, start it again. Tokens and signed links stay valid if `jwt.key` and
`token-keys.json` came along.

## Uninstall

```sh
task testor:uninstall            # the service (and on Windows the firewall rule); data stays
```

Delete `~/test-run` on the runner to remove everything.
