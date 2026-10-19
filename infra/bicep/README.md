# Bicep 배포

Resource Group을 먼저 만들고 공개 키와 SSH 허용 CIDR을 전달합니다.

```bash
az group create --name rg-hpc-workshop --location eastus
az deployment group create \
  --resource-group rg-hpc-workshop \
  --template-file infra/bicep/main.bicep \
  --parameters sshPublicKey="$(cat ~/.ssh/id_rsa.pub)" \
               sshSourceCidr="YOUR_PUBLIC_IP/32"
```

VMSS는 인프라만 배포하며 Slurm에 노드를 등록하지 않습니다. SSH CIDR을 실제 신뢰 가능한 출발지로 제한하고, 지역별 SKU 용량과 quota를 배포 전에 확인하세요.
