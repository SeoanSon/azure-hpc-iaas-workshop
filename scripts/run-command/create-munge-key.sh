#!/usr/bin/env bash
set -euo pipefail

create-munge-key -f
chown munge:munge /etc/munge/munge.key
chmod 0400 /etc/munge/munge.key
install -o munge -g munge -m 0400 \
  /etc/munge/munge.key /srv/hpc/.munge-key
systemctl restart munge
systemctl is-active --quiet munge
