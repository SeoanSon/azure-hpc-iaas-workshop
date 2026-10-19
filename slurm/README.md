# Slurm 실습 안내

이 디렉터리의 설정은 **고정된 호스트 이름을 사용하는 최소 교육용 예제**입니다. VMSS의 인스턴스 이름과 수가 변할 때 Slurm 노드를 자동 등록/제거하지 않습니다. 따라서 VMSS 규모 변경 실습과 아래 고정 노드 구성 실습은 별도 단계로 진행합니다.

## 기본 개념

- Controller node: `slurmctld`로 job queue와 자원 할당 관리
- Compute node: `slurmd`로 할당된 job 실행
- Munge: 노드 간 Slurm 인증
- Shared filesystem: job script, 입력, 결과를 공통 경로로 제공

## 고정 노드 실습 순서

1. Head와 두 compute VM에 동일한 Slurm 및 Munge 패키지를 설치합니다.
2. 모든 노드의 `/etc/munge/munge.key`를 같은 키로 구성하고 소유자/권한을 `munge:munge`, `0400`으로 제한합니다. 키를 저장소에 커밋하거나 공개 채널로 전송하지 않습니다.
3. 모든 노드에 동일한 `/etc/slurm/slurm.conf`를 설치하고, DNS 또는 `/etc/hosts`에서 `headnode`, `compute01`, `compute02` 이름이 해석되는지 확인합니다.
4. Head에서 `slurmctld`, compute에서 `slurmd`를 시작하고 `sinfo`, `scontrol ping`으로 확인합니다.
5. `submit-job.sh` 예제를 이용해 batch job을 제출합니다.

Ubuntu 패키지의 Slurm 설정 경로와 패키지 버전은 이미지/저장소에 따라 다를 수 있으므로 설치 후 `dpkg -L slurm-wlm` 등으로 실제 경로를 확인하세요. 이 실습은 사용자 계정, 공유 스토리지, 방화벽 규칙도 환경에 맞춰 별도 구성해야 합니다.
