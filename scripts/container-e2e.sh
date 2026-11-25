#!/usr/bin/env bash
# testor and its agent in containers on one network, as in Kubernetes: a job queued through the
# API is taken by the agent container, run, and its run sent back to testor, which archives it
# to an S3-compatible server (versitygw, which checks SigV4 signatures and checksums).
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
# S3: versitygw over a folder (a bucket is a folder of it).
S3_IMAGE=versity/versitygw:v1.10.0@sha256:89cad13cc981986ee284cbafea4613f9533ce6fd5f37a2c96c4c4fb8adb3a316
cleanup() { docker rm -f "$NET-testor" "$NET-agent" "$NET-s3" >/dev/null 2>&1 || true; docker network rm "$NET" >/dev/null 2>&1 || true; rm -rf "$WORK"; }
trap cleanup EXIT

docker network create "$NET" >/dev/null
mkdir -p "$WORK/s3/evidence" && chmod -R 777 "$WORK/s3"
docker run -d --name "$NET-s3" --network "$NET" --network-alias s3 -v "$WORK/s3:/data" "$S3_IMAGE" \
  --access e2e-access --secret e2e-secret-key-12345 posix /data >/dev/null
# The agent reaches testor by its container name: a name testor must be told to answer.
docker run -d --name "$NET-testor" --network "$NET" --network-alias testor -p 127.0.0.1::6767 \
  -e TESTOR_ALLOWED_HOSTS=testor -e AWS_ACCESS_KEY_ID=e2e-access -e AWS_SECRET_ACCESS_KEY=e2e-secret-key-12345 --read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges "$TESTOR" >/dev/null
for _ in $(seq 1 30); do docker exec "$NET-testor" /app/bin/testor eval 'Testor.Probe.check()' >/dev/null 2>&1 && break; sleep 2; done
PORT=$(docker port "$NET-testor" 6767/tcp | head -1 | sed 's/.*://')
BASE=http://127.0.0.1:$PORT

docker exec "$NET-testor" sh -c 'echo "{\"execution\": {\"enabled\": true}, \"archive\": {\"bucket\": \"evidence\", \"region\": \"us-east-1\", \"endpoint\": \"http://s3:7070\", \"pathStyle\": true, \"prefix\": \"e2e\"}}" > /data/workspaces/.testor/config.json'
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
  SIGNED=$( [ -n "$RUN" ] && curl -fsS -u admin:$PASS "$BASE/api/v1/runs/$RUN" | json run.agentAttested || true)
  [ "$STATUS" = passed ] && [ "$SIGNED" = True ] && break
  sleep 1
done
LOG=$(curl -fsS -u admin:$PASS "$BASE/api/v1/runs/$RUN/log")
echo "job: $JOBJSON"
echo "run $RUN: $STATUS"
[ "$(echo "$JOBJSON" | json status)" = passed ] || { echo "FAIL: the job did not pass"; exit 1; }
[ "$STATUS" = passed ] || { echo "FAIL: the run did not pass"; exit 1; }
echo "$LOG" | grep -q "hello from a pod" || { echo "FAIL: the run's log did not arrive"; exit 1; }
curl -fsS -u admin:$PASS "$BASE/metrics" | grep -q '^testor_jobs{status="passed"} 1' || { echo "FAIL: metrics do not count the job"; exit 1; }
[ "$SIGNED" = True ] || { echo "FAIL: the agent's attestation was not accepted"; exit 1; }
# The agent's signature checks out with plain OpenSSL too (docs/attestation.md).
if command -v openssl >/dev/null; then
  curl -fsS -u admin:$PASS "$BASE/api/v1/runs/$RUN/attestation?by=agent" > "$WORK/envelope.json"
  curl -fsS -u admin:$PASS "$BASE/api/v1/agents" | python3 -c 'import json, sys; print(json.load(sys.stdin)["data"][0]["publicKey"], end="")' > "$WORK/agent.pem"
  python3 - "$WORK" <<'PY'
import base64, json, sys
work = sys.argv[1]
env = json.load(open(f"{work}/envelope.json"))
payload = base64.b64decode(env["payload"])
t = env["payloadType"].encode()
open(f"{work}/pae.bin", "wb").write(b"DSSEv1 %d %s %d " % (len(t), t, len(payload)) + payload)
open(f"{work}/sig.der", "wb").write(base64.b64decode(env["signatures"][0]["sig"]))
PY
  openssl dgst -sha256 -verify "$WORK/agent.pem" -signature "$WORK/sig.der" "$WORK/pae.bin" || { echo "FAIL: OpenSSL does not verify the agent's signature"; exit 1; }
fi
# Archived to the bucket once signed: the run's log is there, as written.
for _ in $(seq 1 30); do
  [ "$(curl -fsS -u admin:$PASS "$BASE/api/v1/runs/$RUN" | json run.archived)" = True ] && break
  sleep 1
done
[ "$(curl -fsS -u admin:$PASS "$BASE/api/v1/runs/$RUN" | json run.archived)" = True ] || { docker logs "$NET-testor" | tail -20; echo "FAIL: the run was not archived"; exit 1; }
ARCHIVED_LOG=$(cat "$WORK/s3/evidence/e2e/logs/$RUN.log" 2>/dev/null || sudo cat "$WORK/s3/evidence/e2e/logs/$RUN.log")
echo "$ARCHIVED_LOG" | grep -q "hello from a pod" || { echo "FAIL: the archived log is not the run's"; exit 1; }
[ -n "$(ls "$WORK/s3/evidence/e2e/attestations/" 2>/dev/null || sudo ls "$WORK/s3/evidence/e2e/attestations/")" ] || { echo "FAIL: the attestations were not archived"; exit 1; }
echo "ok: a job ran in an agent container, its run reached testor, signed by the agent, and was archived to S3"
