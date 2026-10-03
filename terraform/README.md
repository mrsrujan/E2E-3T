# terraform/

Infrastructure for the E2E-3T project — EKS + Yelb app + ArgoCD + Jenkins + Gateway API.

Three layers, apply in order:

| Layer            | Provisions                                                                          | ~Time  |
|------------------|-------------------------------------------------------------------------------------|--------|
| `foundation/`    | VPC (3 AZ), EKS 1.28, managed nodegroup, ECR repos (yelb-ui/appserver/db), IRSA OIDC | ~15 min |
| `cluster-addons/`| EBS CSI (+gp3), AWS Load Balancer Controller, Jenkins, ArgoCD, ArgoCD Applications  | ~5 min  |
| `gateway/`       | Gateway API CRDs, Gateway resource (ALB-backed)                                     | ~2 min  |

See [../docs/deploy-terraform.md](../docs/deploy-terraform.md) for the full guide. This README is the quick reference.

## Quickstart

```bash
# One-time: provision S3 state backend + DynamoDB lock table
./bootstrap.sh

# Edit each layer's terraform.tfvars (copy from .example)
# At minimum, set state_bucket and account_id placeholders.

# Apply all three layers
./apply-all.sh

# Destroy everything (reverse order)
./destroy-all.sh
```

## File layout

```
terraform/
├── bootstrap.sh                 One-time S3 + DynamoDB state backend
├── apply-all.sh                 init+apply across all layers
├── destroy-all.sh               Destroy in reverse order
├── foundation/
│   ├── backend.tf               S3 remote state
│   ├── providers.tf             AWS provider
│   ├── variables.tf
│   ├── main.tf                  VPC + EKS + ECR
│   ├── outputs.tf
│   └── terraform.tfvars.example
├── cluster-addons/
│   ├── backend.tf
│   ├── providers.tf             aws + kubernetes + helm
│   ├── data.tf                  Pulls foundation remote state
│   ├── variables.tf
│   ├── ebs-csi.tf
│   ├── alb-controller.tf
│   ├── jenkins.tf
│   ├── argocd.tf
│   ├── argocd-apps.tf           Application CRs for Yelb
│   └── terraform.tfvars.example
└── gateway/
    ├── backend.tf
    ├── providers.tf
    ├── data.tf
    ├── variables.tf
    ├── main.tf                  CRDs + Gateway
    └── terraform.tfvars.example
```

## Prerequisites

- AWS CLI 2.15+, Terraform 1.6+, kubectl 1.28+, helm 3.12+
- An IAM principal with `AdministratorAccess` (initial apply)
- `aws configure` done

## Notes

- **The old `Jenkins-Server-TF/` is superseded** by this layout. Jenkins now runs in-cluster via Helm (see `cluster-addons/jenkins.tf`). Remove `Jenkins-Server-TF/` once this layer is working.
- ArgoCD Applications in `cluster-addons/argocd-apps.tf` point at `https://github.com/mrsrujan/E2E-3T.git` — change if you fork.
- `terraform.tfvars` is gitignored; `.example` files are checked in.
