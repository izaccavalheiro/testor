# Changelog

## Unreleased

- **Artifacts**: `ARTIFACTS` in a task (`remote.yml`; `run.ps1 -Artifacts`) keeps the files and
  folders a run writes (coverage, HTML reports, Markdown, JUnit XML, ...) with the run, up to
  `artifacts.maxRunMB` per run; Playwright's videos and `$env:TESTOR_ARTIFACT_DIR` are kept too.
  Run pages list them (reports as one entry, videos with a player), an Artifacts page lists
  every run's, and the janitor limits them by age and size (`artifacts.*`). They are served
  sandboxed (`Content-Security-Policy: sandbox`), with byte ranges.
- **Maintenance**: a Maintenance page and `/api/maintenance` measure what testing leaves on the
  runner (idle project snapshots, old temporary files, the npm, pip, Go and Cargo caches, old
  Playwright browsers) and delete the targets chosen and confirmed, when `maintenance.enabled`
  is set in `config.json` and nothing runs.
- The janitor leaves a run's empty screenshot or artifact folder alone for an hour, so a run
  the store has not seen yet keeps it.

## 0.1.0

The first release. Runners can be Windows, Linux or macOS machines, and the workstation any of
them: commands run in PowerShell 7 everywhere and reach the runner base64-encoded.

- **Orchestrator** (Elixir/OTP, Bandit + Plug): follows the runs `run.ps1` records, parses spec
  results from their output (Vitest, Playwright, pytest, go test, cargo test), and streams runs,
  logs and progress to the dashboard over server-sent events. Cancels runs (process tree),
  settles aborted ones, flags overlapping runs of one project, cleans up old runs and
  screenshots.
- **Dashboard**: running runs with live progress and log tails, history with filters, a board of
  the latest result per project and task, run pages with streaming output, spec files and
  screenshots, a screenshots gallery, and device stats (OS, CPU per core, memory, GPU, storage,
  network, battery, top processes, per-run CPU and memory).
- **Runner**: `run.ps1` (records a run, output and exit code unchanged), `install.ps1` (release,
  installed as a scheduled task on Windows, a systemd user service on Linux, a launchd agent on
  macOS), `setup.ps1` (prepares or checks a machine).
- **Taskfiles**: `testor.yml` (manage testor from the workstation), `remote.yml` (run a
  project's checks on the runner).
