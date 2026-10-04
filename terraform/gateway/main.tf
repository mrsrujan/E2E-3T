# ---------------------------------------------------------------------------
# Gateway API CRDs (standard channel) + the actual Gateway resource.
# HTTPRoutes live in the manifests repo and are synced by ArgoCD.
#
# Gateway API is NOT distributed as a Helm chart — only as a multi-doc YAML
# in GitHub releases. We fetch the raw YAML via the http provider, split it
# into individual CRDs with kubectl_file_documents, then apply each one.
# ---------------------------------------------------------------------------

data "http" "gateway_api_crds" {
  url = "https://github.com/kubernetes-sigs/gateway-api/releases/download/v${var.gateway_api_version}/standard-install.yaml"
}

data "kubectl_file_documents" "gateway_api_crds" {
  content = data.http.gateway_api_crds.response_body
}

resource "kubectl_manifest" "gateway_api_crds" {
  for_each         = data.kubectl_file_documents.gateway_api_crds.manifests
  yaml_body        = each.value
  wait             = false
  wait_for_rollout = false
}

# The ALB implementation of GatewayClass is provided by the AWS Load Balancer
# Controller (installed in cluster-addons layer). It auto-creates an `alb`
# GatewayClass once CRDs are present.

resource "kubectl_manifest" "yelb_gateway" {
  yaml_body = yamlencode({
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
  })

  wait             = false
  wait_for_rollout = false

  depends_on = [kubectl_manifest.gateway_api_crds]
}

output "gateway_address_cmd" {
  value       = "kubectl -n ${var.gateway_namespace} get gateway yelb-gateway -o jsonpath='{.status.addresses[0].value}'"
  description = "Run after apply to get the public ALB DNS name."
}
