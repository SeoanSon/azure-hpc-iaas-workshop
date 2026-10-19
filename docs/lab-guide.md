# Azure IaaS HPC 단계별 실습 가이드

이 가이드는 저장소의 Azure 배포 스크립트와 고정 노드 Slurm 예제를 사용합니다. 모든 명령은 Azure CLI에 로그인한 실습용 계정에서 실행합니다.

## 실습 구성과 범위

실습은 서로 다른 두 구성을 사용합니다.

- **VMSS 관찰:** `scripts/azure-setup.sh`가 만드는 `hpc-compute` VM Scale Set의 인스턴스를 확인하고 규모를 바꿔 봅니다. 이 VMSS는 Slurm에 노드를 자동 등록하지 않습니다.
- **고정 노드 Slurm/MPI:** `headnode`, `compute01`, `compute02`라는 고정 이름을 가진 VM 세 대를 사용합니다. 저장소의 `slurm/slurm.conf`는 이 이름에 맞춰져 있으므로 VMSS 인스턴스를 Slurm compute 노드로 사용하지 않습니다.

공유 파일시스템은 자동 배포되지 않습니다. 아래 단계에서는 워크숍 전용 VNet 안에서 head VM의 NFS 공유를 구성합니다. 운영 환경에서는 워크로드와 성능 요구에 맞는 스토리지 서비스를 별도로 설계하세요.

## 0. 사전 확인

다음을 준비합니다.

- Azure CLI 설치 및 `az login` 완료
- 실습 전용 Azure 구독/리소스 그룹 권한
- SSH 공개 키와 개인 키
- SSH 접속을 허용할 신뢰 가능한 공인 IP/CIDR
- 선택한 지역의 VM quota 및 `Standard_D8s_v5` 용량

실습용 변수는 배포 스크립트의 기본값과 맞춰 설정합니다. 공인 IP는 참가자의 실제 접속 IP로 바꾸세요.

```bash
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
```

공개 키 파일과 개인 키 파일이 있는지 확인합니다.

```bash
test -f "$SSH_PUBLIC_KEY" && test -f "$SSH_PRIVATE_KEY"
```

## 1. 기본 인프라 배포

저장소 루트에서 실행합니다.

```bash
bash scripts/azure-setup.sh
```

배포된 리소스와 head VM의 공인 IP를 확인합니다.

```bash
az vm list --resource-group "$RG" --output table
az vmss list --resource-group "$RG" --output table
HEAD_PUBLIC_IP=$(az vm show --show-details --resource-group "$RG" --name "$HEAD" --query publicIps --output tsv)
printf 'Head VM public IP: %s\n' "$HEAD_PUBLIC_IP"
```

**확인:** head VM과 `hpc-compute` VMSS가 생성되어야 합니다. VMSS 인스턴스를 확인하고 규모 변경을 관찰할 수 있지만, 아직 Slurm 설정이나 노드 등록은 되어 있지 않습니다.

```bash
az vmss list-instances --resource-group "$RG" --name "$VMSS" --output table
az vmss scale --resource-group "$RG" --name "$VMSS" --new-capacity 3
az vmss list-instances --resource-group "$RG" --name "$VMSS" --output table
az vmss scale --resource-group "$RG" --name "$VMSS" --new-capacity 2
```

## 2. 고정 Slurm 노드 준비

Slurm 예제와 이름을 맞추기 위해 같은 VNet/subnet에 공인 IP가 없는 compute VM 두 대를 추가로 만듭니다.

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
```

각 VM의 사설 IP를 확인합니다.

```bash
HEAD_PRIVATE_IP=$(az vm list-ip-addresses --resource-group "$RG" --name "$HEAD" \
  --query '[0].virtualMachine.network.privateIpAddresses[0]' --output tsv)
COMPUTE01_PRIVATE_IP=$(az vm list-ip-addresses --resource-group "$RG" --name compute01 \
  --query '[0].virtualMachine.network.privateIpAddresses[0]' --output tsv)
