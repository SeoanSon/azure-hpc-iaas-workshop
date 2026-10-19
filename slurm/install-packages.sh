#!/usr/bin/env bash
set -euo pipefail

sudo apt-get update
sudo apt-get install -y munge slurm-wlm openmpi-bin openmpi-common libopenmpi-dev
sudo systemctl enable --now munge

echo "Packages installed. Configure the shared Munge key and slurm.conf before starting Slurm daemons."
