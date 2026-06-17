#!/bin/bash

set -e

echo "[1/5] Enabling kernel modules: overlay, br_netfilter..."
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf > /dev/null
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

echo "[2/5] Setting sysctl parameters for Kubernetes networking..."
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf > /dev/null
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

echo "[3/5] Applying sysctl parameters without reboot..."
sudo sysctl --system

echo "[4/5] Opening Kubernetes API port 6443 (iptables)..."
sudo iptables -C INPUT -p tcp --dport 6443 -j ACCEPT 2>/dev/null || \
sudo iptables -A INPUT -p tcp --dport 6443 -j ACCEPT

echo "[5/5] Kernel and sysctl settings complete."