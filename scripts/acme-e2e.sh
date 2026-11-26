#!/usr/bin/env bash
# ACME end to end against Pebble, Let's Encrypt's test CA: testor orders a certificate for
# testor.test over HTTP-01 (Pebble's VA resolves the name through pebble-challtestsrv to
# testor's container), serves it on its HTTPS port, and renews it (Pebble issues 90-second
# certificates here) with the new serial served while the container keeps running.
#
#   scripts/acme-e2e.sh <testor image>
set -euo pipefail
TESTOR=${1:-testor:ci}
NET=testor-acme-$$
SUBNET=172.31.250
PEBBLE=ghcr.io/letsencrypt/pebble@sha256:0c81f05db371f436c97fb894bd6d2ab8fc9c8e2ce40f8bef8a8e15941bcd75ef # 2.10.3
CHALLTESTSRV=ghcr.io/letsencrypt/pebble-challtestsrv@sha256:0152c8cb506e2ecba2900ed47d23932e27e3e6575a7d2c8ef93c7719ee3dea4c # 2.10.3
# Pebble's own TLS root (for its API), at the same release.
MINICA_URL=https://raw.githubusercontent.com/letsencrypt/pebble/v2.10.3/test/certs/pebble.minica.pem
MINICA_SHA256=0c502e52627ff7de972c7e9e065640103b4589b4e2d23d3fcf21bef1e3c8c67c
WORK=$(mktemp -d)
cleanup() {
  docker logs "$NET-testor" 2>&1 | grep -i acme | tail -20 || true
  docker rm -f "$NET-testor" "$NET-pebble" "$NET-dns" >/dev/null 2>&1 || true
  docker volume rm "$NET-home" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

curl -fsSL -o "$WORK/minica.pem" "$MINICA_URL"
echo "$MINICA_SHA256  $WORK/minica.pem" | sha256sum -c -

cat > "$WORK/pebble.json" <<'JSON'
{ "pebble": { "listenAddress": "0.0.0.0:14000", "managementListenAddress": "0.0.0.0:15000",
  "certificate": "test/certs/localhost/cert.pem", "privateKey": "test/certs/localhost/key.pem",
  "httpPort": 5002, "tlsPort": 5001, "ocspResponderURL": "", "externalAccountBindingRequired": false,
  "retryAfter": { "authz": 1, "order": 1 }, "keyAlgorithm": "ecdsa",
  "profiles": { "default": { "description": "short", "validityPeriod": 90 } } } }
JSON
chmod 644 "$WORK/pebble.json"

docker network create --subnet "$SUBNET.0/24" "$NET" >/dev/null
docker run -d --name "$NET-dns" --network "$NET" --ip "$SUBNET.3" "$CHALLTESTSRV" \
  -defaultIPv4 "$SUBNET.10" -defaultIPv6 "" >/dev/null
docker run -d --name "$NET-pebble" --network "$NET" --ip "$SUBNET.4" --network-alias pebble -p 127.0.0.1::15000 \
  -e PEBBLE_VA_NOSLEEP=1 -v "$WORK/pebble.json:/pebble.json:ro" "$PEBBLE" \
  -config /pebble.json -dnsserver "$SUBNET.3:8053" >/dev/null

MGMT=$(docker port "$NET-pebble" 15000/tcp | head -1 | sed 's/.*://')
for _ in $(seq 1 30); do curl -fsSk "https://127.0.0.1:$MGMT/roots/0" -o "$WORK/root.pem" && break; sleep 1; done
cat "$WORK/minica.pem" "$WORK/root.pem" > "$WORK/bundle.pem"

# testor's home, with tls.acme and the bundle, owned by the image's user.
docker volume create "$NET-home" >/dev/null
docker run --rm --user root --entrypoint sh -v "$NET-home:/data" -v "$WORK:/in:ro" "$TESTOR" -c '
  mkdir -p /data/workspaces/.testor && cp /in/bundle.pem /data/workspaces/.testor/acme-bundle.pem
  cat > /data/workspaces/.testor/config.json <<JSON
{"tls": {"acme": {"directory": "https://pebble:14000/dir", "domains": ["testor.test"],
  "caBundle": "/data/workspaces/.testor/acme-bundle.pem", "httpPort": 5002, "email": "ci@testor.test"}}}
JSON
  chown -R 10001:10001 /data'

docker run -d --name "$NET-testor" --network "$NET" --ip "$SUBNET.10" -p 127.0.0.1::6767 \
  -e TESTOR_ALLOWED_HOSTS=testor.test -v "$NET-home:/data" --read-only --tmpfs /tmp \
  --cap-drop ALL --security-opt no-new-privileges "$TESTOR" >/dev/null
PORT=$(docker port "$NET-testor" 6767/tcp | head -1 | sed 's/.*://')

serial() {
  openssl s_client -connect "127.0.0.1:$PORT" -servername testor.test -CAfile "$WORK/root.pem" \
    -verify_return_error </dev/null 2>/dev/null | openssl x509 -noout -serial 2>/dev/null | cut -d= -f2
}

first=""
for _ in $(seq 1 60); do
  first=$(serial || true)
  [ -n "$first" ] && break
  sleep 2
done
[ -n "$first" ] || { echo "::error::no certificate from Pebble was served"; exit 1; }
echo "served $first"
curl -fsS --cacert "$WORK/root.pem" --resolve "testor.test:$PORT:127.0.0.1" "https://testor.test:$PORT/api/health"
echo

# Renewed at two thirds of 90 s (or in Pebble's renewal window): a new serial, same container.
started=$(docker inspect -f '{{.State.StartedAt}}' "$NET-testor")
second=""
for _ in $(seq 1 90); do
  second=$(serial || true)
  [ -n "$second" ] && [ "$second" != "$first" ] && break
  sleep 2
done
[ -n "$second" ] && [ "$second" != "$first" ] || { echo "::error::the certificate was not renewed"; exit 1; }
[ "$(docker inspect -f '{{.State.StartedAt}}' "$NET-testor")" = "$started" ] || { echo "::error::testor restarted"; exit 1; }
[ "$(docker inspect -f '{{.RestartCount}}' "$NET-testor")" = 0 ]
echo "renewed: $first -> $second, served without a restart"
