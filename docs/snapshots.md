# Snapshots and incremental state

A job can run a **snapshot** of a working tree, uncommitted changes included, instead of a git
ref, and a tool's **incremental state** (Stryker's incremental file, coverage baselines, test
timings) can follow a branch from one agent to the next. Both are kept by content, so what has
not changed never travels again.

## Snapshots

`runner/snapshot.ps1` sends the tree as git sees it (tracked and untracked files, minus what
`.gitignore` excludes) and can queue a job that runs it:

```sh
export TESTOR_TOKEN=...   # a user's token with the execute scope (task testor:token)
pwsh runner/snapshot.ps1 -Server https://testor.example.com -Project my-app
pwsh runner/snapshot.ps1 -Server https://testor.example.com -Project my-app -Kind test -Labels linux
```

It prints the snapshot's id (`sha256:<hex>`), then the job's with `-Kind` (`-Json` for one
object). From a project's Taskfile, `remote.yml` does the same with `SYNC=cas`:

```sh
task runner:sync SYNC=cas SERVER=https://testor.example.com KIND=test
```

How it moves:

1. The client hashes each file (SHA-256, cached in the git folder by size and write time, so an
   unchanged file is not read again) and sends the manifest, `{path, sha256, mode, size}` per
   file, to `POST /api/v1/projects/<p>/snapshots`.
2. testor answers with the contents it lacks (`missing`); the client uploads those to
   `PUT /api/v1/blobs/sha256:<hex>`, eight at a time. testor checks each against its hash.
3. The client sends the manifest again: with nothing missing, testor keeps it (`201`), and its
   id is the SHA-256 of the manifest itself. The same tree always has the same id.
4. A job names it: `POST /api/v1/jobs {"project", "kind", "snapshot": "sha256:..."}` (a ref or a
   snapshot, not both). The job carries the branch and commit the snapshot was taken on.
5. The agent reads the manifest, fetches the contents its cache (`<home>/cas`) lacks, and writes
   into the workspace only the files that changed since the snapshot it wrote last; the files
   that snapshot wrote and this one lacks are deleted, and what runs made (dependencies, build
   caches) stays. A one-line change moves one file, both ways.

Contents are copied into the workspace, not hard-linked: a run that writes into a file must not
change the cache. The agent's cache drops contents unused for two weeks when it starts.

An agent takes snapshot jobs only for projects that say so in `agent.json`:

```json
{ "projects": { "my-app": { "snapshots": true, "commands": { "test": "npm test" } } } }
```

Anyone with the execute scope can send a snapshot, so its code runs with that machine's
commands: opt in only where that is meant, as with any job. The workspace is the project's
`workspace`, else `<home>/workspaces/<project>`; `isolate: "copy"` works, `"worktree"` needs a
ref.

### Limits and retention

config.json's `snapshots` (defaults shown):

```json
{ "snapshots": { "maxFiles": 100000, "maxFileMB": 256, "maxMB": 4096, "keepDays": 14 } }
```

The janitor deletes manifests not sent again for `keepDays`, then contents no kept manifest
names that are a day old (an upload in progress keeps its own). Contents live at
`cas/sha256/<ab>/<hex>` and manifests at `snapshots/<project>/<hex>.json`, in the home or the
bucket ([storage](storage.md)); an agent fetches contents through testor, or by a presigned link
to the bucket.

### Paths

A path is relative and `/`-separated. testor refuses absolute paths, `.`, `..` and empty
segments, `.git`, backslashes, colons (drive letters, NTFS streams), control characters and
segments ending in a dot or a space; two paths that differ only by case, or a file that is also
another's folder, are refused too, as Windows and macOS could not hold them apart. The client
follows symbolic links inside the tree and refuses links out of it; a manifest holds files only.
The agent checks every path again, resolves it inside the workspace, and replaces any link a
run left on the way with a folder before it writes.

## SSH runs: only what changed

`remote.yml`'s `sync` sends only the files that changed (since 0.18). git hashes the tree into
a throwaway index (`git update-index --info-only`: no objects written), the runner compares it
with the manifest of its last sync (`<HOME_DIR>/manifests/<PROJECT>.json`) and with the files
as they are there (a file a run changed is sent again), and asks for the ones it lacks. Files
the tree no longer has are deleted; `KEEP` and `PRESERVE` stay as before. `SYNC=full` sends the
whole tree, as earlier versions did.

## Incremental state

A command (or a project) of `agent.json` lists files a tool keeps between runs:

```json
"mutation": { "command": "npx stryker run --incremental",
              "reports": ["reports/mutation/mutation.json"],
              "state": ["reports/stryker-incremental.json"] }
```

Before the run, the agent restores each from testor for the job's branch (the ref, the
snapshot's branch or the workspace's), or else the default branch's (`state.defaultBranch`):
a branch's first run starts from main's. After the run, whatever its result, it sends them back
for that branch. The file `reports/stryker-incremental.json` is kept under the name
`reports--stryker-incremental.json`.

| Endpoint | Who |
| -------- | --- |
| `GET /api/v1/projects/<p>/state/<name>?branch=b` | a user who can read the project |
| `GET /api/v1/agent/projects/<p>/state/<name>?branch=b` | an agent of the project |
| `PUT /api/v1/agent/projects/<p>/state/<name>?job=<id>&branch=b` | only the agent holding a job of that project |

The answer's `X-Testor-State-Branch` says which branch it came from. Without a branch, a write
goes to the default branch. config.json's `state`:

```json
{ "state": { "maxMB": 16, "keepDays": 30, "defaultBranch": "main" } }
```

The janitor deletes a branch's states not written for `keepDays`; the default branch's stay.
State is data the next run reads: it is scoped to its project and branch, and written only by an
agent running a job of that project, so another project's job cannot poison it.

## Warm agents

The queue prefers the agent that ran a project last, whose workspace, dependency caches and
snapshot cache are warm: while that agent is idle and asking for jobs, a new job of the project
waits for it up to `execution.warmSeconds` (2; `0` turns it off), then goes to any agent. It is
a hint, not a rule: a job that agent could not take (its labels) never waits. Agents that share
a user (the chart's pods) tell themselves apart by their host name.

In Kubernetes, the Helm chart's `agents.persistence` (or a profile's) makes the agents a
StatefulSet with a volume per pod for the agent's home, so its workspaces, caches and key survive
a restart, under the same pod name:

```sh
helm upgrade testor deploy/helm/testor --reuse-values \
  --set agents.persistence.enabled=true --set agents.persistence.size=50Gi
```

A profile with `mode: job` (a Kubernetes Job per run) cannot have one. The Terraform module
takes `agents.persistence`.
