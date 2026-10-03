# Deploy Manually via AWS Console

End-to-end deployment of the Yelb 3-tier app on EKS using the **AWS Console wherever possible**. CLI is used only where the console physically cannot do the job (Helm installs, `kubectl apply`, ArgoCD CRs).

> **Status note:** this doc describes the target state. The repo still contains the old React/Node/Mongo app and single-EC2 Jenkins; code migration to Yelb + in-cluster Jenkins is tracked separately. See [deploy-terraform.md](./deploy-terraform.md) for the automated path.

**Why do this manually?** Learning the moving parts, auditing what Terraform abstracts away, or operating in an org where you don't own IaC. For routine use, prefer [deploy-terraform.md](./deploy-terraform.md).

---

## What the console can and cannot do

| Capability                              | Console? | Why                                     |
|-----------------------------------------|----------|-----------------------------------------|
| VPC, subnets, NAT, routing              | ✅ Yes   | Full support                            |
| EKS cluster + managed nodegroup         | ✅ Yes   | Full support                            |
| EKS addons (coredns, vpc-cni, EBS CSI)  | ✅ Yes   | Via EKS → Add-ons tab                   |
| ECR repos                               | ✅ Yes   | Full support                            |
| IAM roles for IRSA                      | ✅ Yes   | Tedious trust-policy JSON editing       |
| Install AWS Load Balancer Controller    | ❌ No    | Helm chart — CLI only                   |
| Install Gateway API CRDs                | ❌ No    | `kubectl apply` from upstream           |
| Install Jenkins                         | ❌ No    | Helm chart                              |
| Install ArgoCD                          | ❌ No    | Helm or raw manifest                    |
| Create ArgoCD Applications              | ❌ No    | Custom resource — kubectl or ArgoCD UI  |
| Create K8s Deployments / Services       | ❌ No    | `kubectl apply`                         |

Sections marked **[CLI]** below cannot be done through the AWS Console.

---

## Prerequisites

- AWS account with ability to create IAM users, VPCs, EKS, EC2.
- Local machine with: AWS CLI 2.15+, kubectl 1.28+, helm 3.12+.
- Browser logged into the AWS Console with the right account/region selector.
- Region used in this doc: **us-east-1**.

---

## Step 1 — Create an IAM admin user (console)

**IAM → Users → Create user**

1. User name: `eks-admin`
2. Attach policy directly: `AdministratorAccess`
3. Create user → open user → **Security credentials** → **Create access key** → *Command Line Interface (CLI)* → download the CSV.
4. Locally: `aws configure` — paste the access key / secret, region `us-east-1`, output `json`.
5. Verify: `aws sts get-caller-identity` returns the eks-admin ARN.

---

## Step 2 — Create the VPC (console)

**VPC → Create VPC → VPC and more**

Fill in:
- Name tag auto-generation: `three-tier`
- IPv4 CIDR: `10.0.0.0/16`
- Number of Availability Zones: **3**
- Number of public subnets: **3**
- Number of private subnets: **3**
- NAT gateways: **In 1 AZ** (cost; use "1 per AZ" for prod HA)
- VPC endpoints: **None**
- DNS options: both enabled

Click **Create VPC** (~2 min).

**After it creates, tag the subnets** so the AWS Load Balancer Controller discovers them:

VPC → Subnets → for each **public** subnet, add tag `kubernetes.io/role/elb = 1`. For each **private** subnet, add tag `kubernetes.io/role/internal-elb = 1`.

> Miss this and the ALB controller will silently refuse to create load balancers.

---

## Step 3 — Create ECR repositories (console)

**ECR → Private registry → Repositories → Create repository**

Create **three** repositories:
- `yelb-ui`
- `yelb-appserver`
- `yelb-db`

Settings for each:
- Image tag mutability: **Immutable**
- Scan on push: **Enabled**

Note the registry URI shown in the list — format `<ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/yelb-ui`. You'll paste it into K8s manifests and Jenkins credentials.

---

## Step 4 — Create the EKS cluster (console)

**EKS → Clusters → Create cluster**

Follow the wizard across four screens.

### 4.1 Configure cluster
- Name: `three-tier-cluster`
- Kubernetes version: **1.28**
- Cluster service role → **Create recommended role** (if first time). This opens IAM in a new tab — accept the defaults (`AmazonEKSClusterPolicy`), name it `eksClusterRole`, then come back and refresh.
- Secrets encryption: off (for demo)
- Tags: `env=demo`

