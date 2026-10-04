# Step-by-Step: End-to-End Install

Fresh install path for a new cluster. Reflects the current repo state (post-ArgoCD refactor): Terraform handles only AWS APIs + ArgoCD bootstrap; everything else lives in `platform/` and is synced by ArgoCD.

> **Supersedes** `docs/deploy-terraform.md` and `docs/deploy-manual.md`, which describe the pre-refactor layout. Those docs are retained for history until updated.

---

## Prerequisites (one time)

**Local tools:**

| Tool       | Minimum  | Purpose                               |
|------------|----------|---------------------------------------|
| AWS CLI    | 2.15     | Auth, kubeconfig                      |
| Terraform  | 1.6      | All infra                             |
| kubectl    | 1.28     | Verify + Jenkins/ArgoCD port-forward  |
| Helm       | 3.12     | Debug only (TF calls helm)            |
| Git        | any      | Clone + CI commits                    |

**AWS prerequisites:**
- IAM user with `AdministratorAccess` for the initial apply.
- `aws configure` done; `aws sts get-caller-identity` returns your identity.
- **vCPU quota in us-east-1 ≥ 32.** The AWS default of 5 is too low — the EKS nodegroup + kube-system + ArgoCD + Jenkins exceed it. Request a bump at *Service Quotas → EC2 → Running On-Demand Standard* (~24h approval).

**Clone the repo:**

```bash
git clone https://github.com/mrsrujan/E2E-3T.git
cd E2E-3T
```

---

## Step 1 · Bootstrap Terraform state backend (one time per account)

Creates the S3 bucket + DynamoDB lock table shared by all 3 TF layers. Idempotent.

```bash
cd terraform
./bootstrap.sh
```

Output ends with the exact values for `state_bucket` / `region` / `account_id`. For this account the defaults already target `e2e3t-tfstate-640584914236`.

---

## Step 2 · Create `terraform.tfvars` in each layer

```bash
cd terraform
for d in foundation cluster-addons gateway; do
  cp $d/terraform.tfvars.example $d/terraform.tfvars
done
```

Edit if your region or cluster name differs from the defaults.

---

## Step 3 · Foundation layer — ~15 min

**What it creates:** VPC (3 AZ), EKS cluster (1.28), managed nodegroup, 3 ECR repos (`yelb-ui`, `yelb-appserver`, `yelb-db`), IRSA OIDC provider.

```bash
cd terraform/foundation
terraform init
terraform apply
```

**Verify:**

```bash
aws eks update-kubeconfig --region us-east-1 --name 3-tier-cluster
kubectl get nodes          # 1-2 nodes, STATUS=Ready
```

---

## Step 4 · Cluster-addons layer — ~5 min

**What it creates:** EBS CSI driver (EKS addon + IRSA), IRSA role for ALB controller, ArgoCD (Helm), and the single **root ArgoCD Application** (`platform-root`) that watches `platform/`.

```bash
cd ../cluster-addons
terraform init
terraform apply
```

**Verify ArgoCD is up:**

```bash
kubectl -n argocd get pods                 # all Running
kubectl -n argocd get applications          # should list "platform-root"
```

---

## Step 5 · Wait for ArgoCD to sync `platform/` — ~5 min

ArgoCD now discovers every YAML under `platform/` and installs:

| Component       | Source                                              |
|-----------------|------------------------------------------------------|
| ALB controller  | Helm chart `aws.github.io/eks-charts` v1.8.1         |
| Jenkins         | Helm chart `charts.jenkins.io` v5.9.65 (core 2.568.3)|
| gp3 StorageClass| Plain K8s manifest                                   |
| 4× Yelb apps    | Each syncs `Kubernetes-Manifests-file/<Component>/`  |

**Watch it:**

```bash
# Terminal 1 — Applications status
kubectl -n argocd get applications -w

# Terminal 2 — ArgoCD UI
kubectl -n argocd port-forward svc/argocd-server 8081:443
# → open https://localhost:8081
# → user: admin
# → password:
kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath='{.data.password}' | base64 -d; echo
```

Wait until all 7 Applications show `Synced` + `Healthy`:

```
alb-controller   Synced   Healthy
jenkins          Synced   Healthy
yelb-ui          Synced   Healthy
yelb-appserver   Synced   Healthy
yelb-db          Synced   Healthy
yelb-redis       Synced   Healthy
```

**Expected:** `yelb-ui`, `yelb-appserver`, `yelb-db` pods will show `ImagePullBackOff` — ECR is empty until Step 7 runs. That's fine.

---

## Step 6 · Gateway layer — ~2 min

**What it creates:** Gateway API CRDs + the `yelb-gateway` resource (ALB-backed).

```bash
cd ../gateway
terraform init
terraform apply
```

**Verify:**

```bash
kubectl -n 3-tier get gateway yelb-gateway
# ADDRESS column should populate within ~2 min — this is your public URL
```

---

## Step 7 · Wire Jenkins pipelines (one time, UI)

```bash
# Access Jenkins
kubectl -n jenkins port-forward svc/jenkins 8080:8080
# → open http://localhost:8080
# → user: admin
# → password: admin   (change immediately via People → admin → Configure)
```

### 7.1 — Install plugins

**Manage Jenkins → Plugins → Available**, install:

