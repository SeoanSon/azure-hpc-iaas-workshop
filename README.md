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
| `scripts/azure-setup.sh` | Azure CLI 기반 기본 인프라 생성 |
| `infra/bicep/main.bicep` | Bicep 배포 예제 |
| `infra/terraform/` | Terraform 배포 예제 |
| `slurm/` | Slurm 설치/설정 및 job 예제 |

## 사전 준비

- Azure 구독 및 Azure CLI 로그인
- SSH 공개 키
- SSH 접속에 사용할 공인 IP CIDR
- 대상 지역에서 VM SKU quota 및 용량 확인

## 빠른 시작

`scripts/azure-setup.sh`는 리소스 그룹, VNet, NSG, head VM, compute VMSS를 생성합니다. SSH를 허용할 CIDR을 지정한 뒤 실행하세요.

```bash
az login
export SSH_SOURCE_CIDR="203.0.113.10/32" # 본인의 실제 공인 IP/CIDR로 변경
bash scripts/azure-setup.sh
```

> 이 스크립트는 교육용 인프라 기초를 만들 뿐, 완성된 HPC 클러스터를 자동 구성하지 않습니다. VMSS 노드의 동적 등록/해제, Slurm 설정 배포, 공유 파일시스템 구성은 별도 실습 항목입니다. Slurm의 고정 노드 예제는 `slurm/README.md`를 참고하세요.

전체 실습 순서와 검증 명령은 [`docs/lab-guide.md`](docs/lab-guide.md)를 참고하세요. VMSS 관찰과 고정 호스트 이름을 사용하는 Slurm 실습은 별도 구성입니다.

## 정리

실습 후 생성한 Azure 리소스는 요금이 발생할 수 있습니다. 사용을 마치면 리소스 그룹을 삭제하세요.

```bash
az group delete --name rg-hpc-workshop --yes --no-wait
```

## 범위

이 워크숍은 VM/VMSS 기반 IaaS와 Slurm의 기초를 설명합니다. Azure CycleCloud 및 Azure Batch는 범위에서 제외하며, AKS도 본 실습의 HPC 작업 스케줄러로 사용하지 않습니다.
