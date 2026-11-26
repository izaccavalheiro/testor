#!/usr/bin/env bash
# Two testors with no volume in common, as in Kubernetes with storage.s3: each its own empty home
# (a tmpfs), runs in an S3 bucket (versitygw, which checks SigV4 and checksums), the run index and
# live events in PostgreSQL, one set of keys. An agent sends its run through testor-b; testor-a's
# event stream (a browser's) shows it, and either testor serves its log, files and signature.
#
#   scripts/storage-e2e.sh <testor image> <agent image>
set -euo pipefail
json() { python3 -c 'import json, sys; d = json.load(sys.stdin)
for k in sys.argv[1].split("."): d = (d or {}).get(k)
print(d if d is not None else "")' "$1"; }
TESTOR=${1:-testor:ci}
AGENT=${2:-testor-agent:ci}
NET=testor-storage-$$
WORK=$(mktemp -d)
PASS=storage-password-1234
PG_IMAGE=postgres:17.11@sha256:ff87138949ad9a46f32ff23bd6852b52ce024a13dffe9b4087be98292cdd3b4f
S3_IMAGE=versity/versitygw:v1.10.0@sha256:89cad13cc981986ee284cbafea4613f9533ce6fd5f37a2c96c4c4fb8adb3a316
DB="postgres://testor:testor-db@db:5432/testor?sslmode=disable"
S3_KEY=e2e-access
S3_SECRET=e2e-secret-key-12345
cleanup() {
  kill "${SSE:-0}" 2>/dev/null || true
  docker rm -f "$NET-a" "$NET-b" "$NET-db" "$NET-s3" "$NET-agent" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  rm -rf "$WORK" 2>/dev/null || sudo rm -rf "$WORK" || true
}
trap cleanup EXIT

docker network create "$NET" >/dev/null
docker run -d --name "$NET-db" --network "$NET" --network-alias db -e POSTGRES_USER=testor \
  -e POSTGRES_PASSWORD=testor-db -e POSTGRES_DB=testor "$PG_IMAGE" >/dev/null
mkdir -p "$WORK/s3/runs" && chmod -R 777 "$WORK/s3"
docker run -d --name "$NET-s3" --network "$NET" --network-alias s3 -p 127.0.0.1::7070 -v "$WORK/s3:/data" "$S3_IMAGE" \
  --access "$S3_KEY" --secret "$S3_SECRET" posix /data >/dev/null
for _ in $(seq 1 30); do docker exec "$NET-db" pg_isready -U testor >/dev/null 2>&1 && break; sleep 1; done
S3_PORT=$(docker port "$NET-s3" 7070/tcp | head -1 | sed 's/.*://')

# config.json from outside the home (a ConfigMap in Kubernetes); presigned links name the
# bucket as this machine reaches it.
cat > "$WORK/config.json" <<JSON
{ "execution": {"enabled": true},
  "storage": {"type": "s3", "bucket": "runs", "region": "us-east-1", "endpoint": "http://s3:7070",
              "pathStyle": true, "publicEndpoint": "http://127.0.0.1:$S3_PORT"} }
JSON
chmod 644 "$WORK/config.json"
# One set of keys for both (keys.existingSecret in the chart).
key() { head -c 32 /dev/urandom | base64 | tr -d '\n'; }
TOKEN_KEY=$(key)
SIGNING_KEY=$(key)
JWT_SECRET=$(head -c 48 /dev/urandom | base64 | tr -d '\n')

start() {
  docker run -d --name "$NET-$1" --network "$NET" --network-alias "testor-$1" -p 127.0.0.1::6767 \
    -e TESTOR_ALLOWED_HOSTS="testor-a,testor-b" -e TESTOR_DATABASE_URL="$DB" -e TESTOR_INSTANCE="testor-$1" \
    -e TESTOR_CONFIG_FILE=/etc/testor/config.json -e AWS_ACCESS_KEY_ID="$S3_KEY" -e AWS_SECRET_ACCESS_KEY="$S3_SECRET" \
    -e TESTOR_TOKEN_KEY="$TOKEN_KEY" -e TESTOR_SIGNING_KEY="$SIGNING_KEY" -e TESTOR_JWT_SECRET="$JWT_SECRET" \
    -v "$WORK/config.json:/etc/testor/config.json:ro" --tmpfs /data:uid=10001,gid=10001 \
    --read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges "$TESTOR" >/dev/null
  for _ in $(seq 1 30); do docker exec "$NET-$1" /app/bin/testor eval 'Testor.Probe.check()' >/dev/null 2>&1 && break; sleep 2; done
  docker exec "$NET-$1" /app/bin/testor eval 'Testor.Probe.check()' >/dev/null 2>&1 || {
    docker logs "$NET-$1" 2>&1 | tail -40
    echo "FAIL: testor-$1 did not start"
    exit 1
  }
  # The same users on each (the chart's admin-user step, or single sign-on).
  docker exec -e TESTOR_PASSWORD=$PASS "$NET-$1" /app/bin/testor eval 'Testor.Auth.CLI.user ~s[admin], ~s[admin]' >/dev/null
  docker exec -e TESTOR_PASSWORD=$PASS "$NET-$1" /app/bin/testor eval 'Testor.Auth.CLI.user ~s[pod-agent], ~s[agent]' >/dev/null
}
start a
start b
BASE_A=http://127.0.0.1:$(docker port "$NET-a" 6767/tcp | head -1 | sed 's/.*://')
BASE_B=http://127.0.0.1:$(docker port "$NET-b" 6767/tcp | head -1 | sed 's/.*://')
sleep 2
# A token from testor-a, used on testor-b: one key signs for both.
TOKEN=$(docker exec "$NET-a" /app/bin/testor eval 'Testor.Auth.CLI.token ~s[pod-agent], 1' | tail -1 | tr -d '\r\n ')

# A browser on testor-a: its event stream, open before the run starts.
curl -sN -u admin:$PASS "$BASE_A/events" > "$WORK/events-a.txt" &
SSE=$!

cat > "$WORK/agent.json" <<JSON
{ "server": "http://testor-b:6767", "home": "/home/agent/testor", "upload": true, "labels": ["linux"],
  "projects": { "nofs": { "workspace": "/tmp",
    "commands": { "test": { "command": "New-Item -ItemType Directory -Force out/report | Out-Null; Set-Content out/report/index.html '<h1>from the bucket</h1>'; Set-Content out/data.bin 'payload'; 'hello from no shared volume'",
                            "artifacts": ["out"] } } } } }
JSON
chmod 644 "$WORK/agent.json"

JOB=$(curl -fsS -u admin:$PASS -H 'content-type: application/json' -d '{"project": "nofs", "kind": "test", "labels": ["linux"]}' "$BASE_A/api/v1/jobs" | json id)
echo "queued $JOB on testor-a"
docker run --name "$NET-agent" --network "$NET" -e TESTOR_AGENT_TOKEN="$TOKEN" -v "$WORK/agent.json:/etc/testor-agent/agent.json:ro" \
  --read-only --tmpfs /tmp --tmpfs /home/agent:uid=10001,gid=10001 --cap-drop ALL --security-opt no-new-privileges \
  "$AGENT" -Once -Wait 20

for _ in $(seq 1 60); do
  RUN=$(curl -fsS -u admin:$PASS "$BASE_A/api/v1/jobs/$JOB" | json runId)
  STORED=$( [ -n "$RUN" ] && curl -fsS -u admin:$PASS "$BASE_A/api/v1/runs/$RUN" | json run.stored || true)
  [ "$STORED" = True ] && break
  sleep 1
done
echo "run $RUN: stored as testor-a sees it: $STORED"
if [ "$STORED" != True ]; then
  for t in a b; do echo "--- testor-$t"; docker logs "$NET-$t" 2>&1 | tail -40; done
  curl -sS -u admin:$PASS "$BASE_A/api/v1/runs/$RUN" | head -c 600; echo
  docker exec "$NET-db" psql -U testor -tAc "SELECT id, status, version, origin FROM testor_runs"
  echo "FAIL: testor-a does not see the run stored"
  exit 1
fi
[ "$(curl -fsS -u admin:$PASS "$BASE_A/api/v1/jobs/$JOB" | json status)" = passed ] || { echo "FAIL: the job did not pass"; exit 1; }

for base in "$BASE_A" "$BASE_B"; do
  [ "$(curl -fsS -u admin:$PASS "$base/api/v1/runs/$RUN" | json run.status)" = passed ] || { echo "FAIL: $base: the run did not pass"; exit 1; }
  [ "$(curl -fsS -u admin:$PASS "$base/api/v1/runs/$RUN" | json run.attested)" = True ] || { echo "FAIL: $base: not signed"; exit 1; }
  curl -fsS -u admin:$PASS "$base/api/v1/runs/$RUN/log" | grep -q "hello from no shared volume" || { echo "FAIL: $base does not serve the log"; exit 1; }
done

# testor-a never had the run's files: the HTML report served by it, the download a presigned link.
curl -fsS -u admin:$PASS "$BASE_A/api/v1/runs/$RUN" > "$WORK/run.json"
url() { python3 -c 'import json, sys
for a in json.load(open(sys.argv[1]))["artifacts"]:
    if a["path"].endswith(sys.argv[2]): print(a["url"])' "$WORK/run.json" "$1" | head -1; }
REPORT=$(url report)
DATA=$(url data.bin)
[ -n "$REPORT" ] && [ -n "$DATA" ] || { cat "$WORK/run.json"; echo "FAIL: the artifacts are not listed on testor-a"; exit 1; }
curl -fsS -u admin:$PASS "$BASE_A$REPORT" | grep -q "from the bucket" || { echo "FAIL: testor-a does not serve the HTML report"; exit 1; }
LOCATION=$(curl -fsS -o /dev/null -w '%{redirect_url}' -u admin:$PASS "$BASE_A$DATA")
echo "$LOCATION" | grep -q "X-Amz-Signature=" || { echo "FAIL: the download is not a presigned link: $LOCATION"; exit 1; }
curl -fsS "$LOCATION" | grep -q payload || { echo "FAIL: the presigned link does not open the file"; exit 1; }

# testor-a's stream showed the run testor-b took in.
kill "$SSE" 2>/dev/null || true
grep -q "$RUN" "$WORK/events-a.txt" || { echo "FAIL: testor-a's event stream never showed $RUN"; exit 1; }

# The index holds it stored; the bucket holds its log in one object, no segments left.
ROWS=$(docker exec "$NET-db" psql -U testor -tAc "SELECT count(*) FROM testor_runs WHERE id = '$RUN' AND record->>'stored' = 'true'")
[ "$ROWS" = 1 ] || { echo "FAIL: the index does not hold the stored run"; exit 1; }
BUCKET=$(docker exec "$NET-s3" sh -c 'cd /data/runs && find . -type f' 2>/dev/null || sudo find "$WORK/s3/runs" -type f)
echo "$BUCKET" | grep -q "logs/$RUN.log" || { echo "$BUCKET"; echo "FAIL: the log is not in the bucket"; exit 1; }
! echo "$BUCKET" | grep -q "logs/$RUN/" || { echo "FAIL: the log's segments were left"; exit 1; }
# Neither home holds what the other took in only.
docker exec "$NET-a" sh -c "test ! -e /data/workspaces/.testor/artifacts/$RUN/out/data.bin" || { echo "FAIL: testor-a copied the download"; exit 1; }
echo "ok: two testors, no shared volume: a run sent through testor-b is live on testor-a, served by both, from the bucket"
