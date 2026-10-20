# Azure CLI로 진행하는 HPC 실습

이 가이드는 **Windows PowerShell에서 Azure CLI(`az`) 명령만 실행**해 Azure VM 3대(head 1대, compute 2대)에 NFS, Slurm, OpenMPI를 구성합니다. VM 안에 직접 SSH로 접속하거나 Bash 명령을 따로 입력하지 않습니다. Linux 설정은 저장소의 스크립트를 `az vm run-command invoke`로 각 VM에 전달해 실행합니다. VM에는 공인 IP를 할당하지 않으며, SSH 인바운드 규칙도 만들지 않습니다.

## 실습 구성 및 비용

- `headnode`: NFS 서버, Slurm controller, 작업 제출 노드
- `compute01`, `compute02`: Slurm 작업 노드
- `hpc-compute` VMSS: 크기 변경 관찰 전용. 고정 Slurm 노드와 함께 실행하지 않습니다.

VMSS 초기에는 head 1대와 VMSS 2대가 실행됩니다. 규모 변경 관찰 중 최대 4대(head 1대 + VMSS 3대), 고정 노드 실습 중 3대(head 1대 + compute 2대)가 실행됩니다. VM, 디스크, NAT Gateway, 공인 IP 등 네트워크 사용에 Azure 요금이 발생합니다. 최대 4대분의 `Standard_D8s_v5` quota/용량을 확인하고, VMSS를 0대로 줄인 것을 확인한 뒤 고정 노드를 만드세요.

## 0. 사전 준비

1. 저장소를 로컬 컴퓨터에 내려받고 **저장소 루트 폴더에서 PowerShell을 엽니다.** `@scripts/...` 파일을 Azure CLI가 읽기 때문에 작업 위치가 저장소 루트여야 합니다.
2. Azure CLI를 설치하고 아래 로그인/구독 선택 명령을 실행합니다.
3. Azure 구독의 리소스 생성 권한과 `Standard_D8s_v5` quota/용량을 확인합니다.

`YOUR_SUBSCRIPTION_ID`를 실제 구독 ID로 바꿉니다.

```powershell
az login
az account set --subscription "YOUR_SUBSCRIPTION_ID"
az account show --output table
```

## 1. 네트워크와 기본 VM/VMSS 만들기

아래 명령은 리소스 그룹, VNet/subnet, 기본 NSG, NAT Gateway, head VM, VMSS를 만듭니다. NSG의 기본 규칙은 같은 VNet 내 통신을 허용하고 인터넷 인바운드를 차단합니다. NAT Gateway는 공인 IP 없는 VM이 패키지 저장소와 GitHub에 아웃바운드 연결하도록 합니다. NAT Gateway와 공인 IP는 별도 요금이 발생할 수 있습니다. 사용자 지정 SSH 허용 규칙은 만들지 않습니다.

```powershell
az group create --name rg-hpc-workshop --location eastus --output table
az network nsg create --resource-group rg-hpc-workshop --name nsg-hpc --location eastus --output table
az network vnet create --resource-group rg-hpc-workshop --name vnet-hpc --location eastus --address-prefixes 10.0.0.0/16 --subnet-name subnet-hpc --subnet-prefixes 10.0.0.0/24 --output table
az network public-ip create --resource-group rg-hpc-workshop --name nat-hpc-pip --location eastus --sku Standard --allocation-method Static --output table
az network nat gateway create --resource-group rg-hpc-workshop --name nat-hpc --location eastus --public-ip-addresses nat-hpc-pip --idle-timeout 10 --output table
az network vnet subnet update --resource-group rg-hpc-workshop --vnet-name vnet-hpc --name subnet-hpc --network-security-group nsg-hpc --nat-gateway nat-hpc --output table
az vm create --resource-group rg-hpc-workshop --name headnode --image Ubuntu2204 --size Standard_D8s_v5 --admin-username azureuser --generate-ssh-keys --vnet-name vnet-hpc --subnet subnet-hpc --public-ip-address "" --output table
az vmss create --resource-group rg-hpc-workshop --name hpc-compute --image Ubuntu2204 --vm-sku Standard_D8s_v5 --instance-count 2 --admin-username azureuser --generate-ssh-keys --vnet-name vnet-hpc --subnet subnet-hpc --output table
```

