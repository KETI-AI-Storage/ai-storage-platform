#!/bin/bash

set -e

read -p "Enter NFS server IP address: " nfs_server
read -p "Enter NFS shared directory path (e.g., /mnt/nfs-volume): " nfs_dir_path

echo ""
echo "You entered:"
echo "  NFS Server IP : $nfs_server"
echo "  NFS Directory  : $nfs_dir_path"
read -p "Is this correct? (y/n): " confirm
if [[ "$confirm" != "y" ]]; then
  echo "[ABORTED] Installation cancelled by user."
  exit 1
fi

echo "[1/5] Creating namespace 'nfs-provisioner'..."
kubectl create namespace nfs-provisioner --dry-run=client -o yaml | kubectl apply -f -

echo "[2/5] Adding Helm repository..."
helm repo add nfs-subdir-external-provisioner https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner/
helm repo update

echo "[3/5] Installing NFS provisioner with Helm..."
helm install -n nfs-provisioner nfs-subdir-external-provisioner \
  nfs-subdir-external-provisioner/nfs-subdir-external-provisioner \
  --version 4.0.18 \
  --set nfs.server="$nfs_server" \
  --set nfs.path="$nfs_dir_path" \
  --set storageClass.defaultClass=true

echo "[4/5] Waiting for NFS provisioner pod to become ready..."
kubectl wait --namespace nfs-provisioner \
  --for=condition=Available deployment/nfs-subdir-external-provisioner \
  --timeout=60s

echo "[5/5] Deployed pods:"
kubectl get pods -n nfs-provisioner

echo "      StorageClasses:"
kubectl get storageclass

echo "[INFO] NFS Provisioner successfully installed and ready."