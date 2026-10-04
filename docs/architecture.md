# Architecture

Two views of the same system. **High-level** for a 10-second overview; **detail** when you need to debug or plan a change.

Both diagrams are kept as Mermaid sources in `assets/architecture-*.mmd` so they're text-diffable in PRs. GitHub renders them inline below.

> The historical GIF from the upstream fork is at [`assets/legacy-3-tier.gif`](../assets/legacy-3-tier.gif) — it describes the pre-migration stack (React + Node + Mongo on EC2-hosted Jenkins) and is kept for reference only.

---

## 1 · High-level

What runs where, and how traffic + GitOps loop flow. Zero infrastructure detail.

![High-level architecture](../assets/architecture-high-level.png)

<details>
<summary>Mermaid source (rendered above)</summary>

```mermaid
flowchart LR
    user([👤 User])
    gh[("GitHub<br/>mrsrujan/E2E-3T")]

    subgraph CLOUD["AWS · us-east-1 · 640584914236"]
        direction LR
        gw["ALB<br/>via Gateway API"]
        ecr[("Private ECR<br/>yelb-ui · yelb-appserver · yelb-db")]

        subgraph EKS["EKS: 3-tier-cluster"]
            direction TB
            yelb["Yelb<br/>(ui · appserver · db · redis)"]
            cd["ArgoCD<br/>auto-sync"]
            ci["Jenkins<br/>3 pipelines"]
        end
    end

    user ==> gw ==> yelb
    ci -- "1 · build + push" --> ecr
    ci -- "2 · bump image tag" --> gh
    gh -- "3 · watch main" --> cd
    cd -- "4 · reconcile" --> yelb
    ecr -. "5 · pull" .-> yelb

    classDef cloud fill:#fff8e1,stroke:#f9a825,color:#333
    classDef cluster fill:#e3f2fd,stroke:#1565c0,color:#0d47a1
    classDef store fill:#f3e5f5,stroke:#6a1b9a,color:#4a148c
    class CLOUD cloud
    class EKS cluster
    class ecr,gh store
```

</details>

**The 5 numbered steps are the GitOps loop:**
1. Jenkins builds the image and pushes to ECR.
2. Jenkins commits an image-tag bump into the manifests repo on GitHub.
3. ArgoCD (polling or webhook) detects the commit on `main`.
4. ArgoCD reconciles — applies the new manifest to the cluster.
5. Kubelet pulls the new image from ECR.

User requests go `→ ALB → yelb-ui → yelb-appserver → yelb-db + redis`. No step bypasses GitOps once the cluster is up.

---

## 2 · Detail

Terraform layers, namespaces, service ports, probes, IRSA, PVC. Everything a reviewer or on-call needs to debug the system.

![Detailed architecture](../assets/architecture-detail.png)

<details>
<summary>Mermaid source (rendered above)</summary>