**확인:** head VM과 VMSS가 목록에 있어야 합니다.

```powershell
az vm list --resource-group rg-hpc-workshop --output table
az vmss list --resource-group rg-hpc-workshop --output table
az vmss list-instances --resource-group rg-hpc-workshop --name hpc-compute --output table
```

## 2. VMSS 크기 변경을 관찰하고 중지하기

VMSS 크기를 3대로 늘려 목록을 확인한 뒤 0대로 줄입니다. 0대가 된 것을 확인하기 전에는 다음 단계의 고정 노드를 생성하지 마세요.

```powershell
az vmss scale --resource-group rg-hpc-workshop --name hpc-compute --new-capacity 3
az vmss list-instances --resource-group rg-hpc-workshop --name hpc-compute --output table
az vmss scale --resource-group rg-hpc-workshop --name hpc-compute --new-capacity 0
az vmss list-instances --resource-group rg-hpc-workshop --name hpc-compute --output table
```

**확인:** 마지막 목록에 VMSS 인스턴스가 없어야 합니다. 이 VMSS는 이후 Slurm 노드로 사용하지 않습니다.

## 3. 고정 compute VM 만들기

각 명령을 한 번씩 실행합니다. VM은 공인 IP 없이 같은 VNet에 생성됩니다. `--generate-ssh-keys`는 Linux VM 초기화 요구에 맞춰 키를 생성하지만, 이 가이드에서는 SSH 접속에 사용하지 않습니다.

```powershell
az vm create --resource-group rg-hpc-workshop --name compute01 --image Ubuntu2204 --size Standard_D8s_v5 --admin-username azureuser --generate-ssh-keys --vnet-name vnet-hpc --subnet subnet-hpc --public-ip-address "" --output table
az vm create --resource-group rg-hpc-workshop --name compute02 --image Ubuntu2204 --size Standard_D8s_v5 --admin-username azureuser --generate-ssh-keys --vnet-name vnet-hpc --subnet subnet-hpc --public-ip-address "" --output table
az vm list --resource-group rg-hpc-workshop --show-details --output table
```

Azure 내부 DNS에서 세 VM 이름을 찾을 수 있는지 각 VM에서 Azure Run Command로 확인합니다.

```powershell
az vm run-command invoke --resource-group rg-hpc-workshop --name headnode --command-id RunShellScript --scripts "getent hosts headnode compute01 compute02"
az vm run-command invoke --resource-group rg-hpc-workshop --name compute01 --command-id RunShellScript --scripts "getent hosts headnode compute01 compute02"
az vm run-command invoke --resource-group rg-hpc-workshop --name compute02 --command-id RunShellScript --scripts "getent hosts headnode compute01 compute02"
```

**확인:** 각 VM의 출력에서 `headnode`, `compute01`, `compute02`가 모두 사설 IP로 해석되어야 합니다. 해석되지 않으면 Azure Portal에서 VM이 같은 VNet/subnet에 있는지 확인합니다.

## 4. NFS 공유 디렉터리 준비

headnode에 NFS 서버를 구성하고 저장소의 Slurm 설정을 공유 디렉터리에 가져옵니다. 아래 `--scripts` 인수는 로컬 저장소의 스크립트 파일을 Azure CLI로 전달해 원격 VM에서 실행합니다.

```powershell
az vm run-command invoke --resource-group rg-hpc-workshop --name headnode --command-id RunShellScript --scripts "@scripts/run-command/configure-nfs-server.sh"
```

두 compute VM 각각에 NFS client를 구성하고 공유 디렉터리를 마운트합니다.

