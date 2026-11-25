# Versioning and releases

testor follows [Semantic Versioning 2.0.0](https://semver.org). A version number
`MAJOR.MINOR.PATCH` tells you what an upgrade can do to you: this page says exactly which
surfaces that promise covers, how commits decide the next number, and how a release is cut.

## The version

It lives in one place, `version:` in [`orchestrator/mix.exs`](orchestrator/mix.exs). A running
testor reports it in `GET /api/health` and `GET /api/v1/health` (`version`), in MCP's
`initialize` result (`serverInfo.version`). `node scripts/release.mjs current` prints it.

## What the version covers

**Public** surfaces are what people build on. A change that breaks one of them is a breaking
change, and it is announced under **Breaking** in the [changelog](CHANGELOG.md) with what to do.

| Surface | Covered |
| ------- | ------- |
| Versioned HTTP API | every path under `/api/v1`, its parameters, status codes, and the fields of its JSON answers and event streams, as `GET /api/v1/openapi.json` describes them. Adding a field, an endpoint, an optional parameter or an event is not breaking: clients must ignore what they do not know |
| MCP server | `/mcp`: tool names, their arguments, the shape of their results, the scope each needs. New tools and new optional arguments are not breaking |
| Run records | the fields of `runs/<id>.json` and the layout of `runs/`, `logs/`, `screenshots/`, `artifacts/` under the testor home ([architecture](docs/architecture.md#the-run-record)) |
| `run.ps1` | its parameters (`-Project`, `-Kind`, `-Body`, `-Artifacts`), the environment it gives the command (`TESTOR_RUN_ID`, `SCREENSHOT_DIR`, `TESTOR_ARTIFACT_DIR`), and the promise that output, stderr and exit code pass through unchanged |
| Taskfiles | the tasks and variables of `taskfiles/remote.yml` and `taskfiles/testor.yml` that are documented |
| Configuration | keys of `config.json` and `auth.json`, their defaults' meaning, the environment variables `TESTOR_HOME`, `TESTOR_WORKSPACES`, `TESTOR_PORT`, `TESTOR_BIND`, `TESTOR_JWT_SECRET` |
| Auth | roles, scopes and what each allows; the token claims; `Testor.Auth.CLI` functions |
| Platforms | the runner and workstation OSes and the minimum Erlang/OTP, Elixir, PowerShell and Task versions in the README. Raising a minimum is breaking |

**Not covered**, and free to change in any release (the changelog still says so when it
matters):

- the dashboard's look and its own routes (`/api/state`, `/api/runs/...`, `/events`, ...): they
  serve the dashboard page and change with it. Programs use `/api/v1`, which has the same data;
- log messages and the text of error messages (codes and status codes are covered);
- Elixir modules other than `Testor.Auth.CLI`: testor is an application, not a library;
- the spec lines `SpecParser` recognizes: new formats are features; a test runner that changes
  its output may stop being parsed, and is then fixed in a patch.

## How commits decide the next version

Commit subjects follow [Conventional Commits](https://www.conventionalcommits.org)
(`type(scope)!: subject`; see [CONTRIBUTING.md](CONTRIBUTING.md)). CI refuses a pull request
whose commits do not. Since the last release:

| Commits contain | 0.x (now) | from 1.0.0 |
| --------------- | --------- | ---------- |
| a breaking change (`type!:` or a `BREAKING CHANGE:` footer) | minor | **major** |
| a feature (`feat:`) | minor | minor |
| a fix or a performance improvement (`fix:`, `perf:`) | patch | patch |
| only `docs`, `test`, `refactor`, `build`, `ci`, `chore`, `style` | no release | no release |

Before 1.0.0, SemVer allows anything to change at any time; testor promises more than that: a
**patch release is always safe to take**, and breaking changes only come with a minor
release, under **Breaking** in the changelog. `node scripts/release.mjs next` lists the commits
since the last release and the version they call for.

### Pre-releases

`1.0.0-rc.1`, `0.3.0-beta.2`: tagged from `main` or a `release/x.y` branch for people who want
to try a release early. They are marked as pre-releases on GitHub. A pre-release's successor
with any bump is its release (`1.0.0-rc.2` → `1.0.0`).

### Deprecations

A public surface that is going away is first marked deprecated in a minor release (in the
changelog under **Deprecated**, in the documentation, and where possible in the answer itself,
such as a `Deprecation` header on an HTTP route), and removed no earlier than the next major
release (before 1.0.0: the next minor release, and never in the same one).

### The API's own version

`/api/v1` is a version of the HTTP API, not of testor. A breaking change to the API is made by
adding `/api/v2` next to it; `/api/v1` then stays for at least one major release of testor
after `/api/v2` is released, deprecated. MCP tools change the same way: a new tool next to the
old one.

### Supported versions

The latest minor release gets fixes. Security fixes are also released for the previous minor
release for three months after its successor ([SECURITY.md](SECURITY.md)).

## Cutting a release

From a clean checkout of `main`:

```sh
node scripts/release.mjs next          # what changed, and the version it calls for
node scripts/release.mjs bump auto     # or major, minor, patch, or 1.0.0-rc.1
git switch -c release/v0.2.0
git commit -am "chore(release): 0.2.0"
# open a pull request; when CI passes and it is merged, tag the merge commit:
git tag -s v0.2.0 -m "testor 0.2.0"
git push origin v0.2.0
```

`bump` writes the version into `mix.exs` and turns the changelog's **Unreleased** section into
`## 0.2.0 - <date>`, leaving a new, empty **Unreleased** above it. Pushing the tag runs
[the release workflow](.github/workflows/release.yml), which

1. runs the whole CI pipeline on the tagged commit (Windows, Linux, macOS);
2. checks that the tag, `mix.exs` and the changelog agree (`release.mjs check --tag`), and that a
   stable version is tagged on a commit of `main`;
3. builds the release on each OS and packs it (`testor-<version>-<os>-<arch>.tar.gz`) with
   `SHA256SUMS`, and attests the archives' build provenance;
   from 0.3.0 the runner's scripts (`run.ps1`, `install.ps1`, `setup.ps1`) and an SPDX SBOM
   are assets too, the scripts covered by `SHA256SUMS` and the provenance attestation, and the
   container workflow publishes `ghcr.io/izaccavalheiro/testor:<version>` with its own;
4. creates the GitHub release with the changelog section as its notes; a version with a
   pre-release suffix is marked as a pre-release.

Nothing is published from a laptop. The documentation site is rebuilt from `main` by
[the site workflow](.github/workflows/site.yml).
