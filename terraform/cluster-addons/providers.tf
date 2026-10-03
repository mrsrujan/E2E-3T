provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "E2E-3T"
      ManagedBy = "terraform"
      Layer     = "cluster-addons"
    }
  }
}

# ---------------------------------------------------------------------------
# All three Kubernetes-side providers use `exec` auth instead of a static
# token. Reason: data.aws_eks_cluster_auth caches the token at plan time, so
# long applies (ArgoCD + Jenkins Helm installs can take 10+ min) hit the EKS
# 15-minute token TTL mid-stream and fail with `tls: bad record MAC` on large
# payloads (CRD POSTs, openapi/v2 GETs). exec auth re-fetches on every call.
# ---------------------------------------------------------------------------

provider "kubernetes" {
  host                   = local.cluster_endpoint
  cluster_ca_certificate = base64decode(local.cluster_ca)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", local.cluster_name, "--region", var.region]
  }
}

provider "helm" {
  kubernetes {
    host                   = local.cluster_endpoint
    cluster_ca_certificate = base64decode(local.cluster_ca)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", local.cluster_name, "--region", var.region]
    }
  }
}

provider "kubectl" {
  host                   = local.cluster_endpoint
  cluster_ca_certificate = base64decode(local.cluster_ca)
  load_config_file       = false
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", local.cluster_name, "--region", var.region]
  }
}
