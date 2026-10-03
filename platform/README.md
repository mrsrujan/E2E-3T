# platform/

Everything in-cluster that **ArgoCD** owns. Terraform bootstraps ArgoCD once; after that, chart upgrades and new add-ons are Git PRs — no `terraform apply`.

## How it works

`terraform/cluster-addons/root-app.tf` creates **one** ArgoCD Application (`platform-root`) that points at this folder with `directory.recurse: true`. ArgoCD walks every subdir and applies every YAML it finds. Most of them are themselves ArgoCD `Application` CRs (the **app-of-apps** pattern), so each component gets its own self-healing sync lifecycle.

```
platform/
├── alb-controller/
│   └── app.yaml              Application → aws.github.io/eks-charts
├── jenkins/
│   └── app.yaml              Application → charts.jenkins.io (chart 5.9.65)
├── storage-classes/
│   └── gp3.yaml              StorageClass (plain K8s manifest, cluster-scoped)
└── yelb/
    ├── ui.yaml               Application → Kubernetes-Manifests-file/UI
    ├── appserver.yaml        Application → Kubernetes-Manifests-file/Appserver
    ├── db.yaml               Application → Kubernetes-Manifests-file/DB
    └── redis.yaml            Application → Kubernetes-Manifests-file/Redis
```

## Adding something new

1. Create a subdir under `platform/`.
2. Drop a YAML in it (either an ArgoCD `Application` for Helm/chart stuff, or plain K8s manifests).
3. `git push`. ArgoCD discovers and syncs within ~3 min (polling) or instantly if webhook is wired.

No Terraform changes. No `apply`. No chart-rot-breaks-apply pattern.

## What's still in Terraform

Only AWS APIs and the ArgoCD bootstrap:

- `terraform/foundation/` — VPC, EKS, nodegroup, ECR, IRSA OIDC provider
- `terraform/cluster-addons/` — EBS CSI addon registration, **IRSA roles** (ebs-csi + alb-controller), ArgoCD install, root App

## Chart rot

When a chart's upstream dependencies bump their minimum Jenkins / K8s version and the chart you pinned breaks:
- **Old pain:** `terraform apply` fails → debug `helm_release` / `kubernetes_manifest` provider → force-replace
- **New pain:** ArgoCD shows the Application as `Degraded` with a clear message → bump `targetRevision` in `app.yaml` → `git push` → done
