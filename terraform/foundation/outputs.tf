output "region" {
  value = var.region
}

output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  value = module.eks.cluster_certificate_authority_data
}

output "cluster_oidc_provider_arn" {
  value = module.eks.oidc_provider_arn
}

output "cluster_oidc_issuer_url" {
  value = module.eks.cluster_oidc_issuer_url
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "private_subnet_ids" {
  value = module.vpc.private_subnets
}

output "public_subnet_ids" {
  value = module.vpc.public_subnets
}

output "ecr_repository_urls" {
  value = { for k, v in aws_ecr_repository.yelb : k => v.repository_url }
}

output "update_kubeconfig_command" {
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
  description = "Run this after apply to configure kubectl locally."
}
