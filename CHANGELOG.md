# Changelog

## 0.1.0

The first release.

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
  scheduled task, firewall rule), `setup.ps1` (prepares or checks a Windows machine).
- **Taskfiles**: `testor.yml` (manage testor from the workstation), `remote.yml` (run a
  project's checks on the runner).
