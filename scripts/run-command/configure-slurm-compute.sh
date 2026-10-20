#!/usr/bin/env bash
set -euo pipefail

install -D -o root -g root -m 0644 \
  /mnt/hpc/workshop/slurm/slurm.conf /etc/slurm/slurm.conf
install -d -o root -g root /var/lib/slurm/slurmd
systemctl enable munge slurmd
systemctl restart munge
systemctl restart slurmd
systemctl is-active --quiet slurmd