```powershell
az vm run-command invoke --resource-group rg-hpc-workshop --name compute01 --command-id RunShellScript --scripts "@scripts/run-command/configure-nfs-client.sh"
az vm run-command invoke --resource-group rg-hpc-workshop --name compute02 --command-id RunShellScript --scripts "@scripts/run-command/configure-nfs-client.sh"
```

공유 경로가 실제로 연결되는지 확인합니다. 첫 명령은 compute01에서 표식 파일을 만들고 두 번째 명령은 headnode에서 확인합니다.

```powershell
az vm run-command invoke --resource-group rg-hpc-workshop --name compute01 --command-id RunShellScript --scripts "runuser -u azureuser -- touch /mnt/hpc/compute01-check && findmnt /mnt/hpc"
az vm run-command invoke --resource-group rg-hpc-workshop --name headnode --command-id RunShellScript --scripts "ls -l /mnt/hpc/compute01-check /mnt/hpc/workshop/slurm/slurm.conf"
```

**확인:** 두 번째 명령에서 표식 파일과 `slurm.conf`가 보여야 합니다. 실패하면 첫 `az vm run-command invoke` 결과가 성공했는지, 각 VM의 DNS 확인 결과와 NFS 서버/클라이언트 명령 결과를 확인합니다.

## 5. Slurm 및 Munge 구성

세 VM 각각에서 저장소의 패키지 설치 스크립트를 Azure Run Command로 실행합니다.

```powershell
az vm run-command invoke --resource-group rg-hpc-workshop --name headnode --command-id RunShellScript --scripts "@slurm/install-packages.sh"
az vm run-command invoke --resource-group rg-hpc-workshop --name compute01 --command-id RunShellScript --scripts "@slurm/install-packages.sh"
az vm run-command invoke --resource-group rg-hpc-workshop --name compute02 --command-id RunShellScript --scripts "@slurm/install-packages.sh"
```

Munge 계정의 숫자 UID가 세 VM에서 같은지 확인합니다. 같은 Ubuntu 이미지와 패키지로 구성한 경우 동일해야 하며, 공유 NFS에서 키 파일을 읽는 데 필요합니다.

```powershell
az vm run-command invoke --resource-group rg-hpc-workshop --name headnode --command-id RunShellScript --scripts "id -u munge"
az vm run-command invoke --resource-group rg-hpc-workshop --name compute01 --command-id RunShellScript --scripts "id -u munge"
az vm run-command invoke --resource-group rg-hpc-workshop --name compute02 --command-id RunShellScript --scripts "id -u munge"
```

**확인:** 세 명령이 같은 숫자를 반환해야 합니다. 다르면 키 배포를 진행하지 마세요.

headnode에서 키를 생성해 NFS 서버의 공유 경로에 임시로 둡니다. 두 compute 노드는 공유 경로에서 키를 설치합니다. 임시 파일은 Munge 계정만 읽을 수 있고, 배포 후 삭제합니다.

```powershell
az vm run-command invoke --resource-group rg-hpc-workshop --name headnode --command-id RunShellScript --scripts "@scripts/run-command/create-munge-key.sh"
az vm run-command invoke --resource-group rg-hpc-workshop --name compute01 --command-id RunShellScript --scripts "@scripts/run-command/install-munge-key.sh"
az vm run-command invoke --resource-group rg-hpc-workshop --name compute02 --command-id RunShellScript --scripts "@scripts/run-command/install-munge-key.sh"
az vm run-command invoke --resource-group rg-hpc-workshop --name headnode --command-id RunShellScript --scripts "rm -f /srv/hpc/.munge-key"
```

이제 headnode에서 Slurm controller, compute VM에서 Slurm daemon을 설정합니다.

```powershell
az vm run-command invoke --resource-group rg-hpc-workshop --name headnode --command-id RunShellScript --scripts "@scripts/run-command/configure-slurm-controller.sh"
az vm run-command invoke --resource-group rg-hpc-workshop --name compute01 --command-id RunShellScript --scripts "@scripts/run-command/configure-slurm-compute.sh"
az vm run-command invoke --resource-group rg-hpc-workshop --name compute02 --command-id RunShellScript --scripts "@scripts/run-command/configure-slurm-compute.sh"
```

