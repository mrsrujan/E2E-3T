data "terraform_remote_state" "foundation" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "foundation/terraform.tfstate"
    region = var.region
  }
}

locals {
  cluster_name             = data.terraform_remote_state.foundation.outputs.cluster_name
  cluster_endpoint         = data.terraform_remote_state.foundation.outputs.cluster_endpoint
  cluster_ca               = data.terraform_remote_state.foundation.outputs.cluster_certificate_authority_data
  oidc_provider_arn        = data.terraform_remote_state.foundation.outputs.cluster_oidc_provider_arn
  oidc_provider_issuer_url = data.terraform_remote_state.foundation.outputs.cluster_oidc_issuer_url
}

# aws_eks_cluster_auth removed — providers use `exec` auth (see providers.tf)
# which re-fetches a token on every API call. Static token caching caused
# tls: bad record MAC failures on long applies.
