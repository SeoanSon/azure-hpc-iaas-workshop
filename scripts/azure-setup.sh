#!/usr/bin/env bash
set -euo pipefail

RG="${RG:-rg-hpc-workshop}"
LOC="${LOC:-eastus}"
VNET="${VNET:-vnet-hpc}"
SUBNET="${SUBNET:-subnet-hpc}"
NSG="${NSG:-nsg-hpc}"
HEAD="${HEAD:-headnode}"
VMSS="${VMSS:-hpc-compute}"
ADMIN_USERNAME="${ADMIN_USERNAME:-azureuser}"
VM_SIZE="${VM_SIZE:-Standard_D8s_v5}"
SSH_SOURCE_CIDR="${SSH_SOURCE_CIDR:-}"
SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY:-$HOME/.ssh/id_rsa.pub}"

if [[ -z "$SSH_SOURCE_CIDR" ]]; then
  echo "Set SSH_SOURCE_CIDR to the trusted source IP/CIDR for SSH access." >&2
  exit 1
fi
if [[ ! -f "$SSH_PUBLIC_KEY" ]]; then
  echo "SSH public key not found: $SSH_PUBLIC_KEY" >&2
  exit 1
fi

az group create --name "$RG" --location "$LOC" --output none
az network vnet create \
  --resource-group "$RG" --name "$VNET" \
  --address-prefixes 10.0.0.0/16 \
  --subnet-name "$SUBNET" --subnet-prefixes 10.0.0.0/24 \
  --output none
az network nsg create --resource-group "$RG" --name "$NSG" --output none
az network nsg rule create \
  --resource-group "$RG" --nsg-name "$NSG" --name AllowSSHFromTrustedCIDR \
  --priority 1000 --direction Inbound --access Allow --protocol Tcp \
  --source-address-prefixes "$SSH_SOURCE_CIDR" --source-port-ranges '*' \
  --destination-address-prefixes '*' --destination-port-ranges 22 \
  --output none

az vm create \
  --resource-group "$RG" --name "$HEAD" \
  --image Ubuntu2204 --size "$VM_SIZE" \
  --admin-username "$ADMIN_USERNAME" \
  --ssh-key-values "$SSH_PUBLIC_KEY" \
  --vnet-name "$VNET" --subnet "$SUBNET" --nsg "$NSG" \
  --public-ip-sku Standard \
  --output none

az vmss create \
  --resource-group "$RG" --name "$VMSS" \
  --image Ubuntu2204 --vm-sku "$VM_SIZE" --instance-count 2 \
  --admin-username "$ADMIN_USERNAME" \
  --ssh-key-values "$SSH_PUBLIC_KEY" \
  --vnet-name "$VNET" --subnet "$SUBNET" \
  --output none

echo "Created resource group '$RG', head VM '$HEAD', and VMSS '$VMSS'."
echo "This is infrastructure only; configure Slurm node registration separately."
