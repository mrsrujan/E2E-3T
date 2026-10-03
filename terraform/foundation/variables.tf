variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
  default     = "3-tier-cluster"
}

variable "cluster_version" {
  description = "EKS Kubernetes version"
  type        = string
  default     = "1.34"
}

variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
  default     = "10.0.0.0/16"
}

variable "node_instance_type" {
  description = "EC2 instance type for the managed node group"
  type        = string
  default     = "c7i-flex.large"
}

variable "node_desired_size" {
  description = "Desired node count"
  type        = number
  default     = 1
}

variable "node_min_size" {
  description = "Minimum node count"
  type        = number
  default     = 1
}

variable "node_max_size" {
  description = "Maximum node count"
  type        = number
  default     = 2
}

variable "ecr_repositories" {
  description = "ECR repository names to create"
  type        = list(string)
  default     = ["yelb-ui", "yelb-appserver", "yelb-db"]
}

variable "single_nat_gateway" {
  description = "Use a single NAT gateway (cheaper, not HA). Set false for prod."
  type        = bool
  default     = true
}
