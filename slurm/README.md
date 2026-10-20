# Slurm 실습 안내

이 디렉터리의 설정은 **고정된 호스트 이름을 사용하는 최소 교육용 예제**입니다. VMSS의 인스턴스 이름과 수가 변할 때 Slurm 노드를 자동 등록/제거하지 않습니다. 따라서 VMSS 규모 변경 실습과 아래 고정 노드 구성 실습은 별도 단계로 진행합니다.

## 기본 개념

- Controller node: `slurmctld`로 job queue와 자원 할당 관리
- Compute node: `slurmd`로 할당된 job 실행
- Munge: 노드 간 Slurm 인증
- Shared filesystem: job script, 입력, 결과를 공통 경로로 제공

## Azure CLI 실습

워크숍은 Windows PowerShell의 Azure CLI만 사용합니다. VM에 SSH로 접속하거나 설치 명령을 직접 입력하지 말고, [`docs/lab-guide.md`](../docs/lab-guide.md)의 `az vm run-command invoke` 단계를 차례대로 실행합니다. Run Command가 이 디렉터리의 Slurm 설정과 패키지 설치 스크립트를 VM에 전달합니다.

`scripts/run-command/`에는 NFS, Munge 키, Slurm 서비스, MPI 작업 제출을 위한 Run Command 스크립트가 있습니다. 스크립트는 Azure CLI를 통해 원격 VM에서 실행하며, 로컬 Bash에서 실행하지 않습니다.

이 설정은 고정 노드 이름 `headnode`, `compute01`, `compute02`를 사용하는 최소 교육용 예제입니다. VMSS 인스턴스를 Slurm에 자동 등록하거나 제거하지 않습니다.
