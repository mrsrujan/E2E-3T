# ---------------------------------------------------------------------------
# Gateway API CRDs (standard channel) + the actual Gateway resource.
# HTTPRoutes live in the manifests repo and are synced by ArgoCD.
# ---------------------------------------------------------------------------

resource "helm_release" "gateway_api_crds" {
  name             = "gateway-api"
  repository       = "https://kubernetes-sigs.github.io/gateway-api"
  chart            = "gateway-api"
  version          = var.gateway_api_version
  namespace        = "gateway-system"
  create_namespace = true
}

# The ALB implementation of GatewayClass is provided by the AWS Load Balancer
# Controller (installed in cluster-addons layer). It auto-creates an `alb`
# GatewayClass once CRDs are present.

resource "kubernetes_manifest" "yelb_gateway" {
  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "Gateway"
    metadata = {
      name      = "yelb-gateway"
      namespace = var.gateway_namespace
    }
    spec = {
      gatewayClassName = "alb"
      listeners = [{
        name     = "http"
        port     = 80
        protocol = "HTTP"
        allowedRoutes = {
          namespaces = { from = "Same" }
        }
      }]
    }
  }

  depends_on = [helm_release.gateway_api_crds]
}

output "gateway_address_cmd" {
  value       = "kubectl -n ${var.gateway_namespace} get gateway yelb-gateway -o jsonpath='{.status.addresses[0].value}'"
  description = "Run after apply to get the public ALB DNS name."
}