```mermaid
flowchart TB
    user([👤 User browser])
    gh[("GitHub<br/>mrsrujan/E2E-3T<br/>main")]

    subgraph TF["terraform/ · 3 layers · apply in order"]
        direction LR
        tfA["foundation<br/>VPC · EKS · nodegroup<br/>ECR · IRSA OIDC"]
        tfB["cluster-addons<br/>EBS CSI · ALB Ctrl<br/>Jenkins · ArgoCD · Apps"]
        tfC["gateway<br/>Gateway API CRDs<br/>Gateway resource"]
        tfA --> tfB --> tfC
    end

    subgraph AWS["AWS · us-east-1 · account 640584914236"]
        direction TB

        subgraph VPC["VPC 10.0.0.0/16 · 3 AZ"]
            direction TB
            subgraph PUB["Public subnets"]
                alb["ALB · yelb-gateway<br/>listener :80"]
                nat["NAT Gateway"]
            end
            subgraph PRIV["Private subnets · 2× t3.medium nodes"]
                direction TB

                subgraph NS1["ns: 3-tier"]
                    direction TB
                    hr["HTTPRoute → yelb-gateway"]
                    ui["yelb-ui × 2<br/>:80 nginx<br/>liveness: GET /"]
                    app["yelb-appserver × 2<br/>:4567 Sinatra<br/>liveness: TCP"]
                    db[("yelb-db · StatefulSet<br/>:5432 Postgres<br/>liveness: pg_isready")]
                    redis[("redis-server<br/>:6379")]
                end

                subgraph NSARGO["ns: argocd"]
                    argo["ArgoCD controller<br/>Applications:<br/>• yelb-ui<br/>• yelb-appserver<br/>• yelb-db<br/>• yelb-redis<br/>automated + prune + selfHeal"]
                end

                subgraph NSJEN["ns: jenkins"]
                    jenk["Jenkins (Helm)<br/>Jenkinsfile-UI<br/>Jenkinsfile-Appserver<br/>Jenkinsfile-DB"]
                end

                subgraph NSSYS["ns: kube-system"]
                    albc["AWS LB Controller<br/>+ IRSA"]
                    csi["EBS CSI Driver<br/>+ IRSA → gp3 default SC"]
                end
            end
        end

        ebs[("EBS gp3 · 10 Gi<br/>yelb-db PVC")]
        ecr[("Private ECR<br/>yelb-ui · yelb-appserver · yelb-db<br/>IMMUTABLE tags · scan on push")]
        iam["IRSA Roles<br/>• ebs-csi<br/>• alb-controller"]
    end

    user ==> alb
    alb ==> hr
    hr ==> ui
    ui -- "/api proxy" --> app
    app --> db
    app --> redis
    db -. PVC .-> ebs

    jenk -- "1 · docker build" --> ecr
    jenk -- "2 · git push<br/>(bump image tag)" --> gh
    gh -- "3 · watch" --> argo
    argo -- "4 · kubectl apply" --> NS1
    ecr -. "5 · image pull" .-> ui
    ecr -. "5 · image pull" .-> app
    ecr -. "5 · image pull" .-> db

    TF -. provisions .-> VPC
    TF -. provisions .-> ecr
    TF -. provisions .-> iam
    TF -. installs .-> argo
    TF -. installs .-> jenk
    albc -- controls --> alb
    csi -. provisions .-> ebs

    classDef tf fill:#f3e5f5,stroke:#6a1b9a,color:#4a148c
    classDef cloud fill:#fff8e1,stroke:#f9a825,color:#333
    classDef ns fill:#e3f2fd,stroke:#1565c0,color:#0d47a1
    classDef store fill:#ede7f6,stroke:#5e35b1,color:#311b92
    class TF tf
    class AWS,VPC,PUB,PRIV cloud
    class NS1,NSARGO,NSJEN,NSSYS ns
    class ecr,ebs,gh,iam store
```

</details>

### Reading the detail diagram

- **Thick arrows (`==>`)** = user data plane, request path.
- **Thin arrows (`-->`)** = control plane / service-to-service.
- **Dotted arrows (`-.->`)** = provisioning or passive relationships (TF creates resource; kubelet pulls image).
- **Numbered edges 1–5** = the GitOps + image pull loop (same as the high-level view, expanded).

### Resources per Terraform layer

| Layer            | What it creates                                                                                                          |
|------------------|---------------------------------------------------------------------------------------------------------------------------|
| `foundation/`    | VPC (3 AZ), EKS 1.28, managed nodegroup (2× t3.medium), 3 ECR repos, IAM OIDC provider for IRSA                           |
| `cluster-addons/`| EBS CSI driver (addon + IRSA + gp3 StorageClass), ALB Controller (Helm + IRSA), Jenkins (Helm), ArgoCD (Helm + 4 Apps)    |
| `gateway/`       | Gateway API CRDs (Helm), the `yelb-gateway` resource                                                                       |

### Re-rendering the PNGs

The PNGs in `assets/` are generated from the `.mmd` source files via `mermaid-cli`. To regenerate after an edit:

```bash
# First time only — Puppeteer needs a Chromium:
npx -y puppeteer@latest browsers install chrome

# Point mmdc at the installed Chrome (path varies by OS):
cat > /tmp/.puppeteer.json <<EOF
{ "executablePath": "C:\\\\Users\\\\<you>\\\\.cache\\\\puppeteer\\\\chrome\\\\win64-154.0.8037.57\\\\chrome-win64\\\\chrome.exe",
  "args": ["--no-sandbox"] }
EOF

# Render:
npx -y @mermaid-js/mermaid-cli@latest -i assets/architecture-high-level.mmd -o assets/architecture-high-level.png -b white -s 3 -p /tmp/.puppeteer.json
npx -y @mermaid-js/mermaid-cli@latest -i assets/architecture-detail.mmd    -o assets/architecture-detail.png    -b white -s 3 -p /tmp/.puppeteer.json
```

On Linux/macOS, point `executablePath` at your system Chromium/Chrome, or install via puppeteer and use the path it prints.

If you only need the diagrams rendered inside GitHub, you don't need to regenerate PNGs — the Mermaid code fences in this file render natively.
