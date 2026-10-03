#!/usr/bin/env bash
#
# Applies all three Terraform layers in dependency order.
# Each layer runs `terraform init -upgrade` + `terraform apply -auto-approve`.
#
# Prerequisite: ./bootstrap.sh (one-time) and populated terraform.tfvars in each layer.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAYERS=(foundation cluster-addons gateway)

for layer in "${LAYERS[@]}"; do
  echo
  echo "============================================================"
  echo " Applying layer: ${layer}"
  echo "============================================================"
  cd "${SCRIPT_DIR}/${layer}"

  if [[ ! -f terraform.tfvars ]]; then
    echo "ERROR: ${layer}/terraform.tfvars missing. Copy from terraform.tfvars.example and edit." >&2
    exit 1
  fi

  terraform init -upgrade -input=false
  terraform apply -auto-approve -input=false
done

echo
echo "All layers applied."
echo
echo "Next: aws eks update-kubeconfig --region <region> --name <cluster_name>"
echo "      kubectl get nodes"
echo "      kubectl -n argocd get applications"
