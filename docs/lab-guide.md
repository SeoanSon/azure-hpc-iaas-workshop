# Azure CLI로 진행하는 HPC 실습

이 가이드는 **Windows PowerShell에서 Azure CLI(`az`) 명령만 실행**해 Azure VM 3대(head 1대, compute 2대)에 NFS, Slurm, OpenMPI를 구성합니다. VM 안에 직접 SSH로 접속하거나 Bash 명령을 따로 입력하지 않습니다. Linux 설정은 저장소의 스크립트를 `az vm run-command invoke`로 각 VM에 전달해 실행합니다. VM에는 공인 IP를 할당하지 않으며, SSH 인바운드 규칙도 만들지 않습니다.

## 실습 구성 및 비용

- `headnode`: NFS 서버, Slurm controller, 작업 제출 노드
- `compute01`, `compute02`: Slurm 작업 노드
- `hpc-compute` VMSS: 크기 변경 관찰 전용. 고정 Slurm 노드와 함께 실행하지 않습니다.

VMSS 초기에는 head 1대와 VMSS 2대가 실행됩니다. 규모 변경 관찰 중 최대 4대(head 1대 + VMSS 3대), 고정 노드 실습 중 3대(head 1대 + compute 2대)가 실행됩니다. VM, 디스크, NAT Gateway, 공인 IP 등 네트워크 사용에 Azure 요금이 발생합니다. 사용 가능한 VM 크기와 quota를 확인하세요. Azure의 SKU 목록에 표시되는 크기도 실제 용량이 보장되지는 않습니다. VMSS 용량 오류가 나면 VMSS 관찰 단계를 건너뛰고, VMSS를 0대로 줄였거나 인스턴스가 없는 것을 확인한 후 고정 노드 실습을 진행하세요.

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

`eastus`의 크기 목록과 quota를 확인합니다. SKU가 목록에 있어도 실제 배포 시점의 용량은 보장되지 않습니다.

```powershell
az vm list-skus --location eastus --resource-type virtualMachines --size Standard_D8s_v5 --all --output table
az vm list-usage --location eastus --output table
```

## 1. 네트워크와 head VM 만들기

아래 명령은 리소스 그룹, VNet/subnet, 기본 NSG, NAT Gateway와 head VM용 네트워크 인터페이스를 만듭니다. NSG의 기본 규칙은 같은 VNet 내 통신을 허용하고 인터넷 인바운드를 차단합니다. NAT Gateway는 공인 IP 없는 VM이 패키지 저장소와 GitHub에 아웃바운드 연결하도록 합니다. NAT Gateway와 공인 IP는 별도 요금이 발생할 수 있습니다. 사용자 지정 SSH 허용 규칙은 만들지 않습니다.

앞서 `SkuNotAvailable` 오류가 발생했다면 `eastus`에 해당 VM 크기의 용량이 없다는 뜻입니다. 같은 지역에서 용량이 확인된 다른 8-vCPU 크기를 선택하거나 다른 지역을 선택해 처음부터 모든 리소스를 같은 지역에 만드세요. VM 크기를 바꾸면 `slurm/slurm.conf`의 `CPUs` 및 `RealMemory` 값도 실제 VM 사양에 맞춰야 합니다. 구독 quota가 충분해도 물리적 용량 부족은 별도로 발생할 수 있습니다.

```powershell
az group create --name rg-hpc-workshop --location eastus --output table
az network nsg create --resource-group rg-hpc-workshop --name nsg-hpc --location eastus --output table
az network vnet create --resource-group rg-hpc-workshop --name vnet-hpc --location eastus --address-prefixes 10.0.0.0/16 --subnet-name subnet-hpc --subnet-prefixes 10.0.0.0/24 --output table
az network public-ip create --resource-group rg-hpc-workshop --name nat-hpc-pip --location eastus --sku Standard --allocation-method Static --output table
az network nat gateway create --resource-group rg-hpc-workshop --name nat-hpc --location eastus --public-ip-addresses nat-hpc-pip --idle-timeout 10 --output table
az network vnet subnet update --resource-group rg-hpc-workshop --vnet-name vnet-hpc --name subnet-hpc --network-security-group nsg-hpc --nat-gateway nat-hpc --output table
az network nic create --resource-group rg-hpc-workshop --name nic-headnode --location eastus --vnet-name vnet-hpc --subnet subnet-hpc --network-security-group nsg-hpc --output table
az vm create --resource-group rg-hpc-workshop --name headnode --image Ubuntu2204 --size Standard_D8s_v5 --admin-username azureuser --generate-ssh-keys --nics nic-headnode --output table
```

VM에 공인 IP를 만들지 않도록 먼저 NIC를 만들고 `az vm create --nics`로 연결합니다. 이렇게 하면 PowerShell에서 빈 `--public-ip-address ""` 값을 전달할 때 생기는 인수 오류도 피할 수 있습니다.

**확인:** head VM이 `Succeeded` 상태인지 확인합니다.

```powershell
az vm list --resource-group rg-hpc-workshop --output table
az vm get-instance-view --resource-group rg-hpc-workshop --name headnode --query "instanceView.statuses[].displayStatus" --output table
```

### 선택: VMSS 크기 변경 관찰

VMSS 관찰은 선택 단계입니다. 실제 용량 부족 오류가 발생하면 이 단계를 건너뛰어도 Slurm 실습에 영향이 없습니다. VM 크기나 지역을 바꿀 경우 해당 지역의 quota와 용량을 먼저 확인하세요. VNet과 VMSS는 같은 지역이어야 합니다.

VMSS를 만들고 3대로 늘려 본 뒤 0대로 줄입니다.