### 4.2 Specify networking
- VPC: the `three-tier` VPC from Step 2
- Subnets: select **all 3 private** and **all 3 public**
- Security groups: leave default
- Cluster endpoint access: **Public** (tighten later with CIDRs)

### 4.3 Observability
- Enable **API** and **Authenticator** control-plane logs (useful for debugging IAM issues)

### 4.4 Select add-ons

Check these (defaults + add EBS CSI):
- `coredns`
- `kube-proxy`
- `vpc-cni`
- `aws-ebs-csi-driver`  ← **add this**
- `eks-pod-identity-agent`  ← **add this**

### 4.5 Review and create

Takes ~12 minutes. The page auto-refreshes.

---

## Step 5 — Create a managed node group (console)

**EKS → Clusters → three-tier-cluster → Compute tab → Add node group**

### 5.1 Configure node group
- Name: `primary`
- Node IAM role → **Create role** (new tab). Attach:
  - `AmazonEKSWorkerNodePolicy`
  - `AmazonEKS_CNI_Policy`
  - `AmazonEC2ContainerRegistryReadOnly`
  - `AmazonEBSCSIDriverPolicy`  ← for the EBS CSI addon to work
  Name: `eks-node-role`. Come back and select it.

### 5.2 Set compute and scaling
- AMI type: `Amazon Linux 2 (AL2_x86_64)`
- Instance types: `t3.medium`
- Disk size: 30 GB
- Desired size: **2**, Min: **2**, Max: **4**

### 5.3 Specify networking
- Subnets: the **3 private** subnets
- Allow SSH: **off**

Create. Takes ~5 minutes.

---

## Step 6 — Local kubeconfig **[CLI]**

The console cannot write to your local kubeconfig.

```bash
aws eks update-kubeconfig --region us-east-1 --name three-tier-cluster
kubectl get nodes
```

You should see 2 nodes `Ready`.

---

## Step 7 — Create the IAM OIDC provider for IRSA (console)

**EKS → Clusters → three-tier-cluster → Overview tab**

Copy the **OpenID Connect provider URL** (looks like `https://oidc.eks.us-east-1.amazonaws.com/id/XXXXXXXXXX`).

Then: **IAM → Identity providers → Add provider**
- Provider type: **OpenID Connect**
- Provider URL: paste the URL above, click **Get thumbprint**
- Audience: `sts.amazonaws.com`
- Add provider.

> If the EKS add-ons (EBS CSI) are already showing `Degraded`, that's because this step is missing. Create the provider, then force addon reconciliation (EKS → Add-ons → aws-ebs-csi-driver → Update now).

---

## Step 8 — IAM roles for IRSA (console)

