# Azure IaaS 기반 HPC 아키텍처

```text
                         SSH (제한된 출발지 CIDR)
                                  |
                            [Head VM]
                     Slurm controller / login
                         /             \
                 Slurm control       Shared data
                    traffic       Azure Files or NFS
                       |                 |
                [Compute VMSS] ----------+
                 Slurm compute nodes
                 MPI / batch workloads
```

## 역할

- **Head VM:** 로그인 및 관리, Slurm controller, 작업 제출
- **Compute VMSS:** 작업 실행 노드. VMSS는 VM 인스턴스 수명주기를 관리하지만 Slurm 클러스터 등록을 자동으로 해결하지는 않습니다.
- **공유 스토리지:** 입력, 작업 스크립트, 결과를 노드 간 공유. 특정 HPC 워크로드에서는 스토리지 처리량과 메타데이터 성능이 병목이 될 수 있습니다.
- **VNet/NSG:** 제어 및 데이터 트래픽을 격리하고 필요한 포트만 허용합니다.
- **로컬 임시 디스크:** 지원되는 SKU의 임시 디스크는 scratch 용도로 고려할 수 있으며, 영구 데이터 저장소로 간주하면 안 됩니다.

## HPC 성능 관점

- MPI의 노드 간 통신 성능은 VM SKU, 가상 네트워크, 배치 위치, 지원되는 RDMA/InfiniBand 기능에 영향을 받습니다. 일반 범용 VM으로 실행한 결과를 고성능 HPC SKU 결과와 혼동하지 않습니다.
- 스토리지 선택은 용량뿐 아니라 처리량, IOPS, 지연 시간, 동시 접근 패턴에 맞춰야 합니다.
- 작은 실습에서는 job 대기 시간과 VM 시작 시간이 실제 계산 시간보다 커질 수 있습니다.

## 보안 및 비용

- SSH 인바운드 규칙은 참가자 출발지 CIDR로 제한합니다. 인터넷 전체(`*`)에 열지 않습니다.
- 실습용 계정은 최소 권한으로 사용하고, 자격 증명을 저장소에 커밋하지 않습니다.
- VMSS의 인스턴스 수를 제한하고, 작업 후 리소스 그룹을 삭제합니다.
- VMSS 인스턴스 수를 변경하는 것만으로 Slurm의 동적 노드 관리가 완성되지는 않습니다. 노드 등록, hostname/IP 관리, 상태 전환 및 scale-in 시 작업 보호를 별도로 설계해야 합니다.