```powershell
az vmss create --resource-group rg-hpc-workshop --name hpc-compute --location eastus --image Ubuntu2204 --vm-sku Standard_D8s_v5 --instance-count 2 --admin-username azureuser --generate-ssh-keys --vnet-name vnet-hpc --subnet subnet-hpc
az vmss scale --resource-group rg-hpc-workshop --name hpc-compute --new-capacity 3
az vmss list-instances --resource-group rg-hpc-workshop --name hpc-compute --output table
az vmss scale --resource-group rg-hpc-workshop --name hpc-compute --new-capacity 0
az vmss list-instances --resource-group rg-hpc-workshop --name hpc-compute --output table
```

**용량 오류가 발생하면:** 같은 SKU로 재시도하지 마세요. 아래 조회로 선택한 지역의 사용 가능한 크기를 확인하고, 다른 크기 또는 지역을 선택합니다. 지역을 바꿀 경우 이 실습의 모든 네트워크와 VM을 그 지역에 함께 만들어야 합니다. VMSS만으로 계속 문제가 발생하면 VMSS를 생략하고 다음 단계로 진행합니다.

```powershell
az vm list-skus --location eastus --resource-type virtualMachines --size Standard_D8 --all --output table
az vmss list --resource-group rg-hpc-workshop --output table
```

실패한 VMSS 리소스가 목록에 남아 있고 실습용 리소스임을 확인했다면 삭제합니다. VMSS를 만들지 못했거나 선택 단계를 건너뛰었다면 그대로 다음 단계로 갑니다.

```powershell
az vmss delete --resource-group rg-hpc-workshop --name hpc-compute
```

VMSS를 만들었다면 인스턴스 수를 0으로 줄이고, 목록이 비어 있는 것을 확인합니다. 이 VMSS는 이후 Slurm 노드로 사용하지 않습니다.

```powershell
az vmss scale --resource-group rg-hpc-workshop --name hpc-compute --new-capacity 0
az vmss list-instances --resource-group rg-hpc-workshop --name hpc-compute --output table
```

## 2. 고정 compute VM 만들기

각 VM에 공인 IP가 생기지 않도록 NIC를 만든 뒤 VM에 연결합니다. VMSS 단계에서 해당 SKU 용량 오류를 겪었다면 아래 `--size` 값을 용량이 있는 SKU로 바꾸세요.

```powershell
az network nic create --resource-group rg-hpc-workshop --name nic-compute01 --location eastus --vnet-name vnet-hpc --subnet subnet-hpc --network-security-group nsg-hpc --output table
az vm create --resource-group rg-hpc-workshop --name compute01 --image Ubuntu2204 --size Standard_D8s_v5 --admin-username azureuser --generate-ssh-keys --nics nic-compute01 --output table
az network nic create --resource-group rg-hpc-workshop --name nic-compute02 --location eastus --vnet-name vnet-hpc --subnet subnet-hpc --network-security-group nsg-hpc --output table
az vm create --resource-group rg-hpc-workshop --name compute02 --image Ubuntu2204 --size Standard_D8s_v5 --admin-username azureuser --generate-ssh-keys --nics nic-compute02 --output table
az vm list --resource-group rg-hpc-workshop --show-details --output table
```

Azure 내부 DNS에서 세 VM 이름을 찾을 수 있는지 각 VM에서 Azure Run Command로 확인합니다.

```powershell
az vm run-command invoke --resource-group rg-hpc-workshop --name headnode --command-id RunShellScript --scripts "getent hosts headnode compute01 compute02"
az vm run-command invoke --resource-group rg-hpc-workshop --name compute01 --command-id RunShellScript --scripts "getent hosts headnode compute01 compute02"
az vm run-command invoke --resource-group rg-hpc-workshop --name compute02 --command-id RunShellScript --scripts "getent hosts headnode compute01 compute02"
```

**확인:** 각 VM의 출력에서 `headnode`, `compute01`, `compute02`가 모두 사설 IP로 해석되어야 합니다. 해석되지 않으면 Azure Portal에서 VM이 같은 VNet/subnet에 있는지 확인합니다.

## 3. NFS 공유 디렉터리 준비

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

## 4. Slurm 및 Munge 구성

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

## 5. MPI 작업 제출 및 결과 확인

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

## 6. 리소스 삭제

아래 명령은 이 워크숍의 리소스 그룹 전체를 삭제하며 되돌릴 수 없습니다. 다른 리소스가 없는지 먼저 확인합니다.

```powershell
az resource list --resource-group rg-hpc-workshop --output table
az group delete --name rg-hpc-workshop --yes --no-wait
```

## 문제 해결

| 증상 | Azure CLI에서 실행할 확인 명령 |
| --- | --- |
| VM 생성/패키지 설치 실패 | `az vm list --resource-group rg-hpc-workshop --show-details --output table`로 VM 상태 확인. 배포 지역의 SKU quota/용량과 Run Command 결과 확인. SKU 용량 부족 시 `az vm list-skus`로 다른 크기/지역 확인 |
| 내부 이름 해석 실패 | 3절의 `getent hosts` Run Command를 각 VM에서 다시 실행 |
| NFS 마운트/공유 파일 실패 | 3절의 Run Command 결과와 `az vm run-command invoke ... --scripts "systemctl status nfs-kernel-server; exportfs -v"` 실행 결과 확인 |
| Munge 인증 실패 | 세 VM의 `id -u munge` 결과와 Munge 키 배포 명령 결과 확인 |
| Slurm 노드가 `down` | 4절의 controller/compute 서비스 상태 및 journalctl Run Command 실행 |
| 작업이 완료되지 않음 | `az vm run-command invoke --resource-group rg-hpc-workshop --name headnode --command-id RunShellScript --scripts "squeue; sinfo -N -l"` 실행 후 Slurm 로그 확인 |
