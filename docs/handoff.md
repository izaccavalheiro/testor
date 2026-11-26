# Handing test runs off

Any test command a person or an AI agent would run here can run on an agent instead: the
output, stderr and exit code are as if it ran here, a run can be scoped to some files or test
names or to what a change affects, two worktrees run side by side, and a result testor already
has for the same tree is answered at once. Watch mode works too, as a session.

```text
testor run ──snapshot (only what testor lacks)──▶ testor ──job──▶ agent ──run.ps1──▶ the run
    ▲                                                                     │
    └────────── stdout, stderr (line by line), exit code ◀────────────────┘
```

## `testor run`

`runner/testor.ps1` (PowerShell 7, any OS) is the client:

```sh
export TESTOR_URL=https://testor.example.com TESTOR_TOKEN=...    # a token with the execute scope
pwsh runner/testor.ps1 run                                       # the project's "test" task
pwsh runner/testor.ps1 run --files src/sum.test.ts --names "adds"
pwsh runner/testor.ps1 run --affected=then-all --fail-fast
pwsh runner/testor.ps1 run --kind lint --quiet --digest
```

It sends the working tree as a [snapshot](snapshots.md), queues a job of the project (the
repository's folder name, or `--project`) and task (`--kind`, `test` by default), follows its
runs and writes each line of their output to the stream it came from (run.ps1 records, beside
the log, whether each line was stdout or stderr), then exits with the job's exit code. Ctrl+C
cancels the job, which ends the remote process tree.

| Option | |
| ------ | - |
| `--project`, `--kind`, `--labels a,b` | which project, task and agents |
| `--files a b`, `--names x y` | scope the run (see [Selections](#selections)) |
| `--affected`, `--affected=then-all` | what the change affects; then the rest ([affected tests](#affected-tests)) |
| `--fail-fast` | with then-all: the rest is not run once the affected tests fail |
| `--no-cache` | run even if testor holds a result for this tree ([result cache](#result-cache)) |
| `--digest`, `--quiet` | the failures in a few lines after the output; only them with `--quiet` |
| `--workspace w` | the worktree's name (by default one made from its path): one job per project and workspace runs at a time |
| `-- <argv>` | a command of your own: [exec mode](#exec-mode) |

`TESTOR_TOKEN`, or a file in `TESTOR_TOKEN_FILE` (mode 0600 outside Windows), holds the token;
`.testor/client.json` in the repository may give `server`, `project`, `kind` and `labels`.

From a Taskfile, `remote.yml`'s `MODE=agent` sends the same tasks through `testor run` instead
of SSH (`SERVER`, `KIND`, files in `CLI_ARGS`, `NAMES`, `AFFECTED=1` or `then-all`, `LABELS`):

```sh
task test MODE=agent SERVER=https://testor.example.com -- src/sum.test.ts
```

### For AI agents

Paste into `CLAUDE.md` or `AGENTS.md`:

> Run tests with `pwsh runner/testor.ps1 run` (it runs this repository's test task on a testor
> agent, output and exit code as if local). Scope it with `--files <paths>` or
> `--names <test names>`; add `--affected=then-all` while iterating; add `--quiet --digest` to
> read only the failures. Never start watch mode yourself.

## Selections

A job's `select` (`files`, up to 2,000 paths in the workspace; `names`, up to 50 test names of
200 characters; `affected`) scopes it. The agent hands it to the command as its `agent.json`
says, as separate arguments, never through a shell:

```json
"test": { "argv": ["npx", "vitest", "run"],
          "select": { "files": "append", "names": ["-t", "{}"] } }
```

`"append"` adds each path as an argument; a list is a template whose `{}` each value fills. A
string `command` gets the selection as files instead: `TESTOR_SELECT_FILES` and
`TESTOR_SELECT_NAMES` name files of one value per line. A task without `select` refuses a
scoped job.

| Tool | `argv` | `files` | `names` |
| ---- | ------ | ------- | ------- |
| Vitest | `npx vitest run` | `"append"` | `["-t", "{}"]` |
| Jest | `npx jest` | `"append"` | `["-t", "{}"]` |
| pytest | `python -m pytest` | `"append"` (or `file::name` node ids) | `["-k", "{}"]` |
| `go test` | `go test` | `"append"` (packages: `./pkg/...`) | `["-run", "{}"]` |
| cargo-nextest | `cargo nextest run` | | `["-E", "test({})"]` |
| Playwright | `npx playwright test` | `"append"` | `["-g", "{}"]` |
| `dotnet test` | `dotnet test` | | `["--filter", "{}"]` |

A scoped run's record keeps its `select`, so it is never taken for a full one: release gates
and commit statuses leave scoped runs (and watch sessions' runs) out, unless a gate says
`"scoped": true`. Flaky detection still counts their specs.

## Affected tests

`"select": {"affected": true}` on a snapshot job makes testor count the files that changed
since the branch's previous snapshot (else the default branch's latest), with no git on the
agent; the job carries them as `select.changed`. The agent then runs:

- a full run when a change means one: lockfiles, `package.json`, `go.mod`, `Cargo.toml`,
  `pyproject.toml`, test and TypeScript configuration (`vitest.config.*`, `jest.config.*`,
  `playwright.config.*`, `tsconfig*.json`, `conftest.py`...), anything in the project's
  `"fullRunOn"` (globs), or when there is no base to compare with;
- else the tool's own selection when the task declares one, given the changed files:

  ```json
  "test": { "argv": ["npx", "vitest", "run"], "select": { "files": "append" },
            "affected": { "argv": ["npx", "vitest", "related", "--run"], "files": "append" } }
  ```

  (`jest --findRelatedTests`, `pytest --testmon`, `nx affected`, `turbo run --filter=...[base]`
  likewise);
- else the tests named after what changed (`foo.ts`: `foo.test.ts`, `foo.spec.ts`,
  `test_foo.py`, `foo_test.go`), and the changed tests themselves, through `select.files`.

`"affected": "then-all"` runs the affected tests first, as a run of their own, then the rest;
with `"failFast": true`, the rest is not run once they fail. `testor run` shows both.

## Result cache

A project whose tests are hermetic, as only its owner can say, sets `"cache": true` (passing
results) or `"cache": "all"` (failures too) in `agent.json`, with the variables its runs depend
on as `"inputs"`. The agent then reports, when a job of a snapshot ends, the hash of everything
it declares as an input (the command entry, those variables' values, its own script, the
platform, the executor's image). A later job of the same snapshot, project, task (or argv),
selection and labels is answered at once: its record says `"cached": {"job": ...}` and points to
the run that gave the result (and its attestation), which `testor run` replays.

`"cache": false` on a job (`--no-cache`) or `"clean": true` skips it; a watch session or exec job
never uses it. Entries go after `cache.days` (config.json, 7), and stop matching as soon as the
agent reports another hash for the task (its entry changed).

## Exec mode

`agent.json` maps tasks to commands, and that stays the rule. Exec mode is for a person
offloading from their own laptop to their own agent, the trust they already have over SSH,
with three opt-ins:

1. **The agent** lists who may send commands: `"exec": {"subjects": ["user:ada"], "executor":
   "container"}`. Off by default, and the Helm chart has no value for it.
2. **The scope** `exec`, which only the `exec-admin` role has: a job with `"argv"` needs it on
   its project. MCP never gets it.
3. **A claim testor signs** (RS256 with its job-token key, published at `/.well-known/jwks.json`;
   `jobTokens` in auth.json is needed) of who asked (`sub` `user:<name>`), the project and the
   argv's SHA-256 (the arguments joined by NUL). The agent checks the signature, the hash and
   the subject against its list, and refuses a job without one.

The argv runs with no shell, in a copy of the workspace of its own, in the project's container
executor unless the agent says `"executor": "none"`. Every exec job is in the audit trail
(`exec`, with its argv). A stolen token with `exec` means code execution on that agent: give
such tokens short lives.

## Watch sessions

```sh
pwsh runner/testor.ps1 watch            # the "watch" task of agent.json
```

`POST /api/v1/watches {project, snapshot, kind?, labels?, workspace?}` opens a session: a job
an agent keeps while its client sends the working tree's snapshots
(`POST /api/v1/watches/:id/changes {snapshot}`, after 150 ms of quiet from the client's file
watcher, which honours `.gitignore`). The agent writes each change into the session's
workspace (each file renamed into place) and, by the task's `"rerun"`:

- `"native"` (default): the tool's own watch mode (`vitest`, `jest --watch`, `ptw`,
  `cargo watch`) sees the files and reruns; its module graph stays warm;
- `"restart"`: the command starts again on each change, scoped to the tests the change affects
  when the task has a `select`.

```json
"watch": { "argv": ["npx", "vitest"], "rerun": "native" }
```

Each run is recorded with `"session"`, shown live and left out of gates. The client's
heartbeats keep the session open (`POST /api/v1/watches/:id/heartbeat`); it ends with
`DELETE /api/v1/watches/:id` (Ctrl+C), or after `execution.watchIdleMinutes` (15) without them.

## Slots and workspaces

An agent with `"slots": n` runs up to n jobs at once, each in a process of its own (capped by
its CPUs and by its memory, a slot per GB); an `"exclusive"` task waits until it is alone. One
job per project **and workspace** runs at a time: jobs of one project with different
`"workspace"` names (`testor run` gives each worktree its own) lease at once, and a snapshot job
with a workspace is written to `<workspace>@<name>`. The Helm chart's `agents.slots` (or a
profile's) sets it, and KEDA counts queued jobs per slot.

## Failure digest

`GET /api/v1/runs/:id/digest` (`?format=text` for lines) gives the counts and duration, each
failing spec and test with its message, and the first stack frames inside the project (frames of
`node_modules`, `site-packages`, the standard library and the runtime dropped). MCP `get_run`
includes it, fenced as untrusted.

## Security

- `select` values, changed files and session changes are data: paths are relative, normalized
  and inside the workspace (snapshot paths' rules); test names are capped and passed as single
  arguments, never through a shell.
- Exec mode is three opt-ins: the agent's subjects, the `exec` scope, testor's signed claim.
- The cache never serves a result across projects; its key holds everything the owner declared
  as an input, and a wrong hermetic claim affects only that owner's project.
- Sessions write only inside their own workspace and need the execute scope on their project;
  an idle session ends by itself.
