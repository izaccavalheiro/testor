---
sidebar_position: 3
title: Rust, Go and Python projects
description: Run cargo test, go test and pytest on a runner, with spec results and build caches that survive between runs.
---

# Rust, Go and Python projects

testor is not tied to Node.js: any command PowerShell 7 can start works, and the output of
`cargo test`, `go test` and pytest is parsed into spec results.

## The Taskfile

```yaml title="Taskfile.yml"
version: "3"
includes:
  runner:
    taskfile: ~/git/testor/taskfiles/remote.yml
    internal: true
    vars:
      RUNNER: my-runner
      # kept between uploads: dependencies and build caches
      KEEP: "target .venv node_modules .lockhash"

tasks:
  rust:
    cmds:
      - task: runner:sync
      - task: runner:exec
        vars: { KIND: rust, CMD: "cargo fmt --check; cargo clippy --all-targets -- -D warnings; cargo test" }

  go:
    cmds:
      - task: runner:sync
      - task: runner:exec
        vars: { KIND: go, CMD: "gofmt -l . | ForEach-Object { throw \"not formatted: $_\" }; go vet ./...; go test -race ./..." }

  python:
    cmds:
      - task: runner:sync
      - task: runner:exec
        vars:
          KIND: python
          CMD: |
            if (-not (Test-Path .venv)) { python -m venv .venv }
            $py = if ($IsWindows) { ".venv/Scripts/python" } else { ".venv/bin/python" }
            & $py -m pip install -q -e ".[test]"
            & $py -m pytest --junitxml=junit.xml
          ARTIFACTS: "junit.xml"
```

## Why `KEEP` matters

`sync` deletes the previous snapshot's files before unpacking the new one, except the names in
`KEEP` (default `node_modules .lockhash target .venv`). Keeping `target` makes `cargo test`
incremental; keeping `.venv` avoids recreating the environment. Add your own (`build`,
`.gradle`), separated by spaces.

## What testor reads

| Tool | Spec result |
| ---- | ----------- |
| `cargo test` | one entry per test binary (`Running tests/x.rs`), with its `test result:` counts |
| `go test` | one entry per package (`ok`/`FAIL`) |
| pytest | one entry per test file, from the progress dots (`..F.s`) |

`go test -v` and `cargo test -- --nocapture` still work; they just print more.

## Toolchains on the runner

Install them as on any machine (rustup, the Go installer, Python). On Windows, call Python by
full path or through `py` if the Microsoft Store stub shadows `python`. Build caches live
outside the snapshot (Cargo's registry, Go's build cache, pip's cache); the
[Maintenance page](../features/retention-and-maintenance.md) measures them and can clear them.

## Caveats

- **Native toolchains on Windows**: Rust's `x86_64-pc-windows-gnu` target needs a MinGW
  linker; cgo needs a C compiler on the PATH. These are toolchain concerns, not testor's, but
  they are what usually breaks first on a fresh Windows runner.
- **Antivirus** can lock freshly built test binaries; see
  [the Windows scenario](windows-from-linux.md#caveats).