- AWS Credentials
- Docker Pipeline
- SonarQube Scanner
- OWASP Dependency-Check
- Pipeline: Stage View

### 7.2 — Add credentials

**Manage Jenkins → Credentials → System → Global:**

| Kind              | ID            | Value                                                     |
|-------------------|---------------|-----------------------------------------------------------|
| Username/password | `GITHUB`      | your GH username + a PAT with `repo` scope                |
| Secret text       | `ACCOUNT_ID`  | `640584914236`                                            |

### 7.3 — Create 3 Pipeline jobs

For each of `yelb-ui`, `yelb-appserver`, `yelb-db`:

- **New Item → Pipeline** → name `yelb-<component>`
- Pipeline → Definition: *Pipeline script from SCM*
- SCM: Git, URL `https://github.com/mrsrujan/E2E-3T.git`, credentials `GITHUB`
- Branch: `*/main`
- Script Path: `Jenkins-Pipeline-Code/Jenkinsfile-<Component>` (e.g., `Jenkinsfile-UI`, `Jenkinsfile-Appserver`, `Jenkinsfile-DB`)
- Save → **Build Now**

### 7.4 — What the first build does

1. `docker build` the Yelb source in `Application-Code/yelb-<component>/`
2. Push to ECR as `yelb-<component>:1`
3. `sed` the image tag in `Kubernetes-Manifests-file/<Component>/*.yaml`
4. `git commit` + push to `main`
5. ArgoCD detects the commit, syncs within ~3 min, pods come up `Healthy`

---

## Step 8 · Verify the app is live

```bash
# Get the public URL from the Gateway
kubectl -n 3-tier get gateway yelb-gateway \
    -o jsonpath='{.status.addresses[0].value}'
```

Open that URL in a browser → Yelb UI → vote → counter updates.

**Health check from the cluster:**

```bash
kubectl -n 3-tier get pods           # all 4 workloads Running
kubectl -n argocd get applications       # all Synced + Healthy
```

---

## Teardown (reverse order)

```bash
# Delete runtime resources FIRST so ALBs and EBS unprovision cleanly.
kubectl -n 3-tier delete gateway yelb-gateway
kubectl -n 3-tier delete pvc --all
kubectl -n argocd delete application platform-root  # cascades to all child Apps

# Clear any Helm releases ArgoCD may have left behind
helm -n jenkins uninstall jenkins 2>/dev/null || true

# Then destroy TF layers in reverse dependency order
cd terraform/gateway        && terraform destroy
cd ../cluster-addons        && terraform destroy
cd ../foundation            && terraform destroy
```

**Manual cleanup in the AWS Console (common leaks):**

- S3 → empty + delete the `e2e3t-tfstate-640584914236` bucket
- DynamoDB → delete the `e2e3t-tflocks` table
- EC2 → Load Balancers (orphaned ALBs with `k8s-` prefix)
- EC2 → Volumes (orphaned EBS)
- EC2 → Security Groups (`k8s-*`)
- CloudWatch → Log groups (`/aws/eks/*`)

---

## Key gotchas (lessons learned)

1. **`terraform apply` can hit `tls: bad record MAC`** on long runs — the EKS token expires mid-apply. Fixed in current code: all K8s/Helm/kubectl providers use `exec` auth.
2. **ArgoCD `Application` CRD not found at plan time** when installing ArgoCD + Apps in the same apply. Fixed by using `kubectl_manifest` (gavinbunney) instead of `kubernetes_manifest`.
3. **Jenkins chart `5.1.5` plugin-rot** — the chart's pinned Jenkins core couldn't satisfy latest plugins' minimum version. Fixed by pinning `5.9.65` in `platform/jenkins/app.yaml`. **When this breaks again in ~12 months, bump `targetRevision` and `git push` — no TF needed.**
4. **ALB webhook race** — in the old TF layout, parallel Helm releases hit the ALB mutating webhook before its pods had endpoints. Gone, because the ALB chart is now ArgoCD-managed and self-heals.
5. **Single-node capacity** — resource requests in `platform/{alb-controller,jenkins}/app.yaml` are trimmed to fit on one `c7i-flex.large`. If pods get OOM-killed, bump `node_desired_size` to 2 in `terraform/foundation/terraform.tfvars` and re-apply foundation.

---

## How changes work going forward

| Change type                              | What you do                                              |
|------------------------------------------|----------------------------------------------------------|
| App code change (any Yelb component)     | `git push` → Jenkins builds → pushes ECR → bumps tag → ArgoCD syncs |
| K8s manifest change (resources, probes)  | Edit `Kubernetes-Manifests-file/*/*.yaml` → `git push` → ArgoCD syncs |
| Helm chart version bump (ALB, Jenkins)   | Edit `platform/*/app.yaml` `targetRevision` → `git push` → ArgoCD syncs |
| Add a new ArgoCD-managed component       | Drop a new YAML under `platform/<name>/app.yaml` → `git push` → root App discovers it |
| AWS infrastructure change (VPC, EKS, IAM)| Edit `terraform/foundation/*` → `terraform apply`        |
| Rotate Jenkins admin password            | Edit `platform/jenkins/app.yaml` → `git push` → ArgoCD syncs → Jenkins restarts |

**After Step 7, you should rarely run `terraform apply` for the cluster-addons layer.** Everything in-cluster moves via Git.
