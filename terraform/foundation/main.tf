data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 2)

  private_subnets = [for i, az in local.azs : cidrsubnet(var.vpc_cidr, 8, i + 1)]
  public_subnets  = [for i, az in local.azs : cidrsubnet(var.vpc_cidr, 8, i + 101)]
}

# ---------------------------------------------------------------------------
# VPC
# ---------------------------------------------------------------------------
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.5"

  name = "${var.cluster_name}-vpc"
  cidr = var.vpc_cidr
  azs  = local.azs

  private_subnets = local.private_subnets
  public_subnets  = local.public_subnets

  enable_nat_gateway   = true
  single_nat_gateway   = var.single_nat_gateway
  enable_dns_hostnames = true
  enable_dns_support   = true

  # Tags required for AWS Load Balancer Controller subnet auto-discovery.
  public_subnet_tags = {
    "kubernetes.io/role/elb"                    = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"           = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}

# ---------------------------------------------------------------------------
# EKS cluster + managed node group
# ---------------------------------------------------------------------------
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.8"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  cluster_endpoint_public_access = true
  enable_irsa                    = true

  # Grant the IAM principal running terraform full cluster-admin via EKS access entries.
  enable_cluster_creator_admin_permissions = true

  eks_managed_node_groups = {
    primary = {
      instance_types = [var.node_instance_type]
      min_size       = var.node_min_size
      max_size       = var.node_max_size
      desired_size   = var.node_desired_size

      iam_role_additional_policies = {
        # Required for EBS CSI driver when running on node (defense in depth
        # alongside IRSA on the controller SA).
        AmazonEBSCSIDriverPolicy = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
      }
    }
  }
}

# ---------------------------------------------------------------------------
# ECR repositories
# ---------------------------------------------------------------------------
resource "aws_ecr_repository" "yelb" {
  for_each = toset(var.ecr_repositories)

  name                 = each.key
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}
