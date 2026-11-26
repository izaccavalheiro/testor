#!/usr/bin/env bash
# Two testors serving one team, as in Kubernetes with replicas > 1: one home (a shared volume),
# one PostgreSQL. A job queued on one is taken through the other; both serve its run; its side
# effects happen once; each keeps its own audit trail.
#
#   scripts/cluster-e2e.sh <testor image> <agent image>
set -euo pipefail
json() { python3 -c 'import json, sys; d = json.load(sys.stdin)
for k in sys.argv[1].split("."): d = (d or {}).get(k)
print(d if d is not None else "")' "$1"; }
TESTOR=${1:-testor:ci}
AGENT=${2:-testor-agent:ci}
NET=testor-cluster-$$
WORK=$(mktemp -d)
PASS=cluster-password-1234
PG_IMAGE=postgres:17.11@sha256:ff87138949ad9a46f32ff23bd6852b52ce024a13dffe9b4087be98292cdd3b4f
# A private network: no TLS between testor and its database here (verify-full elsewhere).
DB="postgres://testor:testor-db@db:5432/testor?sslmode=disable"
cleanup() {
  docker rm -f "$NET-a" "$NET-b" "$NET-db" "$NET-agent" >/dev/null 2>&1 || true
  docker volume rm "$NET-home" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

docker network create "$NET" >/dev/null
docker volume create "$NET-home" >/dev/null
docker run -d --name "$NET-db" --network "$NET" --network-alias db -e POSTGRES_USER=testor \
  -e POSTGRES_PASSWORD=testor-db -e POSTGRES_DB=testor "$PG_IMAGE" >/dev/null
for _ in $(seq 1 30); do docker exec "$NET-db" pg_isready -U testor >/dev/null 2>&1 && break; sleep 1; done

# The volume belongs to the image's user (uid 10001).
docker run --rm -v "$NET-home:/data" --user root --entrypoint sh "$TESTOR" -c 'mkdir -p /data/workspaces/.testor && chown -R 10001:10001 /data'

start() {
  docker run -d --name "$NET-$1" --network "$NET" --network-alias "testor-$1" -p 127.0.0.1::6767 \
    -e TESTOR_ALLOWED_HOSTS="testor-a,testor-b" -e TESTOR_DATABASE_URL="$DB" -e TESTOR_INSTANCE="testor-$1" \
    -v "$NET-home:/data" --read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges "$TESTOR" >/dev/null
  for _ in $(seq 1 30); do docker exec "$NET-$1" /app/bin/testor eval 'Testor.Probe.check()' >/dev/null 2>&1 && return 0; sleep 2; done
  docker logs "$NET-$1" 2>&1 | tail -40
  echo "FAIL: testor-$1 did not start"
  exit 1
}
start a
start b
BASE_A=http://127.0.0.1:$(docker port "$NET-a" 6767/tcp | head -1 | sed 's/.*://')
BASE_B=http://127.0.0.1:$(docker port "$NET-b" 6767/tcp | head -1 | sed 's/.*://')

docker exec "$NET-a" sh -c 'echo "{\"execution\": {\"enabled\": true}}" > /data/workspaces/.testor/config.json'
docker exec -e TESTOR_PASSWORD=$PASS "$NET-a" /app/bin/testor eval 'Testor.Auth.CLI.user ~s[admin], ~s[admin]' >/dev/null
docker exec -e TESTOR_PASSWORD=$PASS "$NET-a" /app/bin/testor eval 'Testor.Auth.CLI.user ~s[pod-agent], ~s[agent]' >/dev/null
sleep 2
TOKEN=$(docker exec "$NET-b" /app/bin/testor eval 'Testor.Auth.CLI.token ~s[pod-agent], 1' | tail -1 | tr -d '\r\n ')

cat > "$WORK/agent.json" <<JSON
{ "server": "http://testor-a:6767", "home": "/home/agent/testor", "upload": true, "labels": ["linux"],
  "projects": { "shared": { "workspace": "/tmp", "commands": { "test": "'hello from the cluster'" } } } }
JSON
chmod 644 "$WORK/agent.json"

# Queued on b, taken through a: one queue.
JOB=$(curl -fsS -u admin:$PASS -H 'content-type: application/json' -d '{"project": "shared", "kind": "test", "labels": ["linux"]}' "$BASE_B/api/v1/jobs" | json id)
echo "queued $JOB on testor-b"
docker run --name "$NET-agent" --network "$NET" -e TESTOR_AGENT_TOKEN="$TOKEN" -v "$WORK/agent.json:/etc/testor-agent/agent.json:ro" \
  --read-only --tmpfs /tmp --tmpfs /home/agent:uid=10001,gid=10001 --cap-drop ALL --security-opt no-new-privileges \
  "$AGENT" -Once -Wait 20

for _ in $(seq 1 30); do
  RUN=$(curl -fsS -u admin:$PASS "$BASE_B/api/v1/jobs/$JOB" | json runId)
  A=$( [ -n "$RUN" ] && curl -fsS -u admin:$PASS "$BASE_A/api/v1/runs/$RUN" | json run.attested || true)
  B=$( [ -n "$RUN" ] && curl -fsS -u admin:$PASS "$BASE_B/api/v1/runs/$RUN" | json run.attested || true)
  [ "$A" = True ] && [ "$B" = True ] && break
  sleep 1
done
echo "run $RUN: signed as seen from a: $A, from b: $B"
[ "$(curl -fsS -u admin:$PASS "$BASE_B/api/v1/jobs/$JOB" | json status)" = passed ] || { echo "FAIL: the job did not pass"; exit 1; }
[ "$A" = True ] && [ "$B" = True ] || { echo "FAIL: both testors do not serve the signed run"; exit 1; }
curl -fsS -u admin:$PASS "$BASE_B/api/v1/runs/$RUN/log" | grep -q "hello from the cluster" || { echo "FAIL: testor-b does not serve the log"; exit 1; }

# Its side effects once: one claim for its end, across both.
CLAIMS=$(docker exec "$NET-db" psql -U testor -tAc "SELECT count(*) FROM testor_claims WHERE kind = 'finished' AND key = '$RUN'")
[ "$CLAIMS" = 1 ] || { echo "FAIL: the run's end was claimed $CLAIMS times"; exit 1; }

# Each testor's own audit trail.
docker exec "$NET-a" ls /data/workspaces/.testor | grep -q '^audit.testor-a.jsonl$' || { echo "FAIL: testor-a keeps no audit trail of its own"; exit 1; }
docker exec "$NET-a" ls /data/workspaces/.testor | grep -q '^audit.testor-b.jsonl$' || { echo "FAIL: testor-b keeps no audit trail of its own"; exit 1; }
echo "ok: two testors, one home, one queue: a job queued on one ran through the other, both serve it, signed once"