Two roles needed: EBS CSI (if the addon didn't create it) and AWS Load Balancer Controller.

### 8.1 EBS CSI role

The EKS console *may* have created this automatically when you added the addon. Check: **IAM → Roles**, search for `AmazonEKSTPodIdentity` or `*ebs-csi*`. If present, skip to 8.2.

Otherwise:
- IAM → Roles → Create role → **Web identity**
- Identity provider: your EKS OIDC provider
- Audience: `sts.amazonaws.com`
- Add condition: `*:sub` = `system:serviceaccount:kube-system:ebs-csi-controller-sa`
- Attach policy: `AmazonEBSCSIDriverPolicy`
- Name: `AmazonEKS_EBS_CSI_DriverRole`

Then: **EKS → Add-ons → aws-ebs-csi-driver → Edit** → paste the role ARN → Save.

### 8.2 AWS Load Balancer Controller role

Download the policy JSON from upstream:
```
https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.7.1/docs/install/iam_policy.json
```

- IAM → Policies → Create policy → JSON → paste → name `AWSLoadBalancerControllerIAMPolicy`.
- IAM → Roles → Create role → **Web identity**
  - Identity provider: EKS OIDC
  - Audience: `sts.amazonaws.com`
  - Condition: `*:sub` = `system:serviceaccount:kube-system:aws-load-balancer-controller`
- Attach the policy you just created.
- Name: `AmazonEKSLoadBalancerControllerRole`. **Copy the ARN** — you'll need it in Step 9.

---

## Step 9 — Install AWS Load Balancer Controller **[CLI]**

```bash
kubectl create serviceaccount aws-load-balancer-controller -n kube-system
kubectl annotate serviceaccount -n kube-system aws-load-balancer-controller \
    eks.amazonaws.com/role-arn=arn:aws:iam::<ACCOUNT_ID>:role/AmazonEKSLoadBalancerControllerRole

helm repo add eks https://aws.github.io/eks-charts
helm repo update
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
    -n kube-system \
    --set clusterName=three-tier-cluster \
    --set serviceAccount.create=false \
    --set serviceAccount.name=aws-load-balancer-controller

kubectl -n kube-system get deploy aws-load-balancer-controller
```

Wait for `AVAILABLE=1`.

---

## Step 10 — Set gp3 as default StorageClass **[CLI]**

The EBS CSI addon ships with a `gp2` StorageClass. We want gp3.

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: ebs.csi.aws.com
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
parameters:
  type: gp3
  encrypted: "true"
EOF

# Remove default annotation from gp2
kubectl patch storageclass gp2 \
    -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'
```

---

## Step 11 — Install Gateway API CRDs **[CLI]**

```bash
kubectl apply -f \
    https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.0.0/standard-install.yaml

kubectl get crd gateways.gateway.networking.k8s.io
```

---

## Step 12 — Install Jenkins in-cluster **[CLI]**

```bash
kubectl create namespace jenkins

helm repo add jenkins https://charts.jenkins.io
helm repo update

helm install jenkins jenkins/jenkins \
    -n jenkins \
    -f Jenkins/jenkins-values.yaml

kubectl -n jenkins get pods
```

Access the UI:
```bash
kubectl -n jenkins port-forward svc/jenkins 8080:8080
# open http://localhost:8080
```

Admin password is set in `jenkins-values.yaml`. **Rotate before exposing publicly.**

---

## Step 13 — Install ArgoCD **[CLI]**

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f \
    https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Wait for pods
kubectl -n argocd get pods -w

# Initial admin password
kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath='{.data.password}' | base64 -d; echo

# Access UI
kubectl -n argocd port-forward svc/argocd-server 8081:443
# open https://localhost:8081, user: admin
```

Change the admin password immediately in the UI (User Info → Update Password).

---

## Step 14 — Register Yelb apps in ArgoCD **[CLI]**

Four `Application` CRs — one per Yelb component. Replace `<YOU>` with your GitHub user.

```bash
for comp in UI Appserver DB Redis; do
cat <<EOF | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: yelb-${comp,,}
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/<YOU>/E2E-3T.git
    targetRevision: main
    path: Kubernetes-Manifests-file/${comp}
  destination:
    server: https://kubernetes.default.svc
    namespace: three-tier
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [ "CreateNamespace=true" ]
EOF
done

kubectl -n argocd get applications
```

First sync takes ~1–2 min. Watch:
```bash
kubectl -n three-tier get pods -w
```

---

## Step 15 — Create the Gateway **[CLI]**

The ALB controller watches for `Gateway` resources with `gatewayClassName: alb`.

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: yelb-gateway
  namespace: three-tier
spec:
  gatewayClassName: alb
  listeners:
    - name: http
      port: 80
      protocol: HTTP
      allowedRoutes:
        namespaces:
          from: Same
EOF
```

The `HTTPRoute` for yelb-ui lives in `Kubernetes-Manifests-file/UI/` and is already synced by ArgoCD.

Get the public URL:
```bash
kubectl -n three-tier get gateway yelb-gateway \
    -o jsonpath='{.status.addresses[0].value}'
```

Open in a browser → Yelb UI.

---

## Step 16 — Configure Jenkins pipelines (Jenkins UI)

In the Jenkins UI (http://localhost:8080):

1. **Manage Jenkins → Plugins** → install: *AWS Credentials, Docker Pipeline, SonarQube Scanner, OWASP Dependency-Check, Pipeline: Stage View*.
2. **Manage Jenkins → Credentials → System → Global** → add:
   - `GITHUB` — Username + password (use a PAT with `repo` scope).
   - `ACCOUNT_ID` — Secret text — your 12-digit AWS account ID.
   - `ECR_UI`, `ECR_APPSERVER`, `ECR_DB` — Secret text — repository names.
3. **New Item** → Pipeline:
   - Name: `yelb-ui`
   - Pipeline → Definition: *Pipeline script from SCM*
   - SCM: Git, URL: your repo, credentials: GITHUB
   - Script Path: `Jenkins-Pipeline-Code/Jenkinsfile-UI`
4. Repeat for `yelb-appserver`, `yelb-db`.
5. **Build Now** on each. First build:
   - Builds image → pushes `<ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/yelb-ui:1` to ECR.
   - Updates `image:` tag in `Kubernetes-Manifests-file/UI/deployment.yaml` and commits.
   - ArgoCD detects the commit and syncs within ~3 min.

> **AWS auth from Jenkins:** best practice is to annotate the Jenkins pod's ServiceAccount with an IRSA role that has ECR push rights, not store static access keys. If using static keys, create a Jenkins AWS credential with the access key/secret.

---

## Verification checklist

- [ ] `kubectl get nodes` → 2 Ready
- [ ] `kubectl -n kube-system get deploy aws-load-balancer-controller` → 1/1
- [ ] `kubectl get storageclass` → `gp3 (default)`
- [ ] `kubectl -n argocd get applications` → all 4 `Synced` + `Healthy`
- [ ] `kubectl -n three-tier get pods` → ui, appserver, db, redis all `Running`
- [ ] `kubectl -n three-tier get pvc` → yelb-db PVC `Bound`
- [ ] Gateway address resolves to the Yelb UI
- [ ] Clicking a vote updates both the chart and the "page views" counter

---

## Cleanup (console)

**Reverse order of creation.** Skipping this leaves orphaned ALBs and EBS volumes that bill forever.

1. **Delete the Gateway first (CLI):** `kubectl -n three-tier delete gateway yelb-gateway` — this triggers ALB deletion.
2. **Delete the Yelb PVC:** `kubectl -n three-tier delete pvc --all` — triggers EBS volume deletion.
3. EKS → Clusters → three-tier-cluster → Compute → delete the `primary` node group.
4. EKS → Clusters → three-tier-cluster → Delete cluster.
5. ECR → delete the three repositories.
6. IAM → delete `AmazonEKSLoadBalancerControllerRole`, `AmazonEKS_EBS_CSI_DriverRole`, `eksClusterRole`, `eks-node-role`.
7. VPC → delete `three-tier` VPC (this cascades subnets, route tables, NAT, IGW).
8. EC2 → **check for orphaned**: Load Balancers, Target Groups, Volumes, Security Groups starting with `k8s-`.
9. CloudWatch → Log groups → delete `/aws/eks/three-tier-cluster/*`.

---

## Common console gotchas

| Symptom                                                | Likely cause                                                 | Fix                                                                                     |
|--------------------------------------------------------|--------------------------------------------------------------|------------------------------------------------------------------------------------------|
| EBS CSI addon stays `Degraded`                         | OIDC provider not created, or role ARN not set on addon      | Steps 7 + 8.1, then **Update now** on the addon.                                        |
| ALB never provisions for the Gateway                   | Subnet tags missing                                          | Re-tag per Step 2. Delete + recreate the Gateway to re-trigger.                         |
| Pods stuck `ImagePullBackOff` from your ECR            | Node role missing `AmazonEC2ContainerRegistryReadOnly`       | IAM → `eks-node-role` → attach that policy. No pod restart needed.                      |
| `kubectl` says `error: You must be logged in`          | kubeconfig token expired, or wrong IAM principal             | `aws sts get-caller-identity`; re-run `aws eks update-kubeconfig`.                      |
| ArgoCD app `Unknown` sync status                       | Repo URL unreachable or branch has no manifests at that path | Check Application → **App details** → Conditions tab.                                   |
| Postgres pod `Pending`                                 | No default StorageClass, or `WaitForFirstConsumer` with no node matching | Step 10; `kubectl describe pvc` for exact reason.                                        |
| Jenkins pod `CrashLoopBackOff` after upgrade           | PVC perms, or `jenkins-values.yaml` admin password syntax    | `kubectl -n jenkins logs <pod>`; validate values file against chart.                    |

---

## When to prefer the Terraform path

- Repeating this across more than one environment.
- You want the whole thing destroyable with one command.
- You want state tracked and reviewable in Git.
- Your org requires change review (PR on `Infra-TF/`).

See [deploy-terraform.md](./deploy-terraform.md).
