variable "region" {
  description = "AWS region (must match foundation layer)"
  type        = string
  default     = "us-east-1"
}

variable "state_bucket" {
  description = "S3 bucket holding foundation layer remote state"
  type        = string
}

variable "argocd_repo_url" {
  description = "Git URL that the root ArgoCD App tracks (contains platform/ folder)"
  type        = string
  default     = "https://github.com/mrsrujan/E2E-3T.git"
}

variable "argocd_target_revision" {
  description = "Git branch/tag/commit for the root App to track"
  type        = string
  default     = "main"
}
