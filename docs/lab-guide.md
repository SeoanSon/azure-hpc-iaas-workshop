# Azure IaaS HPC 단계별 실습 가이드

이 가이드는 Azure VM 3대(head 1대, compute 2대)에 NFS, Slurm, OpenMPI를 구성하고 샘플 작업을 실행합니다. 별도 설치 스크립트를 추가로 만들지 않고, 저장소의 배포 스크립트와 설정 파일을 사용합니다.

## 실습 구성

`scripts/azure-setup.sh`가 만드는 VMSS는 규모 변경을 관찰하는 용도입니다. Slurm은 고정 이름 `headnode`, `compute01`, `compute02`를 사용하므로 VMSS 인스턴스를 Slurm에 연결하지 않습니다. VMSS 관찰을 마친 뒤 인스턴스 수를 0으로 줄이고 고정 노드 2대를 만듭니다. 이 순서로 진행하면 head 1대와 compute 2대만 유지합니다.

모든 세 노드는 `Standard_D8s_v5`, Ubuntu 22.04, 같은 사용자 이름과 같은 `/mnt/hpc` 공유 경로를 사용합니다. 이 가이드는 실습/교육용이며 운영 클러스터 설정이 아닙니다.

## 0. 시작 전 준비

로컬 컴퓨터에서 다음이 준비되어 있는지 확인합니다.

- Bash (예: WSL 또는 Git Bash), Azure CLI, `az login` 완료
- 대상 구독 선택: `az account show --output table`
- Azure 리소스 그룹 생성 권한 및 지역의 `Standard_D8s_v5` 코어 quota/용량
- SSH 키 쌍. 기본 경로는 `$HOME/.ssh/id_rsa` 및 `$HOME/.ssh/id_rsa.pub`
- SSH를 허용할 신뢰 가능한 공인 IP/CIDR. 인터넷 전체를 뜻하는 `0.0.0.0/0`은 사용하지 않습니다.

예상 VM 용량은 VMSS를 관찰하는 동안 head 1대 + VMSS 2대, 고정 노드 실습 중 head 1대 + compute 2대입니다. VMSS 인스턴스를 0으로 줄이기 전에는 고정 노드 VM을 만들지 마세요. VM/디스크/네트워크 사용에 Azure 요금이 발생합니다.

로컬 컴퓨터의 Bash에서 저장소 루트로 이동한 다음 변수를 설정합니다. `SSH_SOURCE_CIDR`을 실제 공인 IP/CIDR로 바꿉니다.

```bash
set -euo pipefail
export RG=rg-hpc-workshop
export LOC=eastus
export VNET=vnet-hpc
export SUBNET=subnet-hpc
export NSG=nsg-hpc
export HEAD=headnode
export VMSS=hpc-compute
export ADMIN_USERNAME=azureuser
export VM_SIZE=Standard_D8s_v5
export SSH_PUBLIC_KEY="$HOME/.ssh/id_rsa.pub"
export SSH_PRIVATE_KEY="$HOME/.ssh/id_rsa"
export SSH_SOURCE_CIDR="203.0.113.10/32" # 실제 공인 IP/CIDR로 변경

test -f "$SSH_PUBLIC_KEY" && test -f "$SSH_PRIVATE_KEY"
az account show --output table
```

뒤 단계에서도 이 로컬 Bash의 변수들을 사용하므로 터미널을 닫지 마세요. VM에 접속해 명령을 실행한 뒤 `exit`를 입력하면 로컬 터미널로 돌아옵니다.

## 1. Azure 인프라 만들기

로컬 컴퓨터에서 저장소 루트에 있는지 확인하고 배포 스크립트를 실행합니다.

```bash
bash scripts/azure-setup.sh
```

**정상 결과:** 리소스 그룹 `rg-hpc-workshop`, VM `headnode`, VMSS `hpc-compute`가 생성됩니다. 리소스 생성이 실패하면 먼저 Azure Portal의 구독 quota, 선택한 지역의 SKU 용량, Azure CLI 로그인 구독을 확인합니다.

VMSS 규모 변경을 관찰한 뒤 반드시 0으로 줄입니다.

```bash
az vm list --resource-group "$RG" --output table
az vmss list-instances --resource-group "$RG" --name "$VMSS" --output table
az vmss scale --resource-group "$RG" --name "$VMSS" --new-capacity 3
az vmss list-instances --resource-group "$RG" --name "$VMSS" --output table
az vmss scale --resource-group "$RG" --name "$VMSS" --new-capacity 0
az vmss list-instances --resource-group "$RG" --name "$VMSS" --output table
```

**확인:** 마지막 명령에 실행 중인 VMSS 인스턴스가 없어야 합니다. 이후 실습은 고정 이름의 VM 두 대를 사용합니다.

