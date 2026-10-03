terraform {
  required_version = ">= 1.6"

  backend "s3" {
    bucket         = "e2e3t-tfstate-640584914236"
    key            = "cluster-addons/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "e2e3t-tflocks"
    encrypt        = true
  }

  required_providers {
    aws        = { source = "hashicorp/aws", version = "~> 5.40" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.27" }
    helm       = { source = "hashicorp/helm", version = "~> 2.13" }
    # kubectl provider is used for the root ArgoCD Application — unlike
    # kubernetes_manifest it doesn't validate CRDs at plan time, so it works
    # in the same apply that installs ArgoCD + its CRDs.
    kubectl = { source = "gavinbunney/kubectl", version = "~> 1.14" }
  }
}
