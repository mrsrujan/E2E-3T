# ---------------------------------------------------------------------------
# AWS Load Balancer Controller — IRSA role ONLY.
#
# The Helm chart install has moved to ArgoCD: see platform/alb-controller/app.yaml.
# This role is referenced by ServiceAccount annotation in that chart's values.
#
# The role name is deterministic ("<cluster_name>-alb-controller") so the
# ArgoCD App can hardcode the ARN. If you change role_name here, also update
# platform/alb-controller/app.yaml.
# ---------------------------------------------------------------------------

module "alb_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.39"

  role_name                              = "${local.cluster_name}-alb-controller"
  attach_load_balancer_controller_policy = true

  oidc_providers = {
    main = {
      provider_arn               = local.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }
}

output "alb_controller_role_arn" {
  value       = module.alb_irsa.iam_role_arn
  description = "Hardcode this ARN in platform/alb-controller/app.yaml → eks.amazonaws.com/role-arn"
}
