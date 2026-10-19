#!/usr/bin/env bash
set -euo pipefail

cat > hello.slurm <<'EOF'
#!/usr/bin/env bash
#SBATCH --job-name=mpi-hostnames
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=2
#SBATCH --time=00:05:00
#SBATCH --output=hello-%j.out
#SBATCH --partition=compute

mpirun -np "$SLURM_NTASKS" hostname
EOF

sbatch hello.slurm
