#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
REPO_ROOT=$(cd -- "${SCRIPT_DIR}/../.." &>/dev/null && pwd)

CLUSTER_NAME=${CLUSTER_NAME:-aptos-local}
NAMESPACE=${NAMESPACE:-aptos-local}
KUBECONTEXT="k3d-${CLUSTER_NAME}"

for tool in docker k3d kubectl helm; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Missing required tool: $tool"
    exit 1
  fi
done

if ! k3d cluster list | awk '{print $1}' | grep -qx "${CLUSTER_NAME}"; then
  k3d cluster create "${CLUSTER_NAME}" \
    --agents 3 \
    --servers 1 \
    --k3s-arg "--disable=traefik@server:0" \
    --wait
fi

KUBECONFIG_FILE=$(k3d kubeconfig write "${CLUSTER_NAME}")
export KUBECONFIG="${KUBECONFIG_FILE}"

kubectl config use-context "${KUBECONTEXT}" >/dev/null

kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1 || kubectl create namespace "${NAMESPACE}"

helm upgrade --install aptos-local \
  "${REPO_ROOT}/terraform/helm/aptos-node" \
  --namespace "${NAMESPACE}" \
  -f "${SCRIPT_DIR}/k3d-aptos-node-values.yaml" \
  --wait=false

helm upgrade --install genesis \
  "${REPO_ROOT}/terraform/helm/genesis" \
  --namespace "${NAMESPACE}" \
  -f "${SCRIPT_DIR}/k3d-genesis-values.yaml" \
  --wait=false

kubectl -n "${NAMESPACE}" wait --for=condition=complete job/genesis-aptos-genesis-e1 --timeout=15m

kubectl -n "${NAMESPACE}" rollout status statefulset/aptos-local-aptos-node-0-validator --timeout=20m
kubectl -n "${NAMESPACE}" rollout status statefulset/aptos-local-aptos-node-1-validator --timeout=20m
kubectl -n "${NAMESPACE}" rollout status statefulset/aptos-local-aptos-node-2-validator --timeout=20m
kubectl -n "${NAMESPACE}" rollout status statefulset/aptos-local-aptos-node-3-validator --timeout=20m

kubectl -n "${NAMESPACE}" rollout status statefulset/aptos-local-aptos-node-0-fullnode-e1 --timeout=20m
kubectl -n "${NAMESPACE}" rollout status statefulset/aptos-local-aptos-node-1-fullnode-e1 --timeout=20m
kubectl -n "${NAMESPACE}" rollout status statefulset/aptos-local-aptos-node-2-fullnode-e1 --timeout=20m
kubectl -n "${NAMESPACE}" rollout status statefulset/aptos-local-aptos-node-3-fullnode-e1 --timeout=20m

kubectl -n "${NAMESPACE}" get pods
kubectl -n "${NAMESPACE}" get svc
