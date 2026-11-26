#!/usr/bin/env bash
# Sharding end to end (docs/sharding.md): a batch of 4 shards of one snapshot, taken by two
# agents with 2 slots each, each shard running its plan's files, merged into one signed run.
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

# Eight test files; each shard prints the files it got and its index, as a test tool would.
mkdir -p "$WORK/shop/tests"
for i in 1 2 3 4 5 6 7 8; do echo "test $i" > "$WORK/shop/tests/t$i.test.ts"; done
cat > "$WORK/shop/run.ps1" <<'PS'
"shard $env:TESTOR_SHARD_INDEX/$env:TESTOR_SHARD_TOTAL files: $($args -join ' ')"
foreach ($f in $args) { " ✓ $f (1 test) 1ms" }
Start-Sleep -Seconds 2
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
for a in agent1 agent2; do
  TOKEN=$(docker exec "$NET-testor" /app/bin/testor eval "Testor.Auth.CLI.token ~s[$a], 1" | tail -1 | tr -d '\r\n ')
  docker run -d --name "$NET-$a" --network "$NET" --hostname "$a" -e TESTOR_AGENT_TOKEN="$TOKEN" -v "$WORK/agent.json:/etc/testor-agent/agent.json:ro" \
    --read-only --tmpfs /tmp --tmpfs /home/agent:uid=10001,gid=10001 --cap-drop ALL --security-opt no-new-privileges "$AGENT" >/dev/null
done

PARENT=$(curl -fsS -u admin:$PASS -H 'content-type: application/json' \
  -d "{\"project\": \"shop\", \"kind\": \"test\", \"snapshot\": \"$SNAP\", \"shards\": 4, \"labels\": [\"linux\"]}" "$BASE/api/v1/jobs")
ID=$(echo "$PARENT" | json id)
echo "batch $ID"
for _ in $(seq 1 120); do
  STATUS=$(curl -fsS -u admin:$PASS "$BASE/api/v1/jobs/$ID" | json status)
  [ "$STATUS" != running ] && break
  sleep 1
done
JOB=$(curl -fsS -u admin:$PASS "$BASE/api/v1/jobs/$ID")
echo "$JOB" | python3 -m json.tool | head -40
[ "$STATUS" = passed ] || { for a in agent1 agent2; do docker logs "$NET-$a" | tail -10; done; echo "FAIL: the batch did not pass"; exit 1; }
AGENTS=$(echo "$JOB" | python3 -c 'import json,sys; print(len({s.get("agent") for s in json.load(sys.stdin)["shardJobs"]}))')
[ "$AGENTS" = 2 ] || { echo "FAIL: the shards did not spread over both agents"; exit 1; }
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
echo "ok: 4 shards on 2 agents with slots ran their planned files and merged into one signed run"
