#!/bin/bash

set -e

if [ -z "$1" ]; then
  echo "Usage: $0 <ServerIP>"
  exit 1
fi

SERVER_IP="$1"

# Confirm user intends to initialize master
read -p "Do you want to initialize this node as the Kubernetes master? (y/N): " confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
  echo "Master initialization canceled."
  exit 1
fi

echo "Starting Kubernetes master node initialization..."

echo "[1/5] Running kubeadm init..."
sudo kubeadm init --apiserver-advertise-address="$SERVER_IP" --pod-network-cidr=10.244.0.0/16

echo "[2/5] Setting up kubeconfig..."
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

echo "[3/5] Installing Flannel CNI..."
kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml

echo "[4/5] Optional: remove master node taint if you want to schedule pods here:"
echo "       Run the following command:"
echo "       kubectl taint nodes --all node-role.kubernetes.io/control-plane-"

echo "[5/5] Kubernetes master node has been successfully initialized!"