COMPUTE02_PRIVATE_IP=$(az vm list-ip-addresses --resource-group "$RG" --name compute02 \
  --query '[0].virtualMachine.network.privateIpAddresses[0]' --output tsv)
printf 'headnode=%s\ncompute01=%s\ncompute02=%s\n' \
  "$HEAD_PRIVATE_IP" "$COMPUTE01_PRIVATE_IP" "$COMPUTE02_PRIVATE_IP"
```

세 VM 모두의 `/etc/hosts`에 위에서 확인한 사설 IP와 호스트 이름을 추가합니다. Slurm 설정과 NFS mount에서 이 이름을 사용합니다. 예를 들어 다음 항목을 각 VM에 추가합니다.

```text
10.0.0.4 headnode
10.0.0.5 compute01
10.0.0.6 compute02
```

주소는 실제 결과로 바꾸세요. head VM에는 로컬에서 SSH로 접속하고, compute VM에는 head를 점프 호스트로 사용합니다.

```bash
ssh -i "$SSH_PRIVATE_KEY" "$ADMIN_USERNAME@$HEAD_PUBLIC_IP"
ssh -i "$SSH_PRIVATE_KEY" -J "$ADMIN_USERNAME@$HEAD_PUBLIC_IP" "$ADMIN_USERNAME@$COMPUTE01_PRIVATE_IP"
```

compute VM마다 공인 IP를 만들지 마세요. 실습 계정의 UID와 GID가 세 노드에서 같은지도 확인합니다. NFS 파일 권한과 Slurm 작업 실행에 필요합니다.

```bash
id "$ADMIN_USERNAME"
```

## 3. 공유 작업 디렉터리 구성

head VM에서 NFS 서버를 설치하고 워크숍 전용 subnet에만 공유합니다.

```bash
sudo apt-get update
sudo apt-get install -y nfs-kernel-server git
sudo install -d -m 0775 /srv/hpc
sudo chown "$USER:$(id -gn)" /srv/hpc
sudo install -d -m 0755 /etc/exports.d
printf '/srv/hpc 10.0.0.0/24(rw,sync,no_subtree_check)\n' |
  sudo tee /etc/exports.d/hpc-workshop.exports
