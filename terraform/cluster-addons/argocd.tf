# ---------------------------------------------------------------------------
# ArgoCD — GitOps controller that reconciles manifests into the cluster.
# ---------------------------------------------------------------------------

resource "kubernetes_namespace" "argocd" {
  metadata { name = "argocd" }
}

resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = "6.7.11"
  namespace  = kubernetes_namespace.argocd.metadata[0].name

  # Keep the server internal; expose via Gateway later if desired.
  set {
    name  = "server.service.type"
    value = "ClusterIP"
  }

  # Disable the dex server (SSO) to save resources on a demo cluster.
  set {
    name  = "dex.enabled"
    value = "false"
  }

  timeout = 600
}

output "argocd_initial_password_cmd" {
  value       = "kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
  description = "Run after apply to fetch the ArgoCD admin password."
}

output "argocd_port_forward" {
  value       = "kubectl -n argocd port-forward svc/argocd-server 8081:443"
  description = "Access the ArgoCD UI at https://localhost:8081 (user: admin)."
}
