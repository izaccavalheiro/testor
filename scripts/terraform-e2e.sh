#!/usr/bin/env bash
# The Terraform module end to end: a kind cluster, `terraform apply` of
# deploy/terraform/examples/minimal with the chart in this checkout and the image just built,
# testor's health through a port-forward, no secret value in the state, `terraform destroy`.
#
#   scripts/terraform-e2e.sh <testor image, name:tag>
set -euo pipefail
IMAGE=${1:-testor:ci}
REPO=$(cd "$(dirname "$0")/.." && pwd)
CLUSTER=testor-tf-$$
KIND_VERSION=v0.33.0
KIND_SHA256=aee6151561422756b764a4ae28e7f44cda5af5a9eead3cc9985112b1de8d8e0d
TERRAFORM=hashicorp/terraform@sha256:6e9c1e647c31a960dc9b59e13272f9111d90010c10b717f77ffb324767660475 # 1.17.2
WORK=$(mktemp -d)
# A value that must never reach the state: the admin password is only a Secret's name there.
SECRET="tf-e2e-$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"
PF=""
cleanup() {
  [ -n "$PF" ] && kill "$PF" 2>/dev/null || true
  "$WORK/kind" delete cluster --name "$CLUSTER" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

curl -fsSL -o "$WORK/kind" "https://github.com/kubernetes-sigs/kind/releases/download/$KIND_VERSION/kind-linux-amd64"
echo "$KIND_SHA256  $WORK/kind" | sha256sum -c -
chmod +x "$WORK/kind"
"$WORK/kind" create cluster --name "$CLUSTER" --kubeconfig "$WORK/kubeconfig" --wait 180s
"$WORK/kind" load docker-image "$IMAGE" --name "$CLUSTER"
export KUBECONFIG="$WORK/kubeconfig"

kubectl create namespace testor
kubectl -n testor create secret generic testor-admin --from-literal=password="$SECRET"

repository=${IMAGE%%:*}
tag=${IMAGE##*:}
tf() {
  docker run --rm --network host -u "$(id -u):$(id -g)" -e HOME=/tmp \
    -e TF_IN_AUTOMATION=1 -e TF_VAR_kubeconfig=/work/kubeconfig \
    -v "$REPO:/repo" -v "$WORK:/work" -w /repo/deploy/terraform/examples/minimal \
    -e TF_DATA_DIR=/work/.terraform "$TERRAFORM" "$@"
}
vars=(-var chart_path=/repo/deploy/helm/testor
  -var "image={repository=\"$repository\",tag=\"$tag\",pullPolicy=\"Never\"}"
  -state=/work/terraform.tfstate)

tf init -backend=false -input=false -lockfile=readonly
tf apply -auto-approve -input=false "${vars[@]}"

kubectl -n testor rollout status deployment/testor --timeout=180s
kubectl -n testor port-forward svc/testor 16767:6767 >"$WORK/pf.log" 2>&1 &
PF=$!
for i in $(seq 1 30); do
  if curl -fsS http://127.0.0.1:16767/api/health; then echo; break; fi
  [ "$i" = 30 ] && { kubectl -n testor logs deployment/testor --tail=50; exit 1; }
  sleep 2
done

if tf show -json /work/terraform.tfstate | grep -q "$SECRET"; then
  echo "::error::a secret value is in the Terraform state"
  exit 1
fi
echo "no secret value in the state"

tf destroy -auto-approve -input=false "${vars[@]}"
test -z "$(kubectl -n testor get deployment -o name)"
echo "applied, answered /api/health, destroyed"
