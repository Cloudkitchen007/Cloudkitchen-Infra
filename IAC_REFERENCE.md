# CloudKitchen — Infrastructure as Code (Terraform): Definitive Reference

> Fourth and final companion document. The set:
> - `AWS_CLOUD_REFERENCE.md` — **what** AWS resources exist and why (service-oriented).
> - `cloudkitchen-gitops/K8S_REFERENCE.md` — the **Kubernetes / GitOps** layer.
> - `cloudkitchen-app/CICD_REFERENCE.md` — the **CI/CD** pipelines.
> - **this** — the **Terraform / IaC mechanics**: how the code, state, variables,
>   providers, and lifecycle actually work. Where `AWS_CLOUD_REFERENCE.md` answers
>   "what is this AWS service for", this answers "how is it coded, stored, and run".

---

## 0. How To Use This Document (instructions for an AI assistant)

You are reading the authoritative description of CloudKitchen's Infrastructure-as-Code.
When answering an IaC/Terraform question about this project:

1. **Prefer this document over generic Terraform knowledge.** It describes the actual
   code in `cloudkitchen-infra`: a **flat root module** (no child modules) of ~15 `.tf`
   files, plus a separate `bootstrap/` module for the state backend.
2. **Every claim is grounded in real files.** Section 21 maps concept → file. Resource
   counts in §8 come from the actual code.
3. **Two distinctions matter most:**
   - **Bootstrap vs main:** the S3/DynamoDB **state backend** is created by a separate
     `bootstrap/` Terraform project (with its own *local* state) — it cannot be stored
     in the very state it manages (chicken-and-egg, §4).
   - **Two-phase apply:** `var.eks_api_origin` is empty on the first apply and set to
     the live NLB DNS on a second apply, so CloudFront can route `/api` + `/auth` to
     the cluster (§10). This is the single most important IaC nuance in the project.
4. **Some in-repo comments are stale.** `main.tf`'s header still describes the old
   EC2/ALB topology; `backend.tf`'s header says the backend is "commented out" but it
   is in fact **active**. Trust the *resources*, not the legacy prose — this document
   flags each known discrepancy.
5. **Account `256603361470`, region `ap-south-1`, project prefix `cloudkitchen`.**

---

## 1. Overview

### 1.1 IaC philosophy
All AWS infrastructure is declared in Terraform in the `cloudkitchen-infra` repo and
applied either by `terraform.yml` (CI, gated) or `deploy.sh` (local, one-shot).
Terraform owns everything *except* the Kubernetes NLB(s), which Kubernetes creates at
runtime and which therefore live **outside** Terraform state (this drives destroy
ordering — §12).

### 1.2 Structure at a glance
- **Flat root module.** No `module {}` blocks; every resource is top-level in the root.
  Files are split **by concern** (one file ≈ one subsystem), not by module.
- **Two Terraform projects in the repo:**
  - the **root** (the real infrastructure), state in S3.
  - **`bootstrap/`** (creates the S3 bucket + DynamoDB lock table the root uses), state
    kept **locally** in `bootstrap/terraform.tfstate`.
- **Providers:** `hashicorp/aws >= 4.0` and `hashicorp/random ~> 3.0`.
- **State:** S3 remote backend with DynamoDB locking, encrypted.

### 1.3 Relationship to the other three pillars
- IaC **creates the EKS cluster** that the K8s/GitOps layer runs on.
- The **CI/CD** infra pipeline (`terraform.yml`) runs this code.
- IaC **outputs** (CloudFront URL/id, bucket names, RDS endpoint, SQS URLs, IRSA ARNs)
  feed `deploy.sh`, the SPA build, and the Helm values.

---

## 2. Repository & File Layout

