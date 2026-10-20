#!/usr/bin/env bash
set -euo pipefail

runuser -u munge -- cat /mnt/hpc/.munge-key > /etc/munge/munge.key
chown munge:munge /etc/munge/munge.key
chmod 0400 /etc/munge/munge.key
systemctl restart munge
systemctl is-active --quiet munge
