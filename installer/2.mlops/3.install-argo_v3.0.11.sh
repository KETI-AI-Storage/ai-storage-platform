!/bin/bash
set -e

echo "[1/2] Creating Argo CD namespace..."
if ! kubectl get namespace argocd >/dev/null 2>&1; then
  kubectl create namespace argocd
else
  echo "→ Namespace 'argocd' already exists, skipping."
fi

echo "[2/2] Installing Argo CD manifests (stable)..."
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.0.11/manifests/install.yaml

echo "[INFO] Argo CD installation complete!"