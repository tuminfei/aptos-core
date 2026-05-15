#!/bin/bash

set -euo pipefail

CLUSTER_NAME=${CLUSTER_NAME:-aptos-local}

if command -v k3d >/dev/null 2>&1; then
  k3d cluster delete "${CLUSTER_NAME}" || true
else
  echo "k3d is not installed"
fi
