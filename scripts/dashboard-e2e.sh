#!/usr/bin/env bash
# The dashboard end to end: a testor container seeded with sample runs (e2e/dashboard/seed.mjs),
# every page and feature driven in Chromium by Playwright (e2e/dashboard/tests), at desktop and
# phone widths, a screenshot of every step kept in e2e/dashboard/test-results.
#
#   scripts/dashboard-e2e.sh [testor image] [-- playwright args]
#
# DOCS_SHOTS=1 also writes the dashboard tour's images to website/static/img/dashboard; KEEP=1
# leaves the container running afterwards (to look at it).
set -euo pipefail
TESTOR=${1:-testor:ci}
[ $# -gt 0 ] && shift
[ "${1:-}" = "--" ] && shift
NAME=testor-dashboard-e2e-$$
PORT=
PASS=e2e-password-1234
DIR=$(cd "$(dirname "$0")/../e2e/dashboard" && pwd)
cleanup() { [ -n "${KEEP:-}" ] && { echo "kept $NAME at port $PORT"; return; }; docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

# Each test opens a page (one or two event streams), and a closed page's stream is only noticed
# at its next heartbeat (15 s): one user holds more streams than a person would.
# A fixed port: a test restarts testor, and the page must find it where it was.
PORT=$(node -e 'const s = require("node:net").createServer().listen(0, "127.0.0.1", () => { console.log(s.address().port); s.close(); })')
docker run -d --name "$NAME" -p "127.0.0.1:$PORT:6767" -e TESTOR_MAX_STREAMS_PER_CLIENT=200 --read-only --tmpfs /tmp --cap-drop ALL \
  --security-opt no-new-privileges "$TESTOR" >/dev/null
for _ in $(seq 1 30); do docker exec "$NAME" /app/bin/testor eval 'Testor.Probe.check()' >/dev/null 2>&1 && break; sleep 2; done

# A person signs in with a password; the hub reads this testor (and one that is down) with a token.
# An AI agent (an operator's token) asks over MCP for what approvals hold (seed.mjs).
docker exec -e TESTOR_PASSWORD=$PASS "$NAME" /app/bin/testor eval 'Testor.Auth.CLI.user ~s[ada], ~s[admin]' >/dev/null
docker exec -e TESTOR_PASSWORD=$PASS "$NAME" /app/bin/testor eval 'Testor.Auth.CLI.user ~s[claude-agent], ~s[operator]' >/dev/null
sleep 2
TOKEN=$(docker exec "$NAME" /app/bin/testor eval 'Testor.Auth.CLI.token ~s[ada], 1' | tail -1 | tr -d '\r\n ')
AGENT_TOKEN=$(docker exec "$NAME" /app/bin/testor eval 'Testor.Auth.CLI.token ~s[claude-agent], 1' | tail -1 | tr -d '\r\n ')
docker exec -i "$NAME" sh -c 'cat > /data/workspaces/.testor/hub.json' <<JSON
{"intervalSeconds": 5, "testors": [
  {"name": "linux-lab", "url": "http://127.0.0.1:6767", "token": "$TOKEN", "labels": ["linux", "e2e"]},
  {"name": "mac-mini", "url": "http://127.0.0.1:9", "token": "$TOKEN", "labels": ["macos"]}]}
JSON
# hub.json is read when testor starts.
docker restart "$NAME" >/dev/null
for _ in $(seq 1 30); do docker exec "$NAME" /app/bin/testor eval 'Testor.Probe.check()' >/dev/null 2>&1 && break; sleep 2; done

cd "$DIR"
[ -d node_modules/@playwright/test ] || npm ci --no-audit --no-fund
status=0
TESTOR_URL=http://127.0.0.1:$PORT TESTOR_CONTAINER=$NAME TESTOR_USER=ada TESTOR_PASSWORD=$PASS TESTOR_AGENT_TOKEN=$AGENT_TOKEN \
  npx playwright test "$@" || status=$?
[ $status -eq 0 ] || docker logs --tail 80 "$NAME"
exit $status
