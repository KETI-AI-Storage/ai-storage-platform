#!/bin/bash

set -e

VERSION="5.4.3"

echo "[1/4] Downloading Kustomize v${VERSION}..."
wget -q --show-progress -O "./tmp/kustomize_v${VERSION}_linux_amd64.tar.gz" \
  "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize/v${VERSION}/kustomize_v${VERSION}_linux_amd64.tar.gz"

echo "[2/4] Extracting the archive..."
tar -zxvf ./tmp/kustomize_v${VERSION}_linux_amd64.tar.gz -C ./tmp

echo "[3/4] Moving binary to /usr/local/bin..."
sudo mv ./tmp/kustomize /usr/local/bin/kustomize

echo "[4/4] Verifying installation..."
kustomize version

echo ""
echo "[INFO] Kustomize v${VERSION} installation complete!"