# ---------------------------------------------------------------------------
# EBS CSI driver — IRSA role + EKS addon registration (AWS APIs, must stay in TF).
#
# The gp3 StorageClass itself has moved to platform/storage-classes/gp3.yaml
# so ArgoCD manages it. The gp2 un-default annotation stays here because it's
# a one-shot patch on a resource ArgoCD doesn't own (the addon-created gp2 SC).
# ---------------------------------------------------------------------------

module "ebs_csi_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.39"

  role_name             = "${local.cluster_name}-ebs-csi"
  attach_ebs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = local.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name             = local.cluster_name
  addon_name               = "aws-ebs-csi-driver"
  service_account_role_arn = module.ebs_csi_irsa.iam_role_arn

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
}

# Un-default the gp2 StorageClass that ships with the EBS CSI addon so the
# ArgoCD-managed gp3 StorageClass wins the default slot.
resource "kubernetes_annotations" "gp2_undefault" {
  api_version = "storage.k8s.io/v1"
  kind        = "StorageClass"
  metadata { name = "gp2" }
  annotations = {
    "storageclass.kubernetes.io/is-default-class" = "false"
  }
  force = true

  depends_on = [aws_eks_addon.ebs_csi]
}
