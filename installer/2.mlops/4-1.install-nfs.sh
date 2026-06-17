#!/bin/bash

set -e

ROLE="$1"
DEFAULT_NFS_PATH="/mnt/nfs-volume"
NFS_PATH="$DEFAULT_NFS_PATH"

while [[ "$ROLE" != "server" && "$ROLE" != "client" ]]; do
  echo -n "enter role (server or client): "
  read ROLE
done

if [ "$ROLE" = "server" ]; then
  echo "Current NFS PATH is: $NFS_PATH"
  read -p "Do you want to proceed with this path? (y/n): " CONFIRM

  while [[ "$CONFIRM" != "y" && "$CONFIRM" != "n" ]]; do
    read -p "Please enter 'y' or 'n': " CONFIRM
  done

  if [ "$CONFIRM" = "n" ]; then
    read -p "Enter a new NFS shared path (e.g., /mnt/nfs-data): " NEW_PATH
    NFS_PATH="$NEW_PATH"
    echo "[INFO] NFS path has been set to: $NFS_PATH"
  fi

  echo "[1/5] Installing NFS server on Storage Server node..."
  sudo apt update
  sudo apt install -y nfs-kernel-server

  echo "[2/5] Creating shared directory at $NFS_PATH..."
  sudo mkdir -p "$NFS_PATH"
  sudo chmod 755 "$NFS_PATH"

  echo "[3/5] Configuring /etc/exports..."
  EXPORT_LINE="$NFS_PATH *(rw,insecure,sync,no_subtree_check,no_root_squash)"
  if ! grep -q "^$NFS_PATH" /etc/exports; then
    echo "$EXPORT_LINE" | sudo tee -a /etc/exports
  fi

  echo "[4/5] Restarting NFS server..."
  sudo exportfs -ra
  sudo systemctl restart nfs-kernel-server.service

  echo "[5/5] NFS server setup complete on Storage Server node."
  echo "Exported directory: $NFS_PATH"
  echo "Current exports:"
  sudo exportfs -v

  echo "[INFO] NFS server is ready."

elif [ "$ROLE" = "client" ]; then
  echo "[1/1] Installing NFS client on Client node..."
  sudo apt update
  sudo apt install -y nfs-common

  echo "[INFO] NFS client installed on Client node."

else
  echo "[ERROR] Argument must be 'server' or 'client'."
  exit 1
fi