| File | Lines | Responsibility |
|------|------:|----------------|
| `main.tf` | 370 | Terraform/provider block, locals, **VPC, subnets, IGW, NAT, route tables, security groups, RDS, random_password, DB subnet group** |
| `addons.tf` | 503 | **CloudFront, S3 buckets, OAC, API Gateway, presign/notification Lambdas, SNS, CloudWatch alarms, AWS Config (gated)** |
| `dr-agent.tf` | 248 | Disaster-recovery agent: Lambda + EventBridge schedule + IAM |
| `eks.tf` | 219 | **EKS cluster, managed node group, add-ons, subnet EKS tags, eks→db SG rule** |
| `irsa.tf` | 194 | **OIDC provider, IRSA roles/policies (ai/order/eso), app-runtime Secrets Manager secret** |
| `variables.tf` | 176 | all input variables |
| `auth.tf` | 166 | Amazon Cognito (user pools + clients) |
| `ecr.tf` | 164 | 5 ECR repos + lifecycle policies |
| `outputs.tf` | 308 | all outputs |
| `sqs.tf` | 62 | orders queue + dead-letter queue |
| `backend.tf` | 41 | **active** S3 backend config block |
| `state-backend.tf` | 47 | *legacy/redundant* state bucket+lock resources (see §4.4) |
| `bootstrap/main.tf` | 96 | creates the real state bucket + DynamoDB lock |
| `bootstrap/outputs.tf` | 29 | prints backend config snippet |
| `bootstrap/variables.tf` | 5 | `aws_region` for bootstrap |

---

## 3. Terraform Settings & Providers

### 3.1 The `terraform {}` block (in `main.tf`)
```hcl
terraform {
  required_version = ">= 1.0.0"
  required_providers {
    aws    = { source = "hashicorp/aws", version = ">= 4.0" }
    random = { source = "hashicorp/random", version = "~> 3.0" }
  }
}
provider "aws" { region = var.aws_region }
```
- **`required_version >= 1.0.0`** is the floor. The **CI pipeline pins `~1.9`**
  (`terraform.yml` `setup-terraform`), so treat ~1.9 as the de-facto version.
