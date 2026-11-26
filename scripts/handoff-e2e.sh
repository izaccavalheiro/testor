#!/usr/bin/env bash
# testor run end to end (docs/handoff.md): a command handed to the agent image through testor
# comes back with its stdout, stderr and exit code as a local run gives them; a selection
# reaches it as arguments; the same tree again is answered from the result cache.
#
#   scripts/handoff-e2e.sh <testor image> <agent image>
set -euo pipefail
TESTOR=${1:-testor:ci}
AGENT=${2:-testor-agent:ci}
NET=testor-handoff-$$
WORK=$(mktemp -d)
PASS=e2e-password-1234
cleanup() {
  docker rm -f "$NET-testor" "$NET-agent" >/dev/null 2>&1 || true; docker network rm "$NET" >/dev/null 2>&1 || true
  rm -rf "$WORK" 2>/dev/null || sudo rm -rf "$WORK" || true
}
trap cleanup EXIT

docker network create "$NET" >/dev/null
docker run -d --name "$NET-testor" --network "$NET" --network-alias testor \
  -e TESTOR_ALLOWED_HOSTS=testor --read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges "$TESTOR" >/dev/null
for _ in $(seq 1 30); do docker exec "$NET-testor" /app/bin/testor eval 'Testor.Probe.check()' >/dev/null 2>&1 && break; sleep 2; done
docker exec "$NET-testor" sh -c 'echo "{\"execution\": {\"enabled\": true, \"warmSeconds\": 0}}" > /data/workspaces/.testor/config.json'
docker exec -e TESTOR_PASSWORD=$PASS "$NET-testor" /app/bin/testor eval 'Testor.Auth.CLI.user ~s[admin], ~s[admin]' >/dev/null
docker exec -e TESTOR_PASSWORD=$PASS "$NET-testor" /app/bin/testor eval 'Testor.Auth.CLI.user ~s[k8s-agent], ~s[agent]' >/dev/null
sleep 2
AGENT_TOKEN=$(docker exec "$NET-testor" /app/bin/testor eval 'Testor.Auth.CLI.token ~s[k8s-agent], 1' | tail -1 | tr -d '\r\n ')
USER_TOKEN=$(docker exec "$NET-testor" /app/bin/testor eval 'Testor.Auth.CLI.token ~s[admin], 1' | tail -1 | tr -d '\r\n ')

# The project: a test script writing to both streams, exiting 3 while "fail" exists.
mkdir -p "$WORK/hand"
cat > "$WORK/hand/t.ps1" <<'PS'
"out: $(($args | ForEach-Object { "[$_]" }) -join ' ')"
"second line"
[Console]::Error.WriteLine("err line")
"third line"
if (Test-Path fail) { exit 3 }
PS
touch "$WORK/hand/fail"
git -C "$WORK/hand" init -q -b main
git -C "$WORK/hand" -c user.name=e2e -c user.email=e2e@example.com add -A
git -C "$WORK/hand" -c user.name=e2e -c user.email=e2e@example.com commit -qm tree

cat > "$WORK/agent.json" <<'JSON'
{ "server": "http://testor:6767", "home": "/home/agent/testor", "upload": true, "labels": ["linux"],
  "projects": { "hand": { "snapshots": true, "cache": true,
    "commands": { "test": { "argv": ["pwsh", "-NoProfile", "-File", "t.ps1"],
                            "select": { "files": "append", "names": ["-Name", "{}"] } } } } } }
JSON
chmod 644 "$WORK/agent.json"
docker run -d --name "$NET-agent" --network "$NET" -e TESTOR_AGENT_TOKEN="$AGENT_TOKEN" -v "$WORK/agent.json:/etc/testor-agent/agent.json:ro" \
  --read-only --tmpfs /tmp --tmpfs /home/agent:uid=10001,gid=10001 --cap-drop ALL --security-opt no-new-privileges "$AGENT" >/dev/null

# testor run, from a container of the agent image (PowerShell and git), as the repository's owner.
run() {
  docker run --rm --network "$NET" --user "$(id -u):$(id -g)" -e HOME=/tmp --tmpfs /tmp -e TESTOR_URL=http://testor:6767 \
    -e TESTOR_TOKEN="$USER_TOKEN" -v "$WORK/hand:/hand" -w /hand --entrypoint pwsh "$AGENT" -NoProfile -NonInteractive \
    -File /opt/testor-agent/testor.ps1 run "$@"
}
local_run() {
  docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp --tmpfs /tmp -v "$WORK/hand:/hand" -w /hand --entrypoint pwsh "$AGENT" \
    -NoProfile -NonInteractive -File t.ps1 "$@"
}

set +e
local_run > "$WORK/local.out" 2> "$WORK/local.err"; LOCAL=$?
START=$(date +%s%N)
run > "$WORK/remote.out" 2> "$WORK/remote.err"; REMOTE=$?
set -e
echo "local exit $LOCAL, remote exit $REMOTE ($(( ($(date +%s%N) - START) / 1000000 )) ms)"
echo "--- stdout"; cat "$WORK/remote.out"; echo "--- stderr"; cat "$WORK/remote.err"
[ "$REMOTE" = 3 ] && [ "$LOCAL" = 3 ] || { echo "FAIL: the exit code is not the command's"; docker logs "$NET-agent" | tail -20; exit 1; }
cmp "$WORK/local.out" "$WORK/remote.out" || { echo "FAIL: stdout differs from a local run"; exit 1; }
grep -qx "err line" "$WORK/remote.err" || { echo "FAIL: stderr did not come back on stderr"; exit 1; }
! grep -q "err line" "$WORK/remote.out" || { echo "FAIL: stderr came back on stdout"; exit 1; }

# A selection reaches the command as separate arguments, never through a shell.
set +e
run --files 'a b.test.ts' --names 'adds; rm -rf /' > "$WORK/scoped.out" 2> "$WORK/scoped.err"
set -e
grep -qx "out: \[a b.test.ts\] \[-Name\] \[adds; rm -rf /\]" "$WORK/scoped.out" || { cat "$WORK/scoped.out" "$WORK/scoped.err"; docker logs "$NET-agent" | tail -5; echo "FAIL: the selection did not arrive as arguments"; exit 1; }

# Passing, then the same tree again: answered from the cache, its output replayed.
rm "$WORK/hand/fail"
run > "$WORK/pass.out" 2>/dev/null || { echo "FAIL: the passing run did not exit 0"; exit 1; }
START=$(date +%s%N)
run > "$WORK/cached.out" 2> "$WORK/cached.err" || { echo "FAIL: the cached run did not exit 0"; exit 1; }
echo "cached in $(( ($(date +%s%N) - START) / 1000000 )) ms"
grep -q "cached result of" "$WORK/cached.err" || { cat "$WORK/cached.err"; echo "FAIL: the second run was not answered from the cache"; exit 1; }
cmp "$WORK/pass.out" "$WORK/cached.out" || { echo "FAIL: the cached output differs"; exit 1; }
echo "ok: testor run kept stdout, stderr and the exit code, passed a selection as arguments, and answered a rerun from the cache"