## 2. 고정 compute VM 만들기

로컬 컴퓨터에서 공인 IP와 사설 IP를 확인합니다.

```bash
HEAD_PUBLIC_IP=$(az vm show --show-details --resource-group "$RG" --name "$HEAD" --query publicIps --output tsv)
HEAD_PRIVATE_IP=$(az vm list-ip-addresses --resource-group "$RG" --name "$HEAD" --query '[0].virtualMachine.network.privateIpAddresses[0]' --output tsv)
printf 'Head public IP: %s\nHead private IP: %s\n' "$HEAD_PUBLIC_IP" "$HEAD_PRIVATE_IP"
```

공인 IP는 head VM에만 사용합니다. compute VM 두 대에는 공인 IP를 만들지 않습니다.

```bash
for node in compute01 compute02; do
  az vm create \
    --resource-group "$RG" --name "$node" \
    --image Ubuntu2204 --size "$VM_SIZE" \
    --admin-username "$ADMIN_USERNAME" \
    --ssh-key-values "$SSH_PUBLIC_KEY" \
    --vnet-name "$VNET" --subnet "$SUBNET" \
    --public-ip-address "" \
    --output none
done

COMPUTE01_PRIVATE_IP=$(az vm list-ip-addresses --resource-group "$RG" --name compute01 --query '[0].virtualMachine.network.privateIpAddresses[0]' --output tsv)
COMPUTE02_PRIVATE_IP=$(az vm list-ip-addresses --resource-group "$RG" --name compute02 --query '[0].virtualMachine.network.privateIpAddresses[0]' --output tsv)
printf 'headnode=%s\ncompute01=%s\ncompute02=%s\n' "$HEAD_PRIVATE_IP" "$COMPUTE01_PRIVATE_IP" "$COMPUTE02_PRIVATE_IP"
```

위 출력에서 IP 세 개가 비어 있지 않은지 확인합니다. 로컬 컴퓨터에서 `/etc/hosts` 내용을 각 VM에 추가해 이름을 고정합니다.

```bash
HOSTS_BLOCK=$(printf '%s\n' \
  "$HEAD_PRIVATE_IP headnode" \
  "$COMPUTE01_PRIVATE_IP compute01" \
  "$COMPUTE02_PRIVATE_IP compute02")

# cloud-init의 loopback 별칭을 제거해 사설 IP 매핑이 우선하도록 합니다.
ssh -i "$SSH_PRIVATE_KEY" "$ADMIN_USERNAME@$HEAD_PUBLIC_IP" \
  "sudo sed -i -E '/[[:space:]](headnode|compute01|compute02)([[:space:]]|$)/d' /etc/hosts"
printf '%s\n' "$HOSTS_BLOCK" |
  ssh -i "$SSH_PRIVATE_KEY" "$ADMIN_USERNAME@$HEAD_PUBLIC_IP" \
  'sudo tee -a /etc/hosts >/dev/null'
ssh -i "$SSH_PRIVATE_KEY" -J "$ADMIN_USERNAME@$HEAD_PUBLIC_IP" \
  "$ADMIN_USERNAME@$COMPUTE01_PRIVATE_IP" \
  "sudo sed -i -E '/[[:space:]](headnode|compute01|compute02)([[:space:]]|$)/d' /etc/hosts"
printf '%s\n' "$HOSTS_BLOCK" |
  ssh -i "$SSH_PRIVATE_KEY" -J "$ADMIN_USERNAME@$HEAD_PUBLIC_IP" \
  "$ADMIN_USERNAME@$COMPUTE01_PRIVATE_IP" 'sudo tee -a /etc/hosts >/dev/null'
ssh -i "$SSH_PRIVATE_KEY" -J "$ADMIN_USERNAME@$HEAD_PUBLIC_IP" \
  "$ADMIN_USERNAME@$COMPUTE02_PRIVATE_IP" \
  "sudo sed -i -E '/[[:space:]](headnode|compute01|compute02)([[:space:]]|$)/d' /etc/hosts"
printf '%s\n' "$HOSTS_BLOCK" |
  ssh -i "$SSH_PRIVATE_KEY" -J "$ADMIN_USERNAME@$HEAD_PUBLIC_IP" \
  "$ADMIN_USERNAME@$COMPUTE02_PRIVATE_IP" 'sudo tee -a /etc/hosts >/dev/null'
```

**확인:** 세 VM에 SSH 접속해 `getent hosts headnode compute01 compute02`를 실행합니다. 각 이름이 위에서 확인한 올바른 사설 IP로 해석되어야 합니다. SSH 접속은 아래처럼 head를 경유합니다.

