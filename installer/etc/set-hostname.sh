#!/bin/bash

if [ -z "$1" ] || [ -z "$2" ]; then
  echo "Usage: $0 <ip-address> <hostname>"
  exit 1
fi

IP="$1"
NEW_HOSTNAME="$2"

echo "[INFO] Setting hostname to '$NEW_HOSTNAME'..."
hostnamectl set-hostname "$NEW_HOSTNAME"

# /etc/hosts 에 IP와 호스트명 추가
echo "$IP    $NEW_HOSTNAME" | sudo tee -a /etc/hosts > /dev/null

# 127.0.1.1 라인에 기존 호스트명을 NEW_HOSTNAME 으로 교체
sudo sed -i "s/^127\.0\.1\.1\s\+.*/127.0.1.1\t$NEW_HOSTNAME/" /etc/hosts

echo "'''"
cat /etc/hosts
echo "'''"

echo "[INFO] Updated /etc/hosts with:"
echo "       $IP    $NEW_HOSTNAME"
echo "       127.0.1.1    $NEW_HOSTNAME"
echo "[INFO] Hostname is now set to '$NEW_HOSTNAME'"
echo "[INFO] Please reopen your terminal!"
