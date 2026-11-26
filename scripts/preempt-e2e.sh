#!/usr/bin/env bash
# Preemption end to end (docs/zero-config.md, "Spot agents"): an agent stopped mid-run (SIGTERM,
# as an eviction or a spot notice sends) ends its job as preempted, its state saved; testor
# queues it again without spending an attempt, and the retry on another agent resumes from it.
#
#   scripts/preempt-e2e.sh <testor image> <agent image>
set -euo pipefail
json() { python3 -c 'import json, sys; d = json.load(sys.stdin)
for k in sys.argv[1].split("."): d = (d or {}).get(k)
print(d if d is not None else "")' "$1"; }
TESTOR=${1:-testor:ci}
AGENT=${2:-testor-agent:ci}
NET=testor-preempt-$$
WORK=$(mktemp -d)
PASS=e2e-password-1234
cleanup() {
  docker rm -f "$NET-testor" "$NET-agent1" "$NET-agent2" >/dev/null 2>&1 || true; docker network rm "$NET" >/dev/null 2>&1 || true
  rm -rf "$WORK" 2>/dev/null || sudo rm -rf "$WORK" || true
}
trap cleanup EXIT

docker network create "$NET" >/dev/null
docker run -d --name "$NET-testor" --network "$NET" --network-alias testor -p 127.0.0.1::6767 \
  -e TESTOR_ALLOWED_HOSTS=testor --read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges "$TESTOR" >/dev/null
for _ in $(seq 1 30); do docker exec "$NET-testor" /app/bin/testor eval 'Testor.Probe.check()' >/dev/null 2>&1 && break; sleep 2; done
PORT=$(docker port "$NET-testor" 6767/tcp | head -1 | sed 's/.*://')
BASE=http://127.0.0.1:$PORT
docker exec "$NET-testor" sh -c 'echo "{\"execution\": {\"enabled\": true, \"warmSeconds\": 0}}" > /data/workspaces/.testor/config.json'
docker exec -e TESTOR_PASSWORD=$PASS "$NET-testor" /app/bin/testor eval 'Testor.Auth.CLI.user ~s[admin], ~s[admin]' >/dev/null
for a in agent1 agent2; do docker exec -e TESTOR_PASSWORD=$PASS "$NET-testor" /app/bin/testor eval "Testor.Auth.CLI.user ~s[$a], ~s[agent]" >/dev/null; done
sleep 2
USER_TOKEN=$(docker exec "$NET-testor" /app/bin/testor eval 'Testor.Auth.CLI.token ~s[admin], 1' | tail -1 | tr -d '\r\n ')

mkdir -p "$WORK/spot"
echo "source" > "$WORK/spot/a.txt"
git -C "$WORK/spot" init -q -b main
git -C "$WORK/spot" -c user.name=e2e -c user.email=e2e@example.com add -A
git -C "$WORK/spot" -c user.name=e2e -c user.email=e2e@example.com commit -qm tree
SNAP=$(docker run --rm --network "$NET" --user "$(id -u):$(id -g)" -e HOME=/tmp --tmpfs /tmp -e TESTOR_TOKEN="$USER_TOKEN" \
  -v "$WORK/spot:/spot" --entrypoint pwsh "$AGENT" -NoProfile -NonInteractive -File /opt/testor-agent/snapshot.ps1 \
  -Server http://testor:6767 -Project spot -Path /spot -Json | json id)

# The first run counts 1 and takes a minute (it is stopped); the retry starts from the state.
cat > "$WORK/agent.json" <<'JSON'
{ "server": "http://testor:6767", "home": "/home/agent/testor", "upload": true, "labels": ["linux"],
  "projects": { "spot": { "snapshots": true,
    "commands": { "mutation": { "command": "$n = if (Test-Path .state/count) { [int](Get-Content .state/count) } else { 0 }; $n++; $null = New-Item -ItemType Directory -Force .state; Set-Content .state/count $n; \"count=$n\"; if ($n -eq 1) { Start-Sleep -Seconds 60 }",
                                "state": [".state/count"] } } } } }
JSON
chmod 644 "$WORK/agent.json"
agent() {
  local name=$1 token
  token=$(docker exec "$NET-testor" /app/bin/testor eval "Testor.Auth.CLI.token ~s[$name], 1" | tail -1 | tr -d '\r\n ')
  docker run -d --name "$NET-$name" --network "$NET" --hostname "$name" -e TESTOR_AGENT_TOKEN="$token" -v "$WORK/agent.json:/etc/testor-agent/agent.json:ro" \
    --read-only --tmpfs /tmp --tmpfs /home/agent:uid=10001,gid=10001 --cap-drop ALL --security-opt no-new-privileges "$AGENT" >/dev/null
}

ID=$(curl -fsS -u admin:$PASS -H 'content-type: application/json' \
  -d "{\"project\": \"spot\", \"kind\": \"mutation\", \"snapshot\": \"$SNAP\", \"labels\": [\"linux\"]}" "$BASE/api/v1/jobs" | json id)
agent agent1
for _ in $(seq 1 60); do [ "$(curl -fsS -u admin:$PASS "$BASE/api/v1/jobs/$ID" | json status)" = running ] && break; sleep 1; done
sleep 3
echo "stopping agent1 (SIGTERM) mid-run"
docker stop -t 45 "$NET-agent1" >/dev/null
docker logs "$NET-agent1" 2>&1 | tail -5
JOB=$(curl -fsS -u admin:$PASS "$BASE/api/v1/jobs/$ID")
echo "after the stop: $JOB"
[ "$(echo "$JOB" | json status)" = queued ] || { echo "FAIL: the job was not queued again"; exit 1; }
[ "$(echo "$JOB" | json preemptions)" = 1 ] || { echo "FAIL: the preemption was not counted"; exit 1; }
[ "$(echo "$JOB" | json attempts)" = 0 ] || { echo "FAIL: the preemption spent an attempt"; exit 1; }

agent agent2
for _ in $(seq 1 60); do [ "$(curl -fsS -u admin:$PASS "$BASE/api/v1/jobs/$ID" | json status)" = passed ] && break; sleep 1; done
JOB=$(curl -fsS -u admin:$PASS "$BASE/api/v1/jobs/$ID")
[ "$(echo "$JOB" | json status)" = passed ] || { docker logs "$NET-agent2" | tail -10; echo "FAIL: the retry did not pass"; exit 1; }
RUN=$(echo "$JOB" | json runId)
curl -fsS -u admin:$PASS "$BASE/api/v1/runs/$RUN/log" | grep -q "count=2" || { echo "FAIL: the retry did not resume from the saved state"; exit 1; }
echo "ok: a stopped agent's job was preempted, queued again without spending an attempt, and resumed from its state"