```bash
ssh -i "$SSH_PRIVATE_KEY" "$ADMIN_USERNAME@$HEAD_PUBLIC_IP"
ssh -i "$SSH_PRIVATE_KEY" -J "$ADMIN_USERNAME@$HEAD_PUBLIC_IP" "$ADMIN_USERNAME@$COMPUTE01_PRIVATE_IP"
```

compute02에도 같은 방식으로 접속할 수 있습니다. 다음 단계에서 안내하는 `headnode`, `compute01`, `compute02` 명령은 해당 VM의 SSH 세션에서 실행합니다. 로컬 컴퓨터의 Azure CLI 명령과 혼동하지 마세요.

세 VM의 일반 사용자 UID/GID가 같아야 공유 파일 권한이 일치합니다. 각 VM에서 확인합니다.

```bash
id
```

## 3. NFS 공유 디렉터리 구성

### headnode에서 실행

head VM에 접속한 뒤 NFS 서버를 설치하고 실습 파일을 둘 디렉터리를 만듭니다.

```bash
sudo apt-get update
sudo apt-get install -y nfs-kernel-server git
sudo install -d -m 0775 /srv/hpc
sudo chown "$USER:$(id -gn)" /srv/hpc
printf '/srv/hpc 10.0.0.0/24(rw,sync,no_subtree_check)\n' |
  sudo tee /etc/exports.d/hpc-workshop.exports
sudo exportfs -rav
sudo systemctl enable --now nfs-kernel-server
sudo install -d -m 0775 /mnt/hpc
sudo mount -t nfs4 -o vers=4.1 headnode:/srv/hpc /mnt/hpc
```

`10.0.0.0/24`는 배포 스크립트의 subnet 범위입니다. 주소 범위를 변경했다면 위 exports 항목을 실제 subnet으로 바꿉니다. NFS는 이 VNet 안에서만 사용하고 인터넷에 노출하지 않습니다.

**확인:** `findmnt /mnt/hpc`에서 NFS 마운트를 확인합니다. 이 경로는 Slurm이 세 노드에서 작업 디렉터리로 사용하는 공유 경로입니다.

```bash
findmnt /mnt/hpc
touch /mnt/hpc/headnode-check
```

### compute01과 compute02 각각에서 실행

각 compute VM에 접속해 NFS client를 설치하고 head의 공유를 같은 경로에 마운트합니다.

```bash
sudo apt-get update
sudo apt-get install -y nfs-common
sudo install -d -m 0775 /mnt/hpc
sudo mount -t nfs4 -o vers=4.1 headnode:/srv/hpc /mnt/hpc
touch "/mnt/hpc/$(hostname)-check"
findmnt /mnt/hpc
```

다시 headnode에서 실행해 세 노드의 파일이 모두 보이는지 확인합니다.

```bash
ls -l /mnt/hpc/*-check
```

`headnode-check`, `compute01-check`, `compute02-check` 세 파일이 보여야 합니다. 파일이 보이지 않으면 먼저 `getent hosts headnode`, `sudo systemctl status nfs-kernel-server`, `sudo exportfs -v`와 각 노드의 `findmnt /mnt/hpc`를 확인합니다.

### headnode에서 실습 파일 가져오기

세 노드에서 동일하게 보이는 경로에 저장소를 clone합니다.

```bash
git clone https://github.com/SeoanSon/azure-hpc-iaas-workshop.git /mnt/hpc/workshop
```

이미 clone한 디렉터리가 있으면 `git -C /mnt/hpc/workshop pull`을 실행합니다.

## 4. Slurm 및 Munge 설치/설정

### 세 노드 모두에서 패키지 설치

headnode에서는 다음을 실행합니다.

```bash
sudo bash /mnt/hpc/workshop/slurm/install-packages.sh
```

compute01, compute02에서도 각각 같은 명령을 실행합니다. `munge`, `slurm-wlm`, OpenMPI 패키지가 설치되어야 합니다.

### Munge 인증 키 배포

headnode에서 Munge 키를 만들고 권한을 설정합니다.

```bash
sudo create-munge-key -f
sudo chown munge:munge /etc/munge/munge.key
sudo chmod 0400 /etc/munge/munge.key
sudo systemctl restart munge
sudo systemctl status --no-pager munge
```

로컬 컴퓨터의 Bash에서 다음을 실행해 같은 키를 SSH 암호화 연결로 compute 노드에 복사합니다. 키 내용을 화면에 출력하거나 저장소에 넣지 않습니다.

```bash
set -euo pipefail
for node_ip in "$COMPUTE01_PRIVATE_IP" "$COMPUTE02_PRIVATE_IP"; do
  ssh -i "$SSH_PRIVATE_KEY" "$ADMIN_USERNAME@$HEAD_PUBLIC_IP" \
    'sudo cat /etc/munge/munge.key' |
  ssh -i "$SSH_PRIVATE_KEY" -J "$ADMIN_USERNAME@$HEAD_PUBLIC_IP" \
    "$ADMIN_USERNAME@$node_ip" \
    'sudo sh -c "cat > /etc/munge/munge.key && chown munge:munge /etc/munge/munge.key && chmod 0400 /etc/munge/munge.key"'
done
```

