#!/usr/bin/env bash
set -euo pipefail

cat > /srv/hpc/hello.slurm <<'EOF'
#!/usr/bin/env bash
#SBATCH --job-name=mpi-hostnames
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=2
#SBATCH --time=00:05:00
#SBATCH --chdir=/mnt/hpc
#SBATCH --output=/mnt/hpc/hello-%j.out
#SBATCH --partition=compute

mpirun -np "$SLURM_NTASKS" hostname
EOF

chown azureuser:azureuser /srv/hpc/hello.slurm
chmod 0644 /srv/hpc/hello.slurm
runuser -u azureuser -- sbatch /mnt/hpc/hello.slurm
