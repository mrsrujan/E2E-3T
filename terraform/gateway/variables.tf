variable "region" {
  description = "AWS region (must match foundation layer)"
  type        = string
  default     = "us-east-1"
}

variable "state_bucket" {
  description = "S3 bucket holding foundation layer remote state"
  type        = string
}

variable "gateway_namespace" {
  description = "Namespace where the Gateway resource lives"
  type        = string
  default     = "3-tier"
}

variable "gateway_api_version" {
  description = "Gateway API CRDs chart version"
  type        = string
  default     = "1.0.0"
}