각 compute 노드에서 서비스와 키 권한을 확인하고 Munge를 재시작합니다.

```bash
sudo systemctl restart munge
sudo systemctl status --no-pager munge
sudo stat -c '%U:%G %a %n' /etc/munge/munge.key
```

출력은 `munge:munge 400 /etc/munge/munge.key`여야 합니다.

### Slurm 설정 배포

headnode에서 실행합니다.

```bash
sudo install -D -o root -g root -m 0644 \
  /mnt/hpc/workshop/slurm/slurm.conf /etc/slurm/slurm.conf
sudo install -d -o slurm -g slurm /var/lib/slurm/slurmctld
sudo systemctl enable munge slurmctld
sudo systemctl restart munge
sudo systemctl restart slurmctld
```

compute01과 compute02 각각에서 실행합니다.

```bash
sudo install -D -o root -g root -m 0644 \
  /mnt/hpc/workshop/slurm/slurm.conf /etc/slurm/slurm.conf
sudo install -d -o root -g root /var/lib/slurm/slurmd
sudo systemctl enable munge slurmd
sudo systemctl restart munge
sudo systemctl restart slurmd
```

**확인:** headnode에서 다음 명령을 실행합니다.

```bash
munge -n | unmunge
scontrol ping
sinfo -N -l
srun --mpi=list
```

`scontrol ping`은 controller가 응답한다고 표시하고, `sinfo -N -l`은 `compute01`과 `compute02`를 `idle` 상태로 보여야 합니다. `srun --mpi=list` 결과에 `pmix`가 있어야 합니다. `down` 또는 `unknown`이면 이름 해석, Munge 키/시간, 각 compute의 `sudo systemctl status --no-pager munge slurmd`, `sudo journalctl -u slurmd --since today`를 확인합니다. Controller 로그는 headnode에서 `sudo journalctl -u slurmctld --since today`로 확인합니다.

## 5. Batch/MPI 작업 제출

headnode의 NFS 공유 경로에서 예제 작업을 제출합니다.

```bash
cd /mnt/hpc
bash /mnt/hpc/workshop/slurm/submit-job.sh
squeue
```

작업이 끝날 때까지 기다린 다음 결과를 확인합니다.

```bash
cat hello-*.out
```

**정상 결과:** 출력에 `compute01` 및 `compute02` 호스트 이름이 나타납니다. 대기 중이면 `sinfo -N -l`로 노드 상태를 확인하고, 실패하면 `scontrol show job <JOB_ID>`와 `sudo journalctl -u slurmctld --since today`를 확인합니다. `<JOB_ID>`는 `sbatch` 출력의 숫자로 바꿉니다.

## 6. 종료 및 리소스 삭제

실습 결과와 필요한 파일을 저장했는지 확인한 뒤, 로컬 컴퓨터에서 대상 리소스 그룹이 이 워크숍 전용인지 다시 확인합니다.

```bash
az vm list --resource-group "$RG" --output table
az vmss list --resource-group "$RG" --output table
```

이 리소스 그룹의 리소스를 모두 삭제해도 되는 경우에만 실행합니다. 삭제는 되돌릴 수 없습니다.

```bash
az group delete --name "$RG" --yes --no-wait
```

## 문제 해결 빠른 확인

| 증상 | 확인할 명령 |
| --- | --- |
| SSH 접속 거부/시간 초과 | 로컬에서 `az vm show --show-details -g "$RG" -n "$HEAD" --query powerState -o tsv`; `SSH_SOURCE_CIDR`가 현재 공인 IP인지 확인 |
| 호스트 이름을 찾지 못함 | 세 VM 모두에서 `getent hosts headnode compute01 compute02`; `/etc/hosts`의 사설 IP 확인 |
| NFS 마운트 실패 | compute에서 `showmount -e headnode`, head에서 `sudo exportfs -v`와 `sudo systemctl status nfs-kernel-server` 확인 |
| Munge 인증 실패 | 각 VM에서 `munge -n \| unmunge` 실행; `sudo sha256sum /etc/munge/munge.key` 결과가 세 VM에서 같은지 확인 |
| Slurm 노드가 `down` | head에서 `scontrol show node compute01`; 해당 compute에서 `sudo journalctl -u slurmd --since today` 확인 |
| 작업이 제출되지 않음 | head에서 `sinfo -N -l`, `squeue`, `sudo journalctl -u slurmctld --since today` 확인 |
