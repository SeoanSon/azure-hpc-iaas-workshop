#!/usr/bin/env bash
set -euo pipefail

install -D -o root -g root -m 0644 \
  /mnt/hpc/workshop/slurm/slurm.conf /etc/slurm/slurm.conf
install -d -o slurm -g slurm /var/lib/slurm/slurmctld
systemctl enable munge slurmctld
systemctl restart munge
systemctl restart slurmctld
systemctl is-active --quiet slurmctld
