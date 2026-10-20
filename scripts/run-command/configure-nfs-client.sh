#!/usr/bin/env bash
set -euo pipefail

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y nfs-common
install -d -m 0775 /mnt/hpc

if ! grep -qE '^[[:space:]]*headnode:/srv/hpc[[:space:]]+/mnt/hpc[[:space:]]+nfs4([[:space:]]|$)' /etc/fstab; then
  printf 'headnode:/srv/hpc /mnt/hpc nfs4 vers=4.1,_netdev,nofail 0 0\n' \
    >> /etc/fstab
fi

if ! mountpoint -q /mnt/hpc; then
  mount /mnt/hpc
fi
