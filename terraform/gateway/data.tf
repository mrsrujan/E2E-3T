data "terraform_remote_state" "foundation" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "foundation/terraform.tfstate"
    region = var.region
  }
}

locals {
  cluster_name     = data.terraform_remote_state.foundation.outputs.cluster_name
  cluster_endpoint = data.terraform_remote_state.foundation.outputs.cluster_endpoint
  cluster_ca       = data.terraform_remote_state.foundation.outputs.cluster_certificate_authority_data
}

# aws_eks_cluster_auth removed — providers use `exec` auth.
