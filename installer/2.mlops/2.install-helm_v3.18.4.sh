#!/bin/bash
set -e

VERSION="v3.18.4"

echo "[1/5] Preparing temporary directory..."
mkdir -p "tmp"

echo "[2/5] Downloading Helm $VERSION..."
wget -q --show-progress -O "./tmp/helm-${VERSION}-linux-amd64.tar.gz" "https://get.helm.sh/helm-${VERSION}-linux-amd64.tar.gz"

echo "[3/5] Extracting archive..."
tar -zxvf "./tmp/helm-${VERSION}-linux-amd64.tar.gz" -C "./tmp"

echo "[4/5] Installing Helm to /usr/local/bin/helm..."
sudo mv "./tmp/linux-amd64/helm" /usr/local/bin/helm
sudo chmod +x /usr/local/bin/helm

echo "[5/5] Verifying installation..."
helm version
