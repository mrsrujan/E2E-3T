#!/usr/bin/env bash
#
# Destroys all three Terraform layers in reverse dependency order.
# Skipping this order will leak ALBs, EBS volumes, and ENIs.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAYERS=(gateway cluster-addons foundation)

echo "This will destroy EVERYTHING provisioned by terraform/."
read -rp "Type 'destroy' to continue: " confirm
if [[ "${confirm}" != "destroy" ]]; then
  echo "Aborted."
  exit 1
fi

for layer in "${LAYERS[@]}"; do
  echo
  echo "============================================================"
  echo " Destroying layer: ${layer}"
  echo "============================================================"
  cd "${SCRIPT_DIR}/${layer}"
  terraform destroy -auto-approve -input=false
done

cat <<'EOF'

All layers destroyed.

Manually verify in the AWS Console that these are gone (common leaks):
  - EC2 → Load Balancers         (orphaned ALBs from Gateway)
  - EC2 → Volumes                (orphaned EBS from PVCs)
  - EC2 → Security Groups        (k8s-* SGs)
  - CloudWatch → Log groups      (/aws/eks/*)
  - ECR → Repositories           (if images remain, destroy skips the repo)
EOF
