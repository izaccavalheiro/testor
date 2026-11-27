#!/usr/bin/env bash
# Sharding end to end (docs/sharding.md): a batch of 4 shards of one snapshot, taken by two
# agents with 2 slots each, each shard running its plan's files, merged into one signed run. One
# agent is stopped mid-shard (SIGTERM): its shards are preempted and run again on a third agent
# alone, the others' are not.
#
#   scripts/shard-e2e.sh <testor image> <agent image>
set -euo pipefail
json() { python3 -c 'import json, sys; d = json.load(sys.stdin)
for k in sys.argv[1].split("."): d = (d or {}).get(k) if isinstance(d, dict) else (d[int(k)] if isinstance(d, list) and k.isdigit() and int(k) < len(d) else None)
print(json.dumps(d) if isinstance(d, (dict, list)) else (d if d is not None else ""))' "$1"; }
TESTOR=${1:-testor:ci}
AGENT=${2:-testor-agent:ci}
NET=testor-shard-$$
WORK=$(mktemp -d)
PASS=e2e-password-1234
cleanup() {
  docker rm -f "$NET-testor" "$NET-agent1" "$NET-agent2" "$NET-agent3" >/dev/null 2>&1 || true; docker network rm "$NET" >/dev/null 2>&1 || true
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
for a in agent1 agent2 agent3; do docker exec -e TESTOR_PASSWORD=$PASS "$NET-testor" /app/bin/testor eval "Testor.Auth.CLI.user ~s[$a], ~s[agent]" >/dev/null; done
sleep 2
USER_TOKEN=$(docker exec "$NET-testor" /app/bin/testor eval 'Testor.Auth.CLI.token ~s[admin], 1' | tail -1 | tr -d '\r\n ')

# Eight test files; each shard prints the files it got and its index, as a test tool would.
mkdir -p "$WORK/shop/tests"
for i in 1 2 3 4 5 6 7 8; do echo "test $i" > "$WORK/shop/tests/t$i.test.ts"; done
cat > "$WORK/shop/run.ps1" <<'PS'
"shard $env:TESTOR_SHARD_INDEX/$env:TESTOR_SHARD_TOTAL files: $($args -join ' ')"
foreach ($f in $args) { " ✓ $f (1 test) 1ms" }
Start-Sleep -Seconds 20
PS
git -C "$WORK/shop" init -q -b main
git -C "$WORK/shop" -c user.name=e2e -c user.email=e2e@example.com add -A
git -C "$WORK/shop" -c user.name=e2e -c user.email=e2e@example.com commit -qm tree
SNAP=$(docker run --rm --network "$NET" --user "$(id -u):$(id -g)" -e HOME=/tmp --tmpfs /tmp -e TESTOR_TOKEN="$USER_TOKEN" \
  -v "$WORK/shop:/shop" --entrypoint pwsh "$AGENT" -NoProfile -NonInteractive -File /opt/testor-agent/snapshot.ps1 \
  -Server http://testor:6767 -Project shop -Path /shop -Json | json id)

cat > "$WORK/agent.json" <<'JSON'
{ "server": "http://testor:6767", "home": "/home/agent/testor", "upload": true, "labels": ["linux"], "slots": 2,
  "projects": { "shop": { "snapshots": true,
    "commands": { "test": { "argv": ["pwsh", "-NoProfile", "-File", "run.ps1"], "select": { "files": "append" } } } } } }
JSON
chmod 644 "$WORK/agent.json"
agent() {
  local a=$1 token
  token=$(docker exec "$NET-testor" /app/bin/testor eval "Testor.Auth.CLI.token ~s[$a], 1" | tail -1 | tr -d '\r\n ')
  docker run -d --name "$NET-$a" --network "$NET" --hostname "$a" -e TESTOR_AGENT_TOKEN="$token" -v "$WORK/agent.json:/etc/testor-agent/agent.json:ro" \
    --read-only --tmpfs /tmp --tmpfs /home/agent:uid=10001,gid=10001 --cap-drop ALL --security-opt no-new-privileges "$AGENT" >/dev/null
}
agent agent1
agent agent2

PARENT=$(curl -fsS -u admin:$PASS -H 'content-type: application/json' \
  -d "{\"project\": \"shop\", \"kind\": \"test\", \"snapshot\": \"$SNAP\", \"shards\": 4, \"labels\": [\"linux\"]}" "$BASE/api/v1/jobs")
ID=$(echo "$PARENT" | json id)
echo "batch $ID"
# Once agent2 runs both its shards, it is stopped: they are preempted, and agent3 runs them.
for _ in $(seq 1 90); do
  [ "$(docker logs "$NET-agent2" 2>&1 | grep -c 'running shop test')" -ge 2 ] && break
  sleep 1
done
sleep 2
docker stop -t 45 "$NET-agent2" >/dev/null
echo "agent2 stopped:"; docker logs "$NET-agent2" 2>&1 | tail -8
agent agent3
for _ in $(seq 1 120); do
  STATUS=$(curl -fsS -u admin:$PASS "$BASE/api/v1/jobs/$ID" | json status)
  [ "$STATUS" != running ] && break
  sleep 1
done
JOB=$(curl -fsS -u admin:$PASS "$BASE/api/v1/jobs/$ID")
echo "$JOB" | python3 -m json.tool | head -40
[ "$STATUS" = passed ] || {
  for a in agent1 agent2 agent3; do echo "--- $a"; docker logs "$NET-$a" 2>&1 | tail -15; done
  echo "--- testor"; docker logs "$NET-testor" 2>&1 | grep -E 'jobs:|batch|store:' | tail -40
  echo "$JOB" | python3 -c 'import json, sys; [print(s) for s in json.load(sys.stdin).get("shardJobs", [])]'
  echo "FAIL: the batch did not pass"; exit 1; }
# agent2's shards were preempted (and finished by agent3), the others ran once.
echo "$JOB" | python3 -c '
import json, sys
shards = json.load(sys.stdin)["shardJobs"]
moved = [s for s in shards if s.get("preemptions") == 1]
kept = [s for s in shards if not s.get("preemptions")]
assert moved and kept, f"expected some shards preempted and some not: {shards}"
assert all(s["agent"] == "agent3" for s in moved), f"preempted shards did not finish on agent3: {shards}"
assert all(s["agent"] == "agent1" and s["attempts"] == 1 for s in kept), f"the other shards ran again: {shards}"
print(f"{len(moved)} shards preempted and run again on agent3, {len(kept)} ran once on agent1")
' || { echo "FAIL: the stopped agent's shards were not retried alone"; exit 1; }
RUN=$(echo "$JOB" | json runId)
# The merged run's record reaches the store a moment after the batch ends.
for _ in $(seq 1 30); do
  REC=$(curl -fsS -u admin:$PASS "$BASE/api/v1/runs/$RUN" || echo '{}')
  [ "$(echo "$REC" | json run.attested)" = True ] && break
  sleep 1
done
echo "$REC" | python3 -c 'import json,sys; r=json.load(sys.stdin)["run"]; print(r["status"], r["summary"], len(r["batch"]["shards"]))'
if [ "$(echo "$REC" | json run.summary.specs)" != 8 ]; then
  for r in $(echo "$JOB" | python3 -c 'import json,sys; print(" ".join(s.get("runId") or "" for s in json.load(sys.stdin)["shardJobs"]))'); do
    echo "--- shard run $r: $(curl -fsS -u admin:$PASS "$BASE/api/v1/runs/$r" | json run.summary)"; curl -fsS -u admin:$PASS "$BASE/api/v1/runs/$r/log"
  done
  echo "FAIL: the merged run does not hold the 8 test files"; exit 1
fi
[ "$(echo "$REC" | json run.attested)" = True ] || { echo "FAIL: the merged run is not signed"; exit 1; }
curl -fsS -u admin:$PASS "$BASE/api/v1/runs/$RUN/attestation" >/dev/null || { echo "FAIL: no attestation for the merged run"; exit 1; }
echo "ok: 4 shards on agents with slots ran their planned files; a stopped agent's shards were retried alone; all merged into one signed run"
