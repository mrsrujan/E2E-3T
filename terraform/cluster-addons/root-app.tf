# ---------------------------------------------------------------------------
# Root ArgoCD Application — the single thing Terraform tells ArgoCD about.
#
# Points at platform/ with directory.recurse=true. ArgoCD walks every subdir
# and applies every YAML it finds (plain K8s manifests and child Application
# CRs alike). This is the standard "app-of-apps" bootstrap pattern.
#
# After this is applied, chart upgrades, new add-ons, and reorg all happen
# via Git PRs to platform/. No more `terraform apply` for cluster workloads.
# ---------------------------------------------------------------------------

resource "kubectl_manifest" "root_app" {
  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name       = "platform-root"
      namespace  = kubernetes_namespace.argocd.metadata[0].name
      finalizers = ["resources-finalizer.argocd.argoproj.io"]
    }
    spec = {
      project = "default"

      source = {
        repoURL        = var.argocd_repo_url
        targetRevision = var.argocd_target_revision
        path           = "platform"
        directory = {
          recurse = true
        }
      }

      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = kubernetes_namespace.argocd.metadata[0].name
      }

      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
        syncOptions = [
          "CreateNamespace=true",
          "ServerSideApply=true",
        ]
      }
    }
  })

  wait             = false
  wait_for_rollout = false

  depends_on = [helm_release.argocd]
}
