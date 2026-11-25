#!/usr/bin/env bash
# testor and its agent in containers on one network, as in Kubernetes: a job queued through the
# API is taken by the agent container, run, and its run sent back to testor.
#
#   scripts/container-e2e.sh <testor image> <agent image>
set -euo pipefail
json() { python3 -c 'import json, sys; d = json.load(sys.stdin)
for k in sys.argv[1].split("."): d = (d or {}).get(k)
print(d if d is not None else "")' "$1"; }
TESTOR=${1:-testor:ci}
AGENT=${2:-testor-agent:ci}
NET=testor-e2e-$$
WORK=$(mktemp -d)
PASS=e2e-password-1234
cleanup() { docker rm -f "$NET-testor" "$NET-agent" >/dev/null 2>&1 || true; docker network rm "$NET" >/dev/null 2>&1 || true; rm -rf "$WORK"; }
trap cleanup EXIT

docker network create "$NET" >/dev/null
# The agent reaches testor by its container name: a name testor must be told to answer.
docker run -d --name "$NET-testor" --network "$NET" --network-alias testor -p 127.0.0.1::6767 \
  -e TESTOR_ALLOWED_HOSTS=testor --read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges "$TESTOR" >/dev/null
for _ in $(seq 1 30); do docker exec "$NET-testor" /app/bin/testor eval 'Testor.Probe.check()' >/dev/null 2>&1 && break; sleep 2; done
PORT=$(docker port "$NET-testor" 6767/tcp | head -1 | sed 's/.*://')
BASE=http://127.0.0.1:$PORT

docker exec "$NET-testor" sh -c 'echo "{\"execution\": {\"enabled\": true}}" > /data/workspaces/.testor/config.json'
docker exec -e TESTOR_PASSWORD=$PASS "$NET-testor" /app/bin/testor eval 'Testor.Auth.CLI.user ~s[admin], ~s[admin]' >/dev/null
docker exec -e TESTOR_PASSWORD=$PASS "$NET-testor" /app/bin/testor eval 'Testor.Auth.CLI.user ~s[k8s-agent], ~s[agent]' >/dev/null
sleep 2
TOKEN=$(docker exec "$NET-testor" /app/bin/testor eval 'Testor.Auth.CLI.token ~s[k8s-agent], 1' | tail -1 | tr -d '\r\n ')

cat > "$WORK/agent.json" <<JSON
{ "server": "http://testor:6767", "home": "/home/agent/testor", "upload": true, "labels": ["linux"],
  "projects": { "e2e": { "workspace": "/tmp",
                         "commands": { "test": "' ✓ tests/e2e.test.ts (1 test) 1ms'; 'hello from a pod'" } } } }
JSON
chmod 644 "$WORK/agent.json"

JOB=$(curl -fsS -u admin:$PASS -H 'content-type: application/json' -d '{"project": "e2e", "kind": "test", "labels": ["linux"]}' "$BASE/api/v1/jobs" | json id)
echo "queued $JOB"
docker run --name "$NET-agent" --network "$NET" -e TESTOR_AGENT_TOKEN="$TOKEN" -v "$WORK/agent.json:/etc/testor-agent/agent.json:ro" \
  --read-only --tmpfs /tmp --tmpfs /home/agent:uid=10001,gid=10001 --cap-drop ALL --security-opt no-new-privileges \
  "$AGENT" -Once -Wait 20

for _ in $(seq 1 30); do
  JOBJSON=$(curl -fsS -u admin:$PASS "$BASE/api/v1/jobs/$JOB")
  RUN=$(echo "$JOBJSON" | json runId)
  STATUS=$( [ -n "$RUN" ] && curl -fsS -u admin:$PASS "$BASE/api/v1/runs/$RUN" | json run.status || true)
  [ "$STATUS" = passed ] && break
  sleep 1
done
LOG=$(curl -fsS -u admin:$PASS "$BASE/api/v1/runs/$RUN/log")
echo "job: $JOBJSON"
echo "run $RUN: $STATUS"
[ "$(echo "$JOBJSON" | json status)" = passed ] || { echo "FAIL: the job did not pass"; exit 1; }
[ "$STATUS" = passed ] || { echo "FAIL: the run did not pass"; exit 1; }
echo "$LOG" | grep -q "hello from a pod" || { echo "FAIL: the run's log did not arrive"; exit 1; }
curl -fsS -u admin:$PASS "$BASE/metrics" | grep -q '^testor_jobs{status="passed"} 1' || { echo "FAIL: metrics do not count the job"; exit 1; }
echo "ok: a job ran in an agent container and its run reached testor"
