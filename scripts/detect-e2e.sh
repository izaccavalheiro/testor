#!/usr/bin/env bash
# The zero-config profiler (docs/zero-config.md) on fixtures of each ecosystem and a monorepo:
# what it proposes, and that it runs nothing (a package.json whose scripts would fail loudly).
#
#   scripts/detect-e2e.sh <agent image>
set -euo pipefail
AGENT=${1:-testor-agent:ci}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
chmod 755 "$WORK"

mk() { mkdir -p "$(dirname "$WORK/$1")"; printf '%s\n' "$2" > "$WORK/$1"; }
mk node/package.json '{"scripts": {"test": "vitest run", "lint": "eslint .", "preinstall": "exit 1"},
  "devDependencies": {"vitest": "3.2.0", "@playwright/test": "1.55.0", "@stryker-mutator/core": "9.1.0"}}'
mk node/pnpm-lock.yaml 'lockfileVersion: 9.0'
mk node/playwright.config.ts 'export default {}'
mk python/pyproject.toml '[project]
name = "x"
dependencies = ["pytest", "pytest-testmon", "pytest-cov"]'
mk go/go.mod 'module example.com/x'
mk rust/Cargo.toml '[package]
name = "x"'
mk rust/.config/nextest.toml '[profile.ci]'
mk dotnet/App.sln ''
mk dotnet/stryker-config.json '{}'
mk mono/web/package.json '{"devDependencies": {"jest": "30.0.0"}}'
mk mono/api/go.mod 'module example.com/api'
mkdir -p "$WORK/empty"
chmod -R a+rX "$WORK"

detect() { docker run --rm -v "$WORK:/f:ro" --entrypoint pwsh "$AGENT" -NoProfile -NonInteractive -File /opt/testor-agent/agent.ps1 -Detect "/f/$1"; }
check() {
  python3 - "$1" "$2" <<'PY'
import json, sys
doc = json.loads(sys.argv[1])
for expr in sys.argv[2].split(";"):
    assert eval(expr, {"p": doc["projects"]}), f"not true: {expr}\n{json.dumps(doc, indent=1)}"
PY
}

check "$(detect node)" 'p["node"]["commands"]["install"]["command"] == "pnpm install --frozen-lockfile";p["node"]["commands"]["test"]["argv"][:4] == ["pnpm", "exec", "vitest", "run"];p["node"]["commands"]["test"]["select"]["names"] == ["-t", "{}"];"related" in p["node"]["commands"]["test"]["affected"]["argv"];p["node"]["commands"]["e2e"]["artifacts"] == ["playwright-report", "test-results"];p["node"]["commands"]["mutation"]["state"] == ["reports/stryker-incremental.json"];set(p["node"]["labels"]) == {"linux", "browser", "mutation"};p["node"]["commands"]["lint"]["command"] == "pnpm run lint";p["node"]["snapshots"] is True'
check "$(detect python)" 'p["python"]["commands"]["test"]["argv"][:3] == ["python", "-m", "pytest"];"--testmon" in p["python"]["commands"]["test"]["affected"]["argv"];"coverage" in p["python"]["commands"];p["python"]["fullRunOn"] == ["conftest.py"]'
check "$(detect go)" 'p["go"]["commands"]["test"]["argv"] == ["go", "test", "./..."];p["go"]["commands"]["test"]["select"]["names"] == ["-run", "{}"]'
check "$(detect rust)" 'p["rust"]["commands"]["test"]["argv"][:3] == ["cargo", "nextest", "run"];p["rust"]["commands"]["test"]["preserve"] == ["target"]'
check "$(detect dotnet)" 'p["dotnet"]["commands"]["test"]["reports"] == ["reports/test.trx"];"mutation" in p["dotnet"]["commands"]'
check "$(detect mono)" 'set(p) == {"web", "api"};p["web"]["workspace"] == "./web";p["web"]["commands"]["test"]["argv"][:2] == ["npx", "jest"];p["api"]["commands"]["test"]["argv"][0] == "go"'
if detect empty >/dev/null 2>&1; then echo "FAIL: an empty folder should find nothing"; exit 1; fi
echo "ok: the profiler proposed entries for Node, Python, Go, Rust, .NET and a monorepo, running nothing"