headnode에서 서비스와 노드 상태를 확인합니다.

```powershell
az vm run-command invoke --resource-group rg-hpc-workshop --name headnode --command-id RunShellScript --scripts "scontrol ping && sinfo -N -l && srun --mpi=list"
```

**정상 결과:** controller가 응답하고 `sinfo`에 `compute01`, `compute02`가 `idle` 상태로 표시되며 MPI 목록에 `pmix`가 있어야 합니다. 실패 시 각 VM의 서비스 상태와 로그를 Azure Run Command로 조회합니다.

```powershell
az vm run-command invoke --resource-group rg-hpc-workshop --name headnode --command-id RunShellScript --scripts "systemctl --no-pager --full status munge slurmctld; journalctl -u slurmctld --since today --no-pager"
az vm run-command invoke --resource-group rg-hpc-workshop --name compute01 --command-id RunShellScript --scripts "systemctl --no-pager --full status munge slurmd; journalctl -u slurmd --since today --no-pager"
az vm run-command invoke --resource-group rg-hpc-workshop --name compute02 --command-id RunShellScript --scripts "systemctl --no-pager --full status munge slurmd; journalctl -u slurmd --since today --no-pager"
```

## 6. MPI 작업 제출 및 결과 확인

Azure Run Command로 공유 경로에 MPI batch job을 만들고 제출합니다.

```powershell
az vm run-command invoke --resource-group rg-hpc-workshop --name headnode --command-id RunShellScript --scripts "@slurm/submit-job.sh"
az vm run-command invoke --resource-group rg-hpc-workshop --name headnode --command-id RunShellScript --scripts "squeue"
```

작업이 완료된 뒤 결과를 확인합니다.

```powershell
az vm run-command invoke --resource-group rg-hpc-workshop --name headnode --command-id RunShellScript --scripts "cat /mnt/hpc/hello-*.out"
```

**정상 결과:** 출력에 `compute01` 및 `compute02`가 나타납니다. 작업이 대기 중이면 `sinfo -N -l`을, 실패하면 `scontrol show job JOB_ID`와 위의 Slurm 로그 명령을 실행합니다. `JOB_ID`는 `sbatch` 결과에서 확인한 숫자로 바꿉니다.

## 7. 리소스 삭제

아래 명령은 이 워크숍의 리소스 그룹 전체를 삭제하며 되돌릴 수 없습니다. 다른 리소스가 없는지 먼저 확인합니다.

```powershell
az resource list --resource-group rg-hpc-workshop --output table
az group delete --name rg-hpc-workshop --yes --no-wait
```

## 문제 해결

| 증상 | Azure CLI에서 실행할 확인 명령 |
| --- | --- |
| VM 생성/패키지 설치 실패 | `az vm list --resource-group rg-hpc-workshop --show-details --output table`로 VM 상태 확인. 배포 지역의 SKU quota/용량과 Run Command 결과 확인 |
| 내부 이름 해석 실패 | 3절의 `getent hosts` Run Command를 각 VM에서 다시 실행 |
| NFS 마운트/공유 파일 실패 | 4절의 Run Command 결과와 `az vm run-command invoke ... --scripts "systemctl status nfs-kernel-server; exportfs -v"` 실행 결과 확인 |
| Munge 인증 실패 | 세 VM의 `id -u munge` 결과와 Munge 키 배포 명령 결과 확인 |
| Slurm 노드가 `down` | 5절의 controller/compute 서비스 상태 및 journalctl Run Command 실행 |
| 작업이 완료되지 않음 | `az vm run-command invoke --resource-group rg-hpc-workshop --name headnode --command-id RunShellScript --scripts "squeue; sinfo -N -l"` 실행 후 Slurm 로그 확인 |
