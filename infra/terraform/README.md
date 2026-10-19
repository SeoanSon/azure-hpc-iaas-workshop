# Terraform 배포

Terraform과 AzureRM provider가 설치되어 있고 `az login`으로 인증된 환경에서 실행합니다.

```bash
cp infra/terraform/terraform.tfvars.example infra/terraform/terraform.tfvars
# terraform.tfvars에서 YOUR_PUBLIC_IP/32를 신뢰 가능한 출발지 CIDR로 변경
cd infra/terraform
terraform init
terraform plan
terraform apply
```

배포 후 `terraform destroy`로 리소스를 정리합니다. 실제 적용 전 `terraform plan`을 검토하세요. 이 예제는 네트워크, head VM, VMSS를 만들며 Slurm 클러스터를 자동 구성하지 않습니다.
