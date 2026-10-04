# Deploy with Terraform (Automated)

End-to-end AWS infrastructure for the Yelb 3-tier app on EKS, provisioned by Terraform. App deployment is handled by ArgoCD after infra is up (Terraform does **not** apply app manifests directly).

> **Status note:** this doc describes the target state. The repo still contains the old React/Node/Mongo app and single-EC2 Jenkins. Code migration to Yelb + in-cluster Jenkins is tracked separately. Treat this doc as the north star.

---

## Architecture

```
                       ┌─────────────────────────────────────┐
   Internet ──▶ ALB ──▶│  EKS cluster (private subnets)      │
                       │                                     │
                       │  ns: 3-tier                     │
                       │   ├─ yelb-ui       (Deployment)     │
                       │   ├─ yelb-appserver(Deployment)     │
                       │   ├─ yelb-db       (StatefulSet+EBS)│
                       │   └─ redis-server  (Deployment)     │
                       │                                     │
                       │  ns: argocd  — reconciles manifests │
                       │  ns: jenkins — builds, pushes ECR   │
                       └─────────────────────────────────────┘
                                  │                 │
                                  ▼                 ▼
                             Private ECR       GitHub (manifests repo)
```

**Flow:** Jenkins builds image → pushes to ECR → bumps image tag in Git → ArgoCD detects change → syncs to cluster.

---

## Prerequisites

| Tool            | Minimum version | Purpose                               |
|-----------------|-----------------|---------------------------------------|
| AWS CLI         | 2.15            | Auth, kubeconfig                      |
| Terraform       | 1.6             | All infra                             |
| kubectl         | 1.28            | Post-apply verification               |
| helm            | 3.12            | (Terraform calls helm; local is for debugging) |

