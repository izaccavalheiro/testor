# Contributing to testor

Thank you for helping. Bug reports, documentation fixes, new test-runner formats for the spec
parser, platform support and features from the [roadmap](ROADMAP.md) are all welcome. By taking
part you agree to the [code of conduct](CODE_OF_CONDUCT.md).

## Before you start

- **A bug**: open an issue with the version (`GET /api/health`), the runner's and workstation's
  OS, what you ran and what happened. `task testor:logs` shows the orchestrator's log.
- **A feature**: open an issue first for anything bigger than a small fix, so the design can be
  agreed before you write it. Check that it fits the principles in the roadmap.
- **A security problem**: do not open an issue; see [SECURITY.md](SECURITY.md).

## The repository

| Path | What | Language |
| ---- | ---- | -------- |
| `orchestrator/` | the application (OTP, Bandit, Plug) and the dashboard (`priv/static/index.html`, one file, no build step) | Elixir, HTML/JS |
| `runner/` | `run.ps1`, `install.ps1`, `setup.ps1` | PowerShell |
| `taskfiles/` | the workstation's tasks | go-task YAML |
| `scripts/` | `smoke.ps1` (end-to-end check of a release), `release.mjs` (versions) | PowerShell, Node.js |
| `docs/` | reference pages, also published on the site | Markdown |
| `website/` | the documentation site | Docusaurus |

## Checks

You need Erlang/OTP 27+ and Elixir 1.18+ to work on the orchestrator. If your machine has none,
let a runner do it: every check runs there.

| Check | Locally | On a runner |
| ----- | ------- | ----------- |
| format, warnings as errors, ExUnit with 100% coverage | `cd orchestrator && mix format --check-formatted && mix compile --warnings-as-errors && pwsh test/partitions.ps1` (four partitions at once, coverage merged; `mix test --cover` runs them one after the other) | `task testor:test` |
| format the sources | `mix format` | `task testor:format` (copies them back) |
| release smoke test | `MIX_ENV=prod mix release && pwsh scripts/smoke.ps1 -Release orchestrator/_build/prod/rel/testor` | `task testor:smoke` |
| everything CI runs on the orchestrator | | `task testor:ci` |
| the release tool | `node --test scripts/release.test.mjs` | |
| the site | `cd website && npm ci && npm run build` | |

CI runs the orchestrator's checks on Windows, Linux and macOS, parses every PowerShell script
with PowerShell 7 (and 5.1 for the scripts Windows PowerShell runs), renders the Taskfiles,
builds the site, and lints commit subjects.

### Rules the checks enforce, and some they cannot

- **100% line coverage** of `lib/`, except the platform adapters (`Testor.OS`, `Testor.Device`,
  `Testor.Device.Unix`), which `scripts/smoke.ps1` checks on each OS. New code comes with tests;
  integration tests (`test/integration/`) start the whole server.
- **Warnings are errors.** `mix format` decides the layout.
- **Windows paths.** Build paths with `Path.join` / `Join-Path`, never by concatenating `/`.
- **PowerShell 5.1.** `runner/setup.ps1` and `orchestrator/priv/sysinfo.ps1` run in Windows
  PowerShell 5.1 too, and every `.ps1` under `runner/` and `orchestrator/priv/` must be ASCII
  (5.1 reads files without a BOM in the ANSI code page).
- **The terminal is unchanged.** `run.ps1` must never alter a command's output, stderr or exit
  code; its own failures are warnings.
- **No external requests from the dashboard.** It is one self-contained HTML file.
- **No new dependency** without a reason in the pull request: testor has two (Bandit, Plug).

## Commits

Commit subjects follow [Conventional Commits](https://www.conventionalcommits.org): they decide
the next version ([VERSIONING.md](VERSIONING.md)), and CI checks them.

```text
<type>(<scope>)!: <subject in lower case, no final period>

<body: what and why, wrapped at 100>

BREAKING CHANGE: <what breaks and what to do instead>
```

| Type | For | Release |
| ---- | --- | ------- |
| `feat` | a new capability for users | minor |
| `fix` | a bug fix | patch |
| `perf` | faster or lighter, same behaviour | patch |
| `refactor`, `test`, `docs`, `build`, `ci`, `chore`, `style` | everything else | none |
| `!` after the scope, or a `BREAKING CHANGE:` footer | a change to a [public surface](VERSIONING.md#what-the-version-covers) that breaks its users | minor before 1.0, major after |

Scopes in use: `orchestrator`, `dashboard`, `api`, `mcp`, `auth`, `device`, `runner`,
`taskfiles`, `site`, `release`, `deps`. `node scripts/release.mjs lint-commits origin/main..HEAD`
checks your branch.

## Pull requests

1. Branch from `main`; keep a pull request to one subject.
2. Add an entry under `## Unreleased` in [CHANGELOG.md](CHANGELOG.md), in the right section
   (**Breaking**, **Added**, **Changed**, **Deprecated**, **Removed**, **Fixed**, **Security**),
   written for users: what they can do now, or what changed for them.
3. Update the documentation the change touches: the reference in `docs/`, the guides in
   `website/docs/`, the README when the quick start changes.
4. A breaking change says so in the pull request, the commit and the changelog, with the
   migration.

Maintainers merge with a squash or a rebase, keeping Conventional Commit subjects. Releases are
cut as [VERSIONING.md](VERSIONING.md#cutting-a-release) describes.

## The documentation site

`website/` is a Docusaurus site. `npm run start` serves it with live reload; `npm run build`
checks every link. The pages under `website/docs/reference/` and `website/docs/project/` are
generated from `docs/` and the files at the root by `website/scripts/sync.mjs`: edit the
originals, not the generated copies (they are not committed).
