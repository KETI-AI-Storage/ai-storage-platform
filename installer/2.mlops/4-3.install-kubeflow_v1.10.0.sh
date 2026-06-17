#!/bin/bash

set -e

KUBEFLOW_VERSION="v1.10.0"

echo "[1/3] Cloning Kubeflow manifests repository (branch/tag: $KUBEFLOW_VERSION)..."
if [ -d "./tmp/kubeflow-manifests" ]; then
  echo "→ ./tmp/kubeflow-manifests already exists, skipping clone."
else
  git clone --branch "$KUBEFLOW_VERSION" --depth 1 "https://github.com/kubeflow/manifests.git" "./tmp/kubeflow-manifests"
fi

echo "[2/3] Moving into ./tmp/kubeflow-manifests"
cd "./tmp/kubeflow-manifests"

echo "[3/3] Installing Kubeflow resources with kustomize (this may take a while)..."
while ! kustomize build example | kubectl apply --server-side --force-conflicts -f -; do
  echo "[WARN] Apply failed. Retrying in 20 seconds..."
  sleep 20
done

echo "[INFO] Kubeflow manifests ($KUBEFLOW_VERSION) applied successfully!"
