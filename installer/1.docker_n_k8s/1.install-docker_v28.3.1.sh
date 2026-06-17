#!/bin/bash

set -e

DOCKER_VERSION="5:28.3.1-1~ubuntu.$(lsb_release -rs)~$(lsb_release -cs)"

echo "[1/7] Updating package index..."
sudo apt-get update

echo "[2/7] Installing dependencies..."
sudo apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release

echo "[3/7] Adding Docker's official GPG key..."
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

echo "[4/7] Adding Docker APT repository..."
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

echo "[5/7] Updating package index after adding Docker repo..."
sudo apt-get update

echo "[6/7] Installing Docker (version $DOCKER_VERSION)..."
sudo apt-get install -y \
  docker-ce="$DOCKER_VERSION" \
  docker-ce-cli="$DOCKER_VERSION" \
  containerd.io \
  docker-buildx-plugin \
  docker-compose-plugin

echo "[7/7] Enabling and starting Docker service..."
sudo systemctl enable docker
sudo systemctl start docker

echo ""
echo "Docker installation complete!"
docker --version
systemctl status docker | grep Active
