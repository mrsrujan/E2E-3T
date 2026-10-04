terraform {
  required_version = ">= 1.6"

  backend "s3" {
    bucket         = "e2e3t-tfstate-640584914236"
    key            = "gateway/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "e2e3t-tflocks"
    encrypt        = true
  }

  required_providers {
    aws        = { source = "hashicorp/aws", version = "~> 5.40" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.27" }
    helm       = { source = "hashicorp/helm", version = "~> 2.13" }
    # kubectl provider is used for the Gateway resource — unlike
    # kubernetes_manifest it doesn't validate CRDs at plan time, so it works
    # in the same apply that installs the Gateway API CRDs.
    kubectl = { source = "gavinbunney/kubectl", version = "~> 1.14" }
    # http provider fetches the Gateway API CRD YAML from GitHub releases.
    # Gateway API is NOT distributed as a Helm chart — only as raw multi-doc YAML.
    http = { source = "hashicorp/http", version = "~> 3.4" }
  }
}
