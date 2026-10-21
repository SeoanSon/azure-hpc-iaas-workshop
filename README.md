# Azure IaaS 기반 HPC 워크숍

Azure VM과 VM Scale Sets를 직접 조립해 HPC 클러스터의 구성 요소와 운영 방식을 학습하는 실습 자료입니다. Azure CycleCloud와 Azure Batch는 사용하지 않습니다.

## 학습 목표

- HPC의 병렬 처리, 스케줄링, 네트워크 및 스토리지 개념 이해
- Azure VM, VMSS, VNet, NSG를 이용한 IaaS 아키텍처 구성
- Slurm과 MPI를 이용한 작업 제출 및 실행 흐름 이해
- 성능, 확장성, 보안, 비용 사이의 trade-off 살펴보기

## 저장소 구성

| 경로 | 내용 |
| --- | --- |
| `docs/agenda.md` | 1일 워크숍 진행안 |
| `docs/architecture.md` | 아키텍처와 설계 고려 사항 |
| `docs/slide-outline.md` | 발표용 슬라이드 목차 |
| `docs/lab-guide.md` | Azure 인프라, NFS, 고정 노드 Slurm/MPI 단계별 실습 |
| `scripts/run-command/` | Azure Run Command로 각 VM에 적용하는 실습 설정 |
| `infra/bicep/main.bicep` | Bicep 배포 예제 |
| `infra/terraform/` | Terraform 배포 예제 |
| `slurm/` | Slurm 설치/설정 및 job 예제 |
| `batch-windows-poc/` | 별도 Windows API + Azure Batch 작업/파일 I/O 성능 PoC |

Bicep 및 Terraform 디렉터리는 선택형 IaC 참고 예제이며, 단계별 실습 경로에는 포함되지 않습니다.

## 사전 준비

- Windows PowerShell 및 Azure CLI
- Azure 구독 권한과 대상 지역의 VM SKU quota/용량
- 저장소를 내려받고 저장소 루트에서 PowerShell 열기

## 실습 시작

전체 실습은 **Windows PowerShell에서 Azure CLI(`az`)만 실행**하도록 구성했습니다. VM 내부 설정은 SSH 접속이나 Bash 터미널 대신 `az vm run-command invoke`로 적용합니다. [단계별 가이드](docs/lab-guide.md)의 명령을 위에서부터 실행하세요. Azure 리소스 생성 비용이 발생합니다.

## 정리

실습 후 생성한 Azure 리소스는 요금이 발생할 수 있습니다. 사용을 마치면 리소스 그룹을 삭제하세요.

```powershell
az group delete --name rg-hpc-workshop --yes --no-wait
```

## 범위

이 워크숍의 단계별 실습은 VM/VMSS 기반 IaaS와 Slurm의 기초를 설명합니다. Azure CycleCloud 및 AKS는 본 실습의 HPC 작업 스케줄러로 사용하지 않습니다. Windows Azure Batch의 독립 PoC는 [`batch-windows-poc/README.md`](batch-windows-poc/README.md)에 있으며, 기본 Slurm 실습과 별도로 배포합니다.