- **`random`** provides `random_password` for the RDS master password (§9.4).
- The provider is region-only; credentials come from the environment (AWS keys in CI,
  or the operator's `aws configure` locally).

### 3.2 The bootstrap project's settings (`bootstrap/main.tf`)
Separate `terraform {}` (`required_version >= 1.0.0`, `aws >= 4.0`), **no backend
block** → local state. It is deliberately minimal so it can run before any remote
state exists.

---

## 4. State Management

### 4.1 The active backend (`backend.tf`)
```hcl
terraform {
  backend "s3" {
    bucket         = "cloudkitchen-tfstate-256603361470"
    key            = "cloudkitchen/terraform.tfstate"
    region         = "ap-south-1"
    dynamodb_table = "cloudkitchen-tfstate-lock"
    encrypt        = true
  }
}
```
- **Remote state in S3**, encrypted, versioned (set on the bucket by bootstrap).
- **DynamoDB table `cloudkitchen-tfstate-lock`** provides state locking so two applies
  can't corrupt state. (You'll see "Acquiring state lock…/Releasing state lock…" in CI
  logs — that's this table.)
- **Backend blocks cannot use variables** — bucket/table/region are literal strings.
- The header comment in `backend.tf` says the block is "commented out / local state".
  **That is stale — the block is active.** Trust the code.

### 4.2 The bootstrap module (`bootstrap/`)
Creates exactly what the backend needs, before the backend can exist:
- `aws_s3_bucket.tfstate` → `cloudkitchen-tfstate-<account_id>` with **versioning**,
  **AES256 SSE**, full **public-access block**, a lifecycle rule expiring noncurrent
  versions after 90 days, and `force_destroy = true` (for teardown).
- `aws_dynamodb_table.tfstate_lock` → `cloudkitchen-tfstate-lock`, `PAY_PER_REQUEST`,
  hash key `LockID`.
- Outputs include a ready-to-paste `backend_config_snippet`.

### 4.3 The chicken-and-egg (why bootstrap is separate)
Terraform can't store its backend's own bucket *inside* that backend. So bootstrap runs
**first** with **local state**, creates the bucket+table, and only then can the root
project use them. `deploy.sh` automates this: it runs `bootstrap` (init+apply) before
the main `init`+`apply`.

### 4.4 `state-backend.tf` — a redundant/legacy file (important nuance)
The **root** also contains `state-backend.tf`, which declares a *second* state bucket
(`<project>-terraform-state-<account>`) and lock table (`<project>-terraform-locks`).
**These are NOT the backend in use** (the backend points at the bootstrap-created
`cloudkitchen-tfstate-*`). They are managed *by* the root state but never store it —
effectively unused leftovers from an earlier approach. If you see two state buckets in
the account, that's why. Safe to remove this file to reduce confusion, but harmless if
left.

### 4.5 State corruption recovery (battle-tested)
A broken-pipe during `terraform apply`/push can corrupt or lock state. Recovery:
`terraform force-unlock <LOCK_ID>` to clear a stuck lock; for a corrupted push,
`terraform state push <good.tfstate>` from a known-good copy (S3 versioning keeps prior
versions you can retrieve).

---

## 5. Input Variables (`variables.tf`)

### 5.1 Full variable table
| Variable | Type | Default | Sensitive | Notes |
|----------|------|---------|:---------:|-------|
| `aws_region` | string | `ap-south-1` | | |
| `project_name` | string | `cloudkitchen` | | naming prefix |
| `environment` | string | `production` | | |
| `vpc_cidr` | string | `10.0.0.0/16` | | |
| `availability_zones` | list | `[ap-south-1a, ap-south-1b]` | | 2 AZs |
| `public_subnet_cidrs` | list | `10.0.1.0/24, 10.0.2.0/24` | | |
| `private_app_subnet_cidrs` | list | `10.0.3.0/24, 10.0.4.0/24` | | |
| `private_db_subnet_cidrs` | list | `10.0.5.0/24, 10.0.6.0/24` | | |
| `global_tags` | map | `{Project, ManagedBy}` | | merged onto everything |
| `web_instance_type` | string | `t3.small` | | legacy (EC2 topology) |
| `app_instance_type` | string | `t3.small` | | legacy (EC2 topology) |
| `key_name` | string | `ustproject-mb` | | legacy EC2 SSH key |
| `db_name` | string | `cloudkitchen` | | |
| `db_username` | string | `postgres` | | |
| `db_instance_class` | string | `db.t3.micro` | | |
| `github_repo` | string | (a public repo URL) | | informational |
| `slack_webhook_url` | string | `""` | ✅ | Alertmanager → Slack |
| `eks_api_origin` | string | `""` | | **second-apply NLB DNS** (§10) |
| `cors_origins` | string | `*` | | backend CORS |
| `admin_email` | string | `pruthvigbhaveri@gmail.com` | | SNS alarm target |
| `hf_api_token` | string | *(none — required)* | ✅ | HuggingFace token |
| `domain_name` | string | `""` | | future ACM/custom domain |
| `enable_aws_config` | bool | `false` | | gates AWS Config resources |

### 5.2 The only required variable
**`hf_api_token` has no default** → it must be supplied. CI passes it as
`TF_VAR_hf_api_token` (from the `HF_API_TOKEN` secret); `deploy.sh` writes it into
`terraform.tfvars` from `$HF_API_TOKEN`. **Every other variable has a default**, which
is exactly why CI `plan` succeeds with only that one injected (§13).

### 5.3 Lesson learned: required vars break non-interactive CI
Two now-removed variables (`web_ami_id`, `app_ami_id`) had **no defaults** and were
unused EC2 leftovers — they made `terraform plan` fail in CI with "No value for
required variable". They were deleted and `admin_email` was given a default. **Rule:**
any variable without a default must be supplied in CI, or `plan` fails.

### 5.4 Sensitive variables
`hf_api_token` and `slack_webhook_url` are `sensitive = true` (redacted in plan/CLI
output). The real values live in the gitignored `terraform.tfvars` (local) or GitHub
Secrets (CI), never committed.

---

## 6. Locals, Workspaces & Naming

### 6.1 `locals.env_prefix`
```hcl
locals {
  env_prefix = terraform.workspace == "default" ? var.project_name
                                                : "${var.project_name}-${terraform.workspace}"
}
```
- **Workspace-aware naming.** The `default` workspace = production → names like
  `cloudkitchen`, `cloudkitchen-igw`. A `dev` workspace → `cloudkitchen-dev-*`.
- This lets the same code stand up isolated environments per Terraform workspace without
  changing variables. In practice the project runs in `default` (production).

### 6.2 Naming convention
Resource `Name` tags use `${local.env_prefix}-<role>` (e.g. `cloudkitchen-public-az1`).
Globally-unique names (S3, ECR) append `${data.aws_caller_identity.current.account_id}`
where needed.

---

## 7. Tagging Strategy

`var.global_tags` (`{Project=CloudKitchen, ManagedBy=Terraform-Pruthvi}`) is merged
onto resources via `merge({ Name = ... }, var.global_tags)`. This gives consistent
cost-allocation/ownership tags across the stack. EKS subnets additionally get
Kubernetes discovery tags (`kubernetes.io/role/elb`, cluster ownership) so the in-tree
cloud provider can place the NLB (see §9.1, and `eks.tf`).

---

## 8. Resource Inventory (by type, from the actual code)

~90 resources across the root module. Highlights (full list in the code):

| Count | Type | Where |
|------:|------|-------|
| 8 | `aws_iam_role` | irsa, dr-agent, eks, addons |
| 7 | `aws_iam_role_policy_attachment` | eks, irsa, dr-agent |
| 6 | `aws_iam_role_policy` | irsa, addons, dr-agent |
| 5 | `aws_ecr_repository` (+5 lifecycle policies) | ecr.tf |
| 5 | `aws_ssm_parameter` | config values |
| 4 | `aws_eks_addon` | eks.tf (vpc-cni, coredns, kube-proxy, cloudwatch-observability) |
| 3 | `aws_subnet` (for_each → 6 subnets) | main.tf |
| 3 | `aws_security_group` | main.tf |
| 3 | `aws_lambda_function` (+3 permissions) | addons (presign, notification), dr-agent |
| 2 | `aws_sqs_queue` | sqs.tf (queue + DLQ) |
| 2 | `aws_secretsmanager_secret` (+2 versions) | irsa (app/runtime), main (db) |
| 2 | `aws_cognito_user_pool` (+2 clients) | auth.tf |
| 2 | `aws_cloudwatch_metric_alarm` | addons/dr |
| 2 | `aws_config_config_rule` (+recorder/channel) | addons (gated by `enable_aws_config`) |
| 1 each | `aws_vpc`, `aws_internet_gateway`, `aws_nat_gateway`, `aws_eip`, `aws_eks_cluster`, `aws_eks_node_group`, `aws_iam_openid_connect_provider`, `aws_db_instance`, `aws_cloudfront_distribution`, `random_password`, `null_resource` | various |

**Modules:** none (flat root). **Data sources:** `aws_caller_identity` (account id),
`tls_certificate` (OIDC thumbprint), `aws_iam_policy_document` ×3 (assume-role/policy
JSON), `archive_file` ×3 (zips Lambda code at plan time).

---

## 9. Key Terraform Patterns Used

### 9.1 `for_each` maps (not `count`) for stable addressing
Subnets, EKS add-ons, ECR repos, and CloudFront behaviours use `for_each` over maps so
each instance has a **stable key** (`aws_subnet.public["az1"]`) — adding/removing one
doesn't reindex the others (which `count` would). EKS subnet tags are produced with a
`for idx, s in aws_subnet.X : tostring(idx) => s` expression.

### 9.2 Data sources that compute values
- `data.aws_caller_identity.current.account_id` — injected into globally-unique names.
- `data.tls_certificate` — fetches the EKS OIDC issuer's TLS thumbprint for the
  `aws_iam_openid_connect_provider` (IRSA trust root).
- `data.aws_iam_policy_document` — builds assume-role / permission JSON in HCL.
- `data.archive_file` — zips Lambda source at plan time (no external build step).

### 9.3 Conditional / gated resources
`var.enable_aws_config` (bool, default false) gates the AWS Config recorder/rules;
`var.eks_api_origin != ""` gates the CloudFront API origin + `/api`/`/auth` behaviours
(§10). This is how the same code produces different shapes per phase/toggle.

### 9.4 Generated secrets
`random_password` generates the RDS master password; it's written to the
`cloudkitchen/db/credentials-new` Secrets Manager secret (consumed at runtime by ESO →
pods). No human ever sees or commits the DB password.

---

## 10. The Two-Phase Apply (the defining IaC mechanism)

CloudFront must forward `/api` + `/auth` to the EKS **NLB**, but that NLB is created by
**Kubernetes at runtime**, after Terraform first runs. Terraform can't reference a
resource it doesn't manage, so the project uses an **input variable as the bridge**:

```hcl
variable "eks_api_origin" { default = "" }   # NLB DNS, empty on first apply
```
- **First apply** (`eks_api_origin = ""`): builds VPC, EKS, RDS, S3, CloudFront with
  the **S3 origin only** — the `/api`/`/auth` behaviours and `eks-api-origin` are
  gated off (`count`/conditional on the var being non-empty).
- Kubernetes then provisions the NLB (via the kgateway Gateway).
- **Second apply** (`-var="eks_api_origin=<nlb-dns>"`): now the conditional resources
  render, adding the API origin + behaviours; then CloudFront is invalidated.

`wire-cloudfront.sh` (gitops repo) automates phase two by reading the live NLB DNS and
re-applying. **Because the NLB DNS changes on every recreate, phase two must re-run
each time** — skipping it is the root cause of the recurring "empty menu / AI warming
up" symptom (full story in `K8S_REFERENCE.md` §7). This is fundamentally an IaC
data-flow constraint, surfaced here for completeness.

---

## 11. Lifecycle & Safe-Teardown Settings

### 11.1 Standard flow
`terraform init` (configures S3 backend + downloads providers) → `plan` → `apply`.
`deploy.sh` runs: bootstrap apply → root init → root apply → (later) the second apply.

### 11.2 Settings that make destroy safe & cheap (deliberate for a sandbox)
- **`force_destroy = true`** on the state + app S3 buckets → `destroy` removes
  non-empty buckets.
- **`force_delete`** on ECR repos → `destroy` removes repos that still hold images.
- **RDS `deletion_protection = false` + `skip_final_snapshot = true`** → DB destroys
  cleanly without a manual final snapshot.
- **DynamoDB / SQS** are `PAY_PER_REQUEST` (no idle cost).
These are intentional for frequent destroy/recreate cost control; in a real production
account you'd flip several back on (snapshots, deletion protection, bucket retention).

---

## 12. Destroy Ordering & Out-of-Band Resources

Terraform does **not** know about the **Kubernetes-created NLB(s)** (gateway, ArgoCD,
Grafana LoadBalancers). If you `terraform destroy` first, those NLBs' ENIs orphan and
**block VPC deletion** (destroy hangs). Therefore `destroy.sh` (gitops repo) enforces
order:
1. delete the ArgoCD app (prunes workloads incl. the gateway),
2. delete **all** LoadBalancer Services and wait until none remain,
3. **then** `terraform destroy`.
This ordering is an IaC consequence of mixing Terraform-managed and K8s-managed AWS
resources in one VPC.

---

## 13. CI Integration (how `terraform.yml` runs this code)

`cloudkitchen-infra/.github/workflows/terraform.yml` (full detail in
`CICD_REFERENCE.md` §4):
- `validate-plan`: `setup-terraform ~1.9` → `init` → `fmt -check -recursive`
  (report-only) → `validate` (gate) → `plan` with `TF_VAR_hf_api_token`.
- `apply` (main push, `environment: production` approval): `init` → `apply
  -auto-approve`.
Implications for IaC authors: keep code `validate`-clean; ensure every variable has a
default (only `hf_api_token` is injected); run `terraform fmt` before pushing (the
check is report-only but reviewers expect formatted code).

---

## 14. Outputs (`outputs.tf`) and their consumers

The root exports ~dozens of outputs; the ones other layers depend on:
| Output | Consumed by | Purpose |
|--------|-------------|---------|
| `cloudfront_url` | deploy.sh, links.sh, users | the app URL |
| `cloudfront_distribution_id` | wire-cloudfront.sh | cache invalidation |
| `frontend_bucket_name` | deploy.sh | `aws s3 sync` target for the SPA |
| `api_gateway_url` | SPA build (`REACT_APP_API_GATEWAY_URL`) | testimonials presign |
| `rds_endpoint`, `rds_db_name`, `rds_port` | reference/debug | DB connection |
| `sqs_orders_queue_url`, `..._dlq_url`, `..._arn` | app config / DR | eventing |
| IRSA role ARNs (ai/order/eso) | gitops `values.yaml` (mirrored) | pod IAM |
| `vpc_id` | reference | networking |

> Note: some outputs still contain legacy text referencing the old ALB/EC2 topology
> (e.g. an "App Tier via ALB" hint and `http://EKS-NLB-DNS` placeholders). These are
> cosmetic leftovers; the EKS path is authoritative.

---

## 15. Secrets in IaC (and the state-plaintext caveat)

- Sensitive **inputs** (`hf_api_token`, `slack_webhook_url`) are marked `sensitive`,
  kept in gitignored `terraform.tfvars` / GitHub Secrets.
- **Generated** secrets (`random_password` for RDS) are written to Secrets Manager
  (`cloudkitchen/db/credentials-new`); the app-runtime secret
  (`cloudkitchen/app/runtime`) holds DB URL/user, HF token, SQS URL, Cognito IDs.
- **Caveat:** Terraform state stores resource attributes — including secret values —
  in (potentially) plaintext within the state file. This is why the state bucket is
  **private + encrypted + access-blocked** (§4.2). Never make the state bucket public;
  never commit state.
- At **runtime**, pods never read Terraform state — they get secrets via ESO from
  Secrets Manager (see `K8S_REFERENCE.md` §8). IaC's job ends at *populating* Secrets
  Manager.

---

## 16. How IaC Connects to the Other Pillars

```
Terraform (this repo)
  ├─ creates EKS cluster ─────────────► K8s/GitOps layer runs on it (K8S_REFERENCE.md)
  ├─ creates ECR repos ──────────────► CI pushes images here (CICD_REFERENCE.md)
  ├─ writes Secrets Manager secrets ─► ESO syncs them into pods
  ├─ creates IRSA roles/OIDC ────────► pods assume them (no static keys)
  ├─ outputs (CF url, buckets, ARNs) ► deploy.sh / SPA build / Helm values
  └─ CloudFront ◄── eks_api_origin ── NLB created by Kubernetes (two-phase, §10)
```

---

## 17. File-by-File Walkthrough

- **`main.tf`** — provider/terraform block + `locals`. The whole **network**: VPC,
  6 subnets (public/app/db ×2 AZ via `for_each`), IGW, single NAT + EIP, route tables +
  associations, three security groups. The **RDS** PostgreSQL instance, its subnet
  group, and `random_password` + the DB Secrets Manager secret. (Header comment
  describes a removed EC2/ALB topology — ignore it.)
- **`eks.tf`** — `aws_eks_cluster`, `aws_eks_node_group` (t3.medium, desired 3/min
  1/max 5), the 4 add-ons, the EKS-discovery **subnet tags**, the **eks→db** security
  group rule, and the CloudWatchAgentServerPolicy attachment on the node role.
- **`irsa.tf`** — `tls_certificate` data + `aws_iam_openid_connect_provider` (the IRSA
  trust root), the **ai/order/eso** roles + policies, and the `cloudkitchen/app/runtime`
  Secrets Manager secret/version. Outputs the role ARNs.
- **`ecr.tf`** — 5 ECR repositories (menu/order/auth/ai/app) each with a lifecycle
  policy to expire old images; `force_delete` for teardown.
- **`sqs.tf`** — the orders queue + a dead-letter queue (redrive policy).
- **`auth.tf`** — Amazon Cognito user pool(s) + app client(s) for authentication.
- **`addons.tf`** — the big one: **CloudFront** distribution (S3 frontend origin +
  conditional `eks-api-origin` with `/api`/`/auth` behaviours gated on
  `eks_api_origin`), **S3** frontend + testimonials buckets, **OAC**, origin-request
  policy, **API Gateway** (HTTP API) + **presign/notification Lambdas** (`archive_file`
  zips), **SNS** topic + subscription (`admin_email`), CloudWatch alarms, and AWS
  **Config** rules gated by `enable_aws_config`.
- **`dr-agent.tf`** — the autonomous DR agent: a Lambda (LangGraph) triggered by an
  EventBridge schedule, monitoring RDS + the SQS DLQ, with its IAM role/policy.
- **`variables.tf` / `outputs.tf`** — inputs (§5) / outputs (§14).
- **`backend.tf`** — active S3 backend (§4.1). **`state-backend.tf`** — redundant
  legacy state resources (§4.4).
- **`bootstrap/`** — the separate project that creates the backend bucket+lock (§4.2).

---

## 18. Failure Modes & Troubleshooting

| Symptom | Root cause | Fix |
|---------|-----------|-----|
| `Error: No value for required variable` (`plan` in CI) | a var without a default not supplied | give it a default or pass `-var`/`TF_VAR_*`. (Fixed: removed `web_ami_id`/`app_ami_id`, defaulted `admin_email`.) |
| `terraform destroy` hangs on VPC/subnet | K8s-created NLB ENIs not in TF state | delete K8s LoadBalancers first (`destroy.sh` order, §12) |
| App shows empty menu / AI "warming up" after recreate | phase-two apply not re-run with new NLB DNS | `bash wire-cloudfront.sh` (re-applies `-var=eks_api_origin=<nlb>`) (§10) |
| `Error acquiring the state lock` | a previous run died holding the DynamoDB lock | `terraform force-unlock <ID>` (verify no apply is actually running) |
| State corrupted after broken-pipe push | interrupted write | `terraform state push <good.tfstate>` from an S3 version (§4.5) |
| Backend init asks to migrate / can't find bucket | bootstrap not applied yet | run `bootstrap/` first (`deploy.sh` does this) |
| `fmt -check` flags files | unformatted HCL | `terraform fmt -recursive` (report-only in CI, but tidy) |
| S3 "bucket already exists" on a fresh account | global name clash | names include account id; ensure correct account/region |

---

## 19. Conventions & How to Extend

- **One concern per file.** Add a new subsystem as a new `*.tf`, not into `main.tf`.
- **Prefer `for_each` over `count`** for collections (stable addressing).
- **Everything gets `global_tags`** via `merge(...)`.
- **New variable?** give it a sensible default (so CI `plan` keeps working) unless it's
  a genuine required secret (then inject it in CI + `deploy.sh`).
- **Add a microservice (IaC side):** add an `aws_ecr_repository` (+lifecycle) in
  `ecr.tf`; if it needs AWS access, add an IRSA role/policy in `irsa.tf` and output its
  ARN; add any queue/secret it needs. (K8s side covered in `K8S_REFERENCE.md` §12;
  CI side in `CICD_REFERENCE.md` §12.)
- **Never** commit `terraform.tfvars` or state; **never** make the state bucket public.

---

## 20. FAQ

**Q: Are there Terraform modules?** No — it's a single flat root module, organised by
file. Simpler to read for a capstone; a production refactor might extract VPC/EKS into
modules.

**Q: Why two state buckets in the account?** `bootstrap/` creates the one actually used
(`cloudkitchen-tfstate-*`); `state-backend.tf` creates a second, unused set
(`*-terraform-state-*`) — a legacy leftover (§4.4).

**Q: Why is the backend block hard-coded (no variables)?** Terraform forbids
variables/expressions in `backend {}`. The values must be literals.

**Q: How does the DB password stay secret?** `random_password` generates it; it's
stored in Secrets Manager and synced to pods by ESO — never printed or committed.

**Q: What's the single weirdest thing about this IaC?** The two-phase apply via
`eks_api_origin` (§10) — Terraform and Kubernetes each own part of the edge path, and
an input variable bridges them.

**Q: Can I run `terraform apply` directly instead of `deploy.sh`?** Yes, after
`bootstrap/` exists and you have `terraform.tfvars` (or `TF_VAR_hf_api_token`). But
you'll still need the phase-two apply once the NLB exists.

**Q: Why `force_destroy`/`skip_final_snapshot`/`deletion_protection=false`?** This is a
cost-controlled sandbox destroyed/recreated often; these make teardown clean. Reverse
them for real production.

---

## 21. File Index (concept → file)

| Concept | File |
|---------|------|
| Provider/terraform block, VPC/subnets/NAT/SG, RDS | `main.tf` |
| EKS cluster, node group, add-ons, subnet tags | `eks.tf` |
| OIDC provider, IRSA roles/policies, app-runtime secret | `irsa.tf` |
| ECR repos + lifecycle | `ecr.tf` |
| SQS queue + DLQ | `sqs.tf` |
| Cognito | `auth.tf` |
| CloudFront, S3, OAC, API Gateway, Lambdas, SNS, Config, alarms | `addons.tf` |
| DR agent Lambda + EventBridge | `dr-agent.tf` |
| Input variables | `variables.tf` |
| Outputs | `outputs.tf` |
| Active S3 backend config | `backend.tf` |
| Legacy/redundant state resources | `state-backend.tf` |
| State backend creation (separate project) | `bootstrap/` |
| Infra CI pipeline | `.github/workflows/terraform.yml` |
| Local one-shot apply orchestration | `cloudkitchen-gitops/deploy.sh` |
| Phase-two CloudFront wire | `cloudkitchen-gitops/wire-cloudfront.sh` |

---

*End of CloudKitchen Infrastructure-as-Code Reference. Companions:
`AWS_CLOUD_REFERENCE.md` (cloud services), `cloudkitchen-gitops/K8S_REFERENCE.md`
(Kubernetes/GitOps), `cloudkitchen-app/CICD_REFERENCE.md` (CI/CD).*
