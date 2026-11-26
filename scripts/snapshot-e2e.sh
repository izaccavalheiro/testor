#!/usr/bin/env bash
# Snapshots and incremental state end to end (docs/snapshots.md): a tree of 10,000 files sent by
# runner/snapshot.ps1 and run by the agent image; then one file changed, which uploads and
# fetches one content, and a run that starts from the state the first one left in testor.
#
#   scripts/snapshot-e2e.sh <testor image> <agent image>
set -euo pipefail
json() { python3 -c 'import json, sys; d = json.load(sys.stdin)
for k in sys.argv[1].split("."): d = (d or {}).get(k)
print(d if d is not None else "")' "$1"; }
TESTOR=${1:-testor:ci}
AGENT=${2:-testor-agent:ci}
NET=testor-snap-$$
WORK=$(mktemp -d)
PASS=e2e-password-1234
cleanup() {
  docker rm -f "$NET-testor" >/dev/null 2>&1 || true; docker network rm "$NET" >/dev/null 2>&1 || true
  # The agent's files belong to its user (uid 10001): removed as it.
  docker run --rm -v "$WORK/agent-home:/h" --entrypoint sh "$AGENT" -c 'rm -rf /h/* /h/.[!.]*' >/dev/null 2>&1 || true
  rm -rf "$WORK" 2>/dev/null || sudo rm -rf "$WORK" || true
}
trap cleanup EXIT

docker network create "$NET" >/dev/null
docker run -d --name "$NET-testor" --network "$NET" --network-alias testor -p 127.0.0.1::6767 \
  -e TESTOR_ALLOWED_HOSTS=testor --read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges "$TESTOR" >/dev/null
for _ in $(seq 1 30); do docker exec "$NET-testor" /app/bin/testor eval 'Testor.Probe.check()' >/dev/null 2>&1 && break; sleep 2; done
PORT=$(docker port "$NET-testor" 6767/tcp | head -1 | sed 's/.*://')
BASE=http://127.0.0.1:$PORT
docker exec "$NET-testor" sh -c 'echo "{\"execution\": {\"enabled\": true}}" > /data/workspaces/.testor/config.json'
docker exec -e TESTOR_PASSWORD=$PASS "$NET-testor" /app/bin/testor eval 'Testor.Auth.CLI.user ~s[admin], ~s[admin]' >/dev/null
docker exec -e TESTOR_PASSWORD=$PASS "$NET-testor" /app/bin/testor eval 'Testor.Auth.CLI.user ~s[k8s-agent], ~s[agent]' >/dev/null
sleep 2
AGENT_TOKEN=$(docker exec "$NET-testor" /app/bin/testor eval 'Testor.Auth.CLI.token ~s[k8s-agent], 1' | tail -1 | tr -d '\r\n ')
USER_TOKEN=$(docker exec "$NET-testor" /app/bin/testor eval 'Testor.Auth.CLI.token ~s[admin], 1' | tail -1 | tr -d '\r\n ')

# The tree: 10,000 files of distinct contents, and .gitignore.
mkdir -p "$WORK/repo"
python3 - "$WORK/repo" <<'PY'
import os, sys
root = sys.argv[1]
for d in range(100):
    os.makedirs(f"{root}/src/d{d}", exist_ok=True)
    for f in range(100):
        open(f"{root}/src/d{d}/f{f}.txt", "w").write(f"file {d}/{f}\n")
open(f"{root}/.gitignore", "w").write(".state/\n")
PY
git -C "$WORK/repo" init -q -b main
git -C "$WORK/repo" -c user.name=e2e -c user.email=e2e@example.com add -A
git -C "$WORK/repo" -c user.name=e2e -c user.email=e2e@example.com commit -qm tree

snapshot() {
  docker run --rm --network "$NET" --user "$(id -u):$(id -g)" -e HOME=/tmp --tmpfs /tmp -e TESTOR_TOKEN="$USER_TOKEN" \
    -v "$WORK/repo:/repo" --entrypoint pwsh "$AGENT" -NoProfile -NonInteractive -File /opt/testor-agent/snapshot.ps1 \
    -Server http://testor:6767 -Project snap -Path /repo -Kind test -Labels linux -Json
}

# The agent keeps its home between jobs, as a StatefulSet's pod does: its cache and workspace.
mkdir -p "$WORK/agent-home" && chmod 777 "$WORK/agent-home"
cat > "$WORK/agent.json" <<'JSON'
{ "server": "http://testor:6767", "home": "/home/agent/testor", "upload": true, "labels": ["linux"],
  "projects": { "snap": { "snapshots": true,
    "commands": { "test": { "command": "$n = if (Test-Path .state/count) { [int](Get-Content .state/count) } else { 0 }; $null = New-Item -ItemType Directory -Force .state; Set-Content .state/count ($n + 1); 'count=' + ($n + 1) + ' first=' + (Get-Content src/d0/f0.txt)",
                            "state": [".state/count"] } } } } }
JSON
chmod 644 "$WORK/agent.json"
agent() {
  docker run --rm --network "$NET" -e TESTOR_AGENT_TOKEN="$AGENT_TOKEN" -v "$WORK/agent.json:/etc/testor-agent/agent.json:ro" \
    -v "$WORK/agent-home:/home/agent" --read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges \
    "$AGENT" -Once -Wait 20
}
# The job's run log, once the job passed.
run_log() {
  local job=$1 status run
  for _ in $(seq 1 60); do
    status=$(curl -fsS -u admin:$PASS "$BASE/api/v1/jobs/$job" | json status)
    run=$(curl -fsS -u admin:$PASS "$BASE/api/v1/jobs/$job" | json runId)
    [ "$status" = passed ] && [ -n "$run" ] && [ "$(curl -fsS -u admin:$PASS "$BASE/api/v1/runs/$run" | json run.status)" = passed ] && break
    sleep 1
  done
  [ "$status" = passed ] || { curl -fsS -u admin:$PASS "$BASE/api/v1/jobs/$job"; echo; echo "FAIL: job $job did not pass"; exit 1; }
  curl -fsS -u admin:$PASS "$BASE/api/v1/runs/$run/log"
}

START=$(date +%s)
FIRST=$(snapshot)
echo "first snapshot: $FIRST ($(( $(date +%s) - START )) s)"
[ "$(echo "$FIRST" | json files)" = 10001 ] || { echo "FAIL: the snapshot does not hold the tree"; exit 1; }
[ "$(echo "$FIRST" | json uploaded)" = 10001 ] || { echo "FAIL: the first snapshot should upload every content"; exit 1; }
agent | tee "$WORK/agent1.log"
grep -q "10001 files, 10001 fetched, 10001 written, 0 deleted" "$WORK/agent1.log" || { echo "FAIL: the agent did not write the snapshot"; exit 1; }
run_log "$(echo "$FIRST" | json job)" | grep -q "count=1 first=file 0/0" || { echo "FAIL: the first run's log"; exit 1; }
[ "$(curl -fsS -u admin:$PASS "$BASE/api/v1/projects/snap/state/.state--count?branch=main" | tr -d '\r\n')" = 1 ] || { echo "FAIL: the state was not saved"; exit 1; }

# One file changed, one deleted: one content travels each way.
echo "changed" > "$WORK/repo/src/d0/f0.txt"
rm "$WORK/repo/src/d99/f99.txt"
# The run's state goes from the workspace: the next run must restore it from testor.
docker run --rm -v "$WORK/agent-home:/h" --entrypoint sh "$AGENT" -c 'rm -rf /h/testor/workspaces/snap/.state'
START=$(date +%s)
SECOND=$(snapshot)
echo "second snapshot: $SECOND ($(( $(date +%s) - START )) s)"
[ "$(echo "$SECOND" | json uploaded)" = 1 ] || { echo "FAIL: a one-file change should upload one content"; exit 1; }
[ "$(echo "$SECOND" | json id)" != "$(echo "$FIRST" | json id)" ] || { echo "FAIL: the snapshot's id did not change"; exit 1; }
agent | tee "$WORK/agent2.log"
grep -q "10000 files, 1 fetched, 1 written, 1 deleted" "$WORK/agent2.log" || { echo "FAIL: the agent should fetch and write one file, and delete one"; exit 1; }
[ ! -e "$WORK/agent-home/testor/workspaces/snap/src/d99/f99.txt" ] || { echo "FAIL: the deleted file is still in the workspace"; exit 1; }
run_log "$(echo "$SECOND" | json job)" | grep -q "count=2 first=changed" || { echo "FAIL: the second run did not start from the saved state"; exit 1; }
echo "ok: 10,000 files sent once; a one-file change uploaded and fetched one content, and the state followed the branch"
