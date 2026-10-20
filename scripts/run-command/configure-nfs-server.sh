#!/usr/bin/env bash
set -euo pipefail

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y nfs-kernel-server git

install -d -o azureuser -g azureuser -m 0775 /srv/hpc
printf '/srv/hpc 10.0.0.0/24(rw,sync,no_subtree_check)\n' \
  > /etc/exports.d/hpc-workshop.exports
exportfs -rav
systemctl enable --now nfs-kernel-server

install -d -m 0775 /mnt/hpc
if ! grep -qE '^[[:space:]]*headnode:/srv/hpc[[:space:]]+/mnt/hpc[[:space:]]+nfs4([[:space:]]|$)' /etc/fstab; then
  printf 'headnode:/srv/hpc /mnt/hpc nfs4 vers=4.1,_netdev,nofail 0 0\n' \
    >> /etc/fstab
fi
if ! mountpoint -q /mnt/hpc; then
  mount /mnt/hpc
fi

if [[ ! -d /srv/hpc/workshop/.git ]]; then
  runuser -u azureuser -- git clone --depth 1 \
    https://github.com/SeoanSon/azure-hpc-iaas-workshop.git \
    /srv/hpc/workshop
fi