**AWS account requirements:**
- IAM user/role with `AdministratorAccess` for the initial apply (can be scoped tighter later — see [IAM minimization](#iam-minimization-optional)).
- A region with EKS availability. This doc uses `us-east-1`.
- Service quotas: ≥ 5 Elastic IPs (NAT GWs + ALB), ≥ 2 `m5.large` or equivalent for nodegroup.

**One-off AWS Console tasks (not in Terraform):**
- Create an **IAM user** `eks-admin` with programmatic access, attach `AdministratorAccess`.
- Run `aws configure` locally with its access/secret key.

---

## Repo layout (target)

```
E2E-3T/
├── Application-Code/
│   ├── yelb-ui/
│   ├── yelb-appserver/
│   └── yelb-db/
├── terraform/
│   ├── bootstrap.sh        # One-time S3 + DynamoDB state backend
│   ├── apply-all.sh        # init+apply across all layers
│   ├── destroy-all.sh      # Reverse-order destroy
│   ├── foundation/         # VPC, EKS, IAM, ECR
│   ├── cluster-addons/     # EBS CSI, ALB controller, Jenkins, ArgoCD
│   └── gateway/            # Gateway API CRDs + Gateway resource
├── Jenkins-Pipeline-Code/
│   ├── Jenkinsfile-UI
│   ├── Jenkinsfile-Appserver
│   └── Jenkinsfile-DB
├── Kubernetes-Manifests-file/
│   ├── UI/
│   ├── Appserver/
│   ├── DB/
│   ├── Redis/
│   └── Gateway/
└── docs/
    ├── deploy-terraform.md   (this file)
    └── deploy-manual.md
```

**Why 3 Terraform layers instead of one?** Each layer has a different blast radius and change cadence. Breaking the cluster addons shouldn't force you to touch VPC state. Each layer has its own `terraform.tfstate`.

---

## Step 0 — Bootstrap Terraform state backend (one-time)

Use S3 for state and DynamoDB for locking. **Do this once per AWS account; all three Terraform layers reuse it.**

```bash
BUCKET="e2e3t-tfstate-$(aws sts get-caller-identity --query Account --output text)"
TABLE="e2e3t-tflocks"
REGION="us-east-1"

aws s3api create-bucket --bucket "$BUCKET" --region "$REGION"
aws s3api put-bucket-versioning --bucket "$BUCKET" \
    --versioning-configuration Status=Enabled
aws s3api put-bucket-encryption --bucket "$BUCKET" \
    --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

aws dynamodb create-table --table-name "$TABLE" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST --region "$REGION"
```

Note the bucket name — you'll paste it into each layer's `backend.tf`.

---

## Step 1 — Layer A: foundation

**Provisions:** VPC (3 AZ, public + private subnets, 1 NAT GW for cost), EKS cluster 1.28, managed nodegroup (2× `t3.medium`), 3 private ECR repos, IAM OIDC provider for IRSA, IAM roles for node group / EBS CSI / ALB controller / Jenkins.

### 1.1 `terraform/foundation/backend.tf`

```hcl
terraform {
  required_version = ">= 1.6"
  backend "s3" {
    bucket         = "e2e3t-tfstate-<ACCOUNT_ID>"
    key            = "foundation/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "e2e3t-tflocks"
    encrypt        = true
  }
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.40" }
  }
}

provider "aws" {
  region = var.region
}
```

### 1.2 `terraform/foundation/variables.tf`

```hcl
variable "region"        { type = string, default = "us-east-1" }
variable "cluster_name"  { type = string, default = "3-tier-cluster" }
variable "cluster_version" { type = string, default = "1.28" }
variable "vpc_cidr"      { type = string, default = "10.0.0.0/16" }
variable "node_instance_type" { type = string, default = "t3.medium" }
variable "node_desired_size"  { type = number, default = 2 }
```

### 1.3 `terraform/foundation/main.tf`

Use the community EKS and VPC modules — hand-rolling these is a mistake.

```hcl
data "aws_availability_zones" "available" { state = "available" }

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.5"

  name = "${var.cluster_name}-vpc"
  cidr = var.vpc_cidr
  azs  = slice(data.aws_availability_zones.available.names, 0, 3)

  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

  enable_nat_gateway   = true
  single_nat_gateway   = true   # cost: 1 NAT, not HA. Flip for prod.
  enable_dns_hostnames = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.8"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version
  vpc_id          = module.vpc.vpc_id
  subnet_ids      = module.vpc.private_subnets

  cluster_endpoint_public_access = true    # tighten in prod
  enable_irsa                    = true

  eks_managed_node_groups = {
    primary = {
      instance_types = [var.node_instance_type]
      min_size       = 2
      max_size       = 4
      desired_size   = var.node_desired_size
    }
  }

  # Grant the IAM principal running terraform cluster-admin
  enable_cluster_creator_admin_permissions = true
}

resource "aws_ecr_repository" "yelb" {
  for_each             = toset(["yelb-ui", "yelb-appserver", "yelb-db"])
  name                 = each.key
  image_tag_mutability = "IMMUTABLE"
  image_scanning_configuration { scan_on_push = true }
}
```

### 1.4 `terraform/foundation/outputs.tf`

```hcl
output "cluster_name"       { value = module.eks.cluster_name }
output "cluster_endpoint"   { value = module.eks.cluster_endpoint }
output "cluster_oidc_arn"   { value = module.eks.oidc_provider_arn }
output "cluster_oidc_url"   { value = module.eks.cluster_oidc_issuer_url }
output "ecr_repository_urls" {
  value = { for k, v in aws_ecr_repository.yelb : k => v.repository_url }
}
output "vpc_id"             { value = module.vpc.vpc_id }
output "private_subnet_ids" { value = module.vpc.private_subnets }
```

### 1.5 Apply

```bash
cd terraform/foundation
terraform init
terraform plan -out plan.tfplan
terraform apply plan.tfplan
```

Expect ~15 minutes (EKS control plane dominates).

### 1.6 Verify

```bash
aws eks update-kubeconfig --region us-east-1 --name 3-tier-cluster
kubectl get nodes
kubectl get ns
```

Both nodes should show `Ready`.

---

## Step 2 — Layer B: cluster-addons

**Provisions:** EKS-managed addons (coredns, kube-proxy, vpc-cni, aws-ebs-csi-driver with IRSA), AWS Load Balancer Controller (Helm), ArgoCD (Helm), Jenkins (Helm, replaces the old EC2 Jenkins), and ArgoCD `Application` CRs for the four Yelb components.

### 2.1 `terraform/cluster-addons/backend.tf`

Same as 1.1 but with `key = "cluster-addons/terraform.tfstate"`.

### 2.2 Pull foundation outputs via remote state

```hcl
data "terraform_remote_state" "foundation" {
  backend = "s3"
  config = {
    bucket = "e2e3t-tfstate-<ACCOUNT_ID>"
    key    = "foundation/terraform.tfstate"
    region = "us-east-1"
  }
}

locals {
  cluster_name     = data.terraform_remote_state.foundation.outputs.cluster_name
  cluster_endpoint = data.terraform_remote_state.foundation.outputs.cluster_endpoint
  oidc_arn         = data.terraform_remote_state.foundation.outputs.cluster_oidc_arn
  oidc_url         = data.terraform_remote_state.foundation.outputs.cluster_oidc_url
}

data "aws_eks_cluster_auth" "this" { name = local.cluster_name }
data "aws_eks_cluster"      "this" { name = local.cluster_name }
```

### 2.3 Kubernetes + Helm providers

```hcl
provider "kubernetes" {
  host                   = data.aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.this.token
}
provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.this.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}
```

### 2.4 EBS CSI driver (IRSA + addon)

```hcl
module "ebs_csi_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.39"

  role_name             = "${local.cluster_name}-ebs-csi"
  attach_ebs_csi_policy = true
  oidc_providers = {
    main = {
      provider_arn               = local.oidc_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name             = local.cluster_name
  addon_name               = "aws-ebs-csi-driver"
  service_account_role_arn = module.ebs_csi_irsa.iam_role_arn
}

resource "kubernetes_storage_class" "gp3" {
  metadata {
    name = "gp3"
    annotations = { "storageclass.kubernetes.io/is-default-class" = "true" }
  }
  storage_provisioner    = "ebs.csi.aws.com"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true
  parameters = { type = "gp3", encrypted = "true" }
}
```

### 2.5 AWS Load Balancer Controller

```hcl
module "alb_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.39"

  role_name                              = "${local.cluster_name}-alb-controller"
  attach_load_balancer_controller_policy = true
  oidc_providers = {
    main = {
      provider_arn               = local.oidc_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }
}

resource "helm_release" "alb_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"
  version    = "1.7.1"

  set { name = "clusterName",                                 value = local.cluster_name }
  set { name = "serviceAccount.create",                       value = "true" }
  set { name = "serviceAccount.name",                         value = "aws-load-balancer-controller" }
  set { name = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn", value = module.alb_irsa.iam_role_arn }
}
```

### 2.6 Jenkins (in-cluster, replaces old EC2 Jenkins)

```hcl
resource "kubernetes_namespace" "jenkins" { metadata { name = "jenkins" } }

resource "helm_release" "jenkins" {
  name       = "jenkins"
  repository = "https://charts.jenkins.io"
  chart      = "jenkins"
  namespace  = kubernetes_namespace.jenkins.metadata[0].name
  version    = "5.1.5"
  values     = [file("${path.module}/../../Jenkins/jenkins-values.yaml")]
}
```

Admin password is set in `Jenkins/jenkins-values.yaml` — **rotate before any public exposure.**

### 2.7 ArgoCD

```hcl
resource "kubernetes_namespace" "argocd" { metadata { name = "argocd" } }

resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  namespace  = kubernetes_namespace.argocd.metadata[0].name
  version    = "6.7.11"

  set { name = "server.service.type", value = "ClusterIP" }
  # expose via Gateway/Ingress later; use port-forward for now
}
```

### 2.8 ArgoCD Applications (point at the manifests repo)

```hcl
locals {
  argocd_apps = ["UI", "Appserver", "DB", "Redis"]
  repo_url    = "https://github.com/<YOU>/E2E-3T.git"
  target_rev  = "main"
}

resource "kubernetes_manifest" "yelb_app" {
  for_each = toset(local.argocd_apps)
  manifest = {
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "yelb-${lower(each.key)}"
      namespace = "argocd"
    }
    spec = {
      project = "default"
      source = {
        repoURL        = local.repo_url
        targetRevision = local.target_rev
        path           = "Kubernetes-Manifests-file/${each.key}"
      }
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = "3-tier"
      }
      syncPolicy = {
        automated = { prune = true, selfHeal = true }
        syncOptions = ["CreateNamespace=true"]
      }
    }
  }
  depends_on = [helm_release.argocd]
}
```

### 2.9 Apply

```bash
cd ../cluster-addons
terraform init
terraform apply
```

~5 minutes. ArgoCD and Jenkins Helm installs are the long tail.

### 2.10 Verify

```bash
kubectl -n kube-system  get deploy aws-load-balancer-controller
kubectl -n argocd       get pods
kubectl -n jenkins      get pods
kubectl -n argocd       get applications
kubectl -n 3-tier   get pods     # first sync may take ~2 min
```

---

## Step 3 — Layer C: gateway

**Provisions:** Gateway API CRDs and a single `Gateway` resource backed by an ALB. The actual `HTTPRoute` lives in `Kubernetes-Manifests-file/UI/` and is synced by ArgoCD.

### 3.1 Install Gateway API CRDs

```hcl
resource "helm_release" "gateway_api_crds" {
  name             = "gateway-api"
  repository       = "https://kubernetes-sigs.github.io/gateway-api"
  chart            = "gateway-api"
  version          = "1.0.0"
  namespace        = "gateway-system"
  create_namespace = true
}
```

### 3.2 Create the Gateway

```hcl
resource "kubernetes_manifest" "yelb_gateway" {
  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "Gateway"
    metadata = {
      name      = "yelb-gateway"
      namespace = "3-tier"
    }
    spec = {
      gatewayClassName = "alb"
      listeners = [{
        name     = "http"
        port     = 80
        protocol = "HTTP"
        allowedRoutes = { namespaces = { from = "Same" } }
      }]
    }
  }
  depends_on = [helm_release.gateway_api_crds]
}
```

### 3.3 Apply

```bash
cd ../gateway
terraform init
terraform apply
```

### 3.4 Get the public URL

```bash
kubectl -n 3-tier get gateway yelb-gateway \
    -o jsonpath='{.status.addresses[0].value}'
```

Open that address in a browser → Yelb UI.

---

## Step 4 — Wire up Jenkins (one-time, UI)

Terraform installs Jenkins but can't create pipeline jobs cleanly. Do this once via the Jenkins UI.

1. Port-forward: `kubectl -n jenkins port-forward svc/jenkins 8080:8080`
2. Open http://localhost:8080, log in with the admin password from `jenkins-values.yaml`.
3. Install plugins: *AWS Credentials, Docker Pipeline, SonarQube Scanner, OWASP Dependency-Check, Pipeline: Stage View*.
4. Credentials → add:
   - `GITHUB` (username + token)
   - `aws-ecr` (AWS access key / secret, or use IRSA on the Jenkins pod — preferred)
5. New Item → Pipeline → "yelb-ui" → Pipeline from SCM → point at `Jenkins-Pipeline-Code/Jenkinsfile-UI`. Repeat for appserver, db.
6. Run each once. First build pushes `:1` to ECR and bumps `image:` in `Kubernetes-Manifests-file/*/deployment.yaml`. ArgoCD syncs.

---

## Teardown

**Reverse order of apply. Skipping this order will leak LBs and EBS volumes.**

```bash
cd terraform/gateway       && terraform destroy
cd ../cluster-addons      && terraform destroy
cd ../foundation          && terraform destroy
```

Then manually: empty the state S3 bucket, delete the bucket + DynamoDB table.

**Common leaks to double-check in the console after destroy:**
- EC2 → Load Balancers (orphaned ALBs from Gateway/Ingress)
- EC2 → Volumes (orphaned EBS from Postgres PVC — set `persistentVolumeReclaimPolicy: Delete` in your StorageClass to avoid)
- EC2 → Security Groups (ALB SGs sometimes linger)
- CloudWatch log groups (`/aws/eks/...`)

---

## IAM minimization (optional)

The initial apply needs broad perms. Once stable, split into:

- **Platform role** (allowed to run `foundation/`): VPC, EKS, IAM, ECR.
- **Addons role** (allowed to run `cluster-addons/` and `gateway/`): EKS describe, Helm/K8s API (via EKS auth), IRSA role creation only in `${cluster_name}-*` namespace.

Terraform [`aws_iam_policy_document`](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) + `access_analyzer` on CloudTrail is the practical way to generate these.

---

## Troubleshooting

| Symptom                                             | Cause                                           | Fix                                                                                 |
|-----------------------------------------------------|-------------------------------------------------|--------------------------------------------------------------------------------------|
| `terraform apply` on Layer B fails with `Unauthorized` | kubeconfig token expired mid-apply              | Re-run; providers refresh tokens per-apply.                                         |
| ArgoCD app stuck in `OutOfSync`                     | Repo path wrong or branch has no commits        | `kubectl -n argocd describe app yelb-ui`; check `status.conditions`.                 |
| Gateway has no address                              | ALB controller not running or lacks IAM         | `kubectl -n kube-system logs deploy/aws-load-balancer-controller`.                   |
| Postgres pod `Pending` forever                      | gp3 StorageClass missing or EBS CSI not installed | `kubectl get storageclass`; re-run Layer B.                                         |
| `helm_release.jenkins` fails with `UPGRADE FAILED`  | Leftover release from prior failed apply        | `helm -n jenkins uninstall jenkins`, re-apply.                                       |
| EKS addon `aws-ebs-csi-driver` fails                | OIDC provider not created yet                   | Confirm `enable_irsa = true` in Layer A, re-apply.                                   |

---

## What this doc intentionally omits

- **Observability** (Prometheus/Grafana) — separate layer, add when needed.
- **GH Actions migration** — covered in a separate doc.
- **Multi-env (dev/stage/prod)** — would need `terraform workspace` or per-env tfvars; out of scope.
- **TLS/ACM** — Gateway listener is HTTP only. Add an HTTPS listener + ACM cert when you have a real domain.
