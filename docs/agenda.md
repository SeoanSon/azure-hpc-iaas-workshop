# 1일 워크숍 Agenda

| 시간 | 주제 | 주요 내용 |
| --- | --- | --- |
| 09:00–09:30 | HPC란 무엇인가 | 병렬 처리, 성능 병목, scale-up과 scale-out |
| 09:30–10:15 | Azure IaaS 아키텍처 | VM, VMSS, VNet, NSG, 스토리지 |
| 10:15–10:30 | 휴식 | |
| 10:30–12:00 | 실습 1: 인프라 준비 | Resource Group, 네트워크, head VM, compute VMSS |
| 12:00–13:00 | 점심 | |
| 13:00–14:30 | 실습 2: 스토리지와 노드 구성 | 공유 파일시스템 개념, 로컬 scratch, 노드 간 연결 |
| 14:30–15:00 | 휴식 | |
| 15:00–16:30 | 실습 3: Slurm | controller와 compute daemon, partition, job queue |
| 16:30–17:00 | 실습 4: MPI job | OpenMPI 예제 실행, `sbatch`, 결과 확인 |
| 17:00–17:30 | 리뷰 | 성능/비용/운영, 확장 한계 및 정리 |

## 강사 준비

- 참가자별 Azure 구독 권한, 지역별 VM quota 및 SKU 용량 확인
- Azure CLI 권한, Run Command 사전 조건, 지역별 VM quota 확인
- 모든 참가자가 실습 후 리소스를 삭제하도록 안내
- MPI 성능 비교는 동일 VM SKU, 입력 크기, 노드 수를 사용하도록 안내

## 실습 결과물

- Azure IaaS 기반 head/compute 노드 구조
- Slurm queue에 제출한 샘플 batch job
- 노드 수에 따른 처리 시간 및 비용에 대한 관찰 기록