sudo exportfs -rav
sudo systemctl enable --now nfs-kernel-server
```

위의 `10.0.0.0/24`는 배포 스크립트가 만드는 subnet입니다. 다른 주소 범위를 사용했다면 실제 실습 subnet으로 바꾸세요. NSG에는 필요한 내부 통신만 허용하고, NFS를 인터넷에 노출하지 않습니다.

각 compute VM에서 NFS client를 설치하고 공유를 마운트합니다.

```bash
sudo apt-get update
sudo apt-get install -y nfs-common
sudo install -d -m 0775 /mnt/hpc
sudo mount -t nfs4 -o vers=4.1 headnode:/srv/hpc /mnt/hpc
touch /mnt/hpc/"$(hostname)-check"
```

head VM에서 다음 명령으로 세 노드의 파일이 같은 공유 디렉터리에서 보이는지 확인합니다.

```bash
ls -l /srv/hpc/*-check
```

이후 실습 명령은 저장소를 NFS 공유에 복제해 모든 노드에서 같은 파일을 사용하도록 합니다. head VM에서 실행합니다.

```bash
git clone https://github.com/SeoanSon/azure-hpc-iaas-workshop.git /mnt/hpc/workshop
```

## 4. Slurm 및 Munge 설정

각 노드에서 공유 경로에 있는 설치 스크립트를 실행합니다.

```bash
sudo bash /mnt/hpc/workshop/slurm/install-packages.sh
```

head VM에서 생성된 Munge 키를 compute 두 대에 SSH 암호화 연결로 전달합니다. 다음 명령은 키 내용을 출력하거나 로컬 파일로 저장하지 않습니다.

```bash
# headnode에서 키 권한을 확인/정정
sudo chown munge:munge /etc/munge/munge.key
sudo chmod 0400 /etc/munge/munge.key
```

로컬 워크스테이션에서 다음 전송을 실행합니다.

```bash
set -o pipefail
for node_ip in "$COMPUTE01_PRIVATE_IP" "$COMPUTE02_PRIVATE_IP"; do
  ssh -i "$SSH_PRIVATE_KEY" "$ADMIN_USERNAME@$HEAD_PUBLIC_IP" \
    'sudo cat /etc/munge/munge.key' |
  ssh -i "$SSH_PRIVATE_KEY" -J "$ADMIN_USERNAME@$HEAD_PUBLIC_IP" \
    "$ADMIN_USERNAME@$node_ip" \
    'sudo sh -c "cat > /etc/munge/munge.key && chown munge:munge /etc/munge/munge.key && chmod 0400 /etc/munge/munge.key"'
done
```

세 노드의 `/etc/munge/munge.key`는 동일해야 하며, 소유자는 `munge:munge`, 권한은 `0400`이어야 합니다. 키를 Git에 추가하거나 채팅/공유 문서에 붙여 넣지 마세요.

모든 노드에 같은 Slurm 설정 파일을 설치합니다.

```bash
sudo install -D -o root -g root -m 0644 \
  /mnt/hpc/workshop/slurm/slurm.conf /etc/slurm/slurm.conf
```

head VM에서 controller를, compute VM에서 daemon을 시작합니다.

```bash
# headnode에서
sudo install -d -o slurm -g slurm /var/lib/slurm/slurmctld
sudo systemctl enable munge slurmctld
sudo systemctl restart munge
sudo systemctl restart slurmctld
```

```bash
# compute01 및 compute02 각각에서
sudo install -d -o root -g root /var/lib/slurm/slurmd
sudo systemctl enable munge slurmd
sudo systemctl restart munge
sudo systemctl restart slurmd
```

**확인:** head VM에서 Munge와 Slurm controller가 정상인지 확인합니다.

```bash
munge -n | unmunge
scontrol ping
sinfo
```

`sinfo`에 `compute` partition의 두 노드가 보이고 `idle` 상태인지 확인합니다. 서비스가 시작되지 않으면 `sudo systemctl status munge slurmctld slurmd` 및 `sudo journalctl -u slurmctld -u slurmd --since today`에서 원인을 확인하세요. Slurm 설정 경로와 서비스 이름은 Ubuntu 패키지 버전에 따라 다를 수 있습니다.

## 5. Batch 및 MPI 작업 실행

head VM에서 NFS 공유 경로로 이동해 예제 제출 스크립트를 실행합니다.

```bash
cd /mnt/hpc
bash /mnt/hpc/workshop/slurm/submit-job.sh
squeue
```

작업이 끝난 뒤 노드별 출력이 담긴 파일을 확인합니다.

```bash
cat hello-*.out
```

정상 실행이면 출력에 compute 노드의 호스트 이름이 나타납니다. 작업이 대기하거나 실패하면 `squeue`, `sinfo`, `scontrol show node`, 그리고 `slurmctld`/`slurmd` 로그를 확인합니다. MPI 런타임과 Slurm 패키지의 호환성은 이미지 및 패키지 버전에 따라 달라질 수 있습니다.

## 6. 정리 및 토의

실습 결과를 기록하고 다음을 비교합니다.

- VMSS 인스턴스 수를 바꾸는 것과 Slurm 노드를 등록/제거하는 것의 차이
- head VM의 NFS 공유가 모든 작업의 입력/출력 경로가 될 때의 성능 한계
- VM SKU, 노드 수, 작업 시간에 따른 성능과 비용
- 실습 종료 후 리소스 그룹을 삭제했는지 여부

리소스 그룹이 이 워크숍 전용인지 먼저 확인한 뒤 삭제합니다. 같은 그룹에 보존할 리소스가 있으면 그룹 전체를 삭제하지 마세요.

```bash
az group delete --name "$RG" --yes --no-wait
```
