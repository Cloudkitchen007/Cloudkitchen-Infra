# CloudKitchen — AWS Cloud Architecture: Definitive Reference

> **Scope of this document:** the **AWS Cloud** pillar of the CloudKitchen
> project. The project has four pillars — **CI/CD**, **Infrastructure (Terraform)**,
> **Kubernetes (GitOps/Helm)**, and **Cloud (AWS services)**. This document covers
> the Cloud pillar exhaustively: every AWS service used, how it is configured, why
> it was chosen, and how all services connect into one system.
>
> **Audience:** humans *and* AI assistants. It is written so that any LLM can read
> it and correctly answer detailed questions about the project's AWS design without
> needing the source code. Where a fact maps to code, the Terraform file is named.

---

## 0. How To Use This Document (instructions for an AI assistant)

If you are an AI assistant answering questions about this project, treat this
document as the authoritative description of the AWS cloud design. Key rules:

1. **Two deployment topologies exist.** The project was first built on **EC2 Auto
   Scaling Groups + an Application Load Balancer (ALB)** ("Topology A — the EC2
   baseline"), then modernized to **Amazon EKS + kgateway + GitOps** ("Topology B
   — the EKS target"). When a question is about "current/production" assume
   **Topology B (EKS)** unless the user says "the EC2 version." Both are described
   here; each service entry states which topology it belongs to.
2. **Naming is deterministic.** Almost every resource name is
   `cloudkitchen-<thing>` (the prefix is `local.env_prefix` = `"cloudkitchen"`).
   The AWS account id used throughout examples is `256603361470` and the region is
   `ap-south-1` (Mumbai).
3. **"Commented/optional" services still count.** AWS Config is gated behind a
   variable (`enable_aws_config`, default `false`) and is therefore usually *not*
   deployed, but it is part of the design and is documented in §3.
4. When asked "why is X used," prefer the **Why** subsection of that service in §3.
5. When asked "how does a request flow," use §2 (Request & Data Flows).
6. When asked "what talks to what," use §9 (Connection Matrix).
7. If a question cannot be answered from this document, say so rather than
   inventing AWS resources that are not listed here.

---

## 1. Project Overview

### 1.1 What CloudKitchen is
CloudKitchen is a cloud-native, microservices food-delivery platform. End users
browse a menu, place orders, record video testimonials, and use AI features
(personalized recommendations and a demand forecaster). Restaurant operators have
their own login. The platform is provisioned end-to-end with Terraform and is
designed to be created and destroyed with a single command for cost control.

### 1.2 The four pillars
| Pillar | Repo | Responsibility |
|---|---|---|
| **CI/CD** | `cloudkitchen-app` (+ workflows) | Build, test, scan, push images, trigger GitOps |
| **Infrastructure** | `cloudkitchen-infra` | Terraform for all AWS resources |
| **Kubernetes** | `cloudkitchen-gitops` | Helm chart, ArgoCD, kgateway, monitoring |
| **Cloud** | (this document) | The AWS services themselves and how they interconnect |

This document is the Cloud pillar's reference. It overlaps the Infrastructure
pillar (Terraform *creates* the cloud resources) but is organized by **AWS
service and behavior**, not by Terraform file.

### 1.3 The microservices (what runs on the cloud)
| Service | Language/Runtime | Port | Role |
|---|---|---|---|
| menu-service | Spring Boot / Java 17 | 8080 | Menu + categories; owns the DB schema (Flyway) |
| order-service | Spring Boot / Java 17 | 8082 | Orders; publishes `OrderPlaced` events to SQS |
| auth-service | Spring Boot / Java 17 | 8001 | Authentication via Cognito (2 pools) |
| ai-recommender | FastAPI / Python 3.12 | 8000 | AI recommendations + demand forecasting; SQS consumer |
| frontend | React + Nginx | 8080 (container) / S3 | Single-page app |

### 1.4 Account, region, naming conventions
- **Account id (examples):** `256603361470`
- **Region:** `ap-south-1` (Mumbai), 2 Availability Zones.
- **Name prefix:** `cloudkitchen` (Terraform `local.env_prefix`).
- **Tags:** every resource carries `var.global_tags` (Project, Environment, etc.).
- **ECR registry host:** `256603361470.dkr.ecr.ap-south-1.amazonaws.com`.

---

## 2. Request & Data Flows

This section traces real requests end-to-end. Each flow lists the hops, the AWS
services involved, and the protocols.

### 2.1 Flow A — Loading the web app (static content)
```
Browser
  │  HTTPS GET https://<cloudfront-domain>/
  ▼
CloudFront (CDN, edge)            ← AWS::CloudFront::Distribution
  │  default cache behavior → S3 frontend origin (via Origin Access Control)
  ▼
S3 (frontend bucket)              ← AWS::S3::Bucket "cloudkitchen-frontend-<acct>"
  │  returns index.html + JS/CSS bundles
  ▼
Browser renders the React SPA
```
Notes:
- The S3 bucket is **private**; only CloudFront can read it via **Origin Access
  Control (OAC)** + a bucket policy that allows the CloudFront service principal.
- A `custom_error_response` maps 404 → `/index.html` (200) so client-side React
  Router routes work (SPA fallback).
- CloudFront enforces HTTPS (`viewer_protocol_policy = redirect-to-https`).

### 2.2 Flow B — Browsing the menu (dynamic API, Topology B / EKS)
```
Browser
  │  HTTPS GET /api/menu     (and /api/categories)
  ▼
CloudFront  → API behavior → EKS NLB origin  (Topology B)
  ▼
AWS Network Load Balancer (L4)    ← created by Kubernetes Service type=LoadBalancer
  │  forwards :80 to the kgateway Envoy proxy pods on the EKS nodes
  ▼
kgateway / Envoy (L7 router in-cluster)
  │  HTTPRoute path match: /api → menu Service
  ▼
Kubernetes Service "menu" (ClusterIP) → menu pod(s)
  ▼
menu-service (Spring Boot :8080)
  │  JDBC (PostgreSQL wire protocol, TCP 5432)
  ▼
Amazon RDS for PostgreSQL          ← AWS::RDS::DBInstance "cloudkitchen-db"
  │  returns menu rows
  ▼  (response travels back up the same chain)
Browser shows the menu
```
In **Topology A (EC2)** the same path is: CloudFront `/api/*` → **ALB** →
**target group** → **EC2 ASG instance** running menu-service → RDS.

### 2.3 Flow C — Placing an order (event-driven)
```
Browser → CloudFront → NLB → kgateway → order Service → order-service (:8082)
  │
  ├─ 1. INSERT order + order_items  → RDS (PostgreSQL)
  └─ 2. publish OrderPlaced event   → Amazon SQS (orders queue)
          (message body: { orderId, items:[{name, quantity}], total, ... })
```
Then, asynchronously:
```
Amazon SQS "cloudkitchen-orders-queue"
  │  long-poll receive
  ▼
ai-recommender SQS consumer (background thread in the AI pod)
  │  increments an in-memory per-item demand counter
  ▼
/api/demand/realtime now reflects real order counts
```
Failure handling: if the consumer fails to process a message 3 times, SQS moves it
to the **Dead Letter Queue (DLQ)** `cloudkitchen-orders-dlq`. A CloudWatch alarm
fires when the DLQ is non-empty.

### 2.4 Flow D — AI recommendation
```
Browser → CloudFront → NLB → kgateway (/api/recommend*) → ai Service → ai-recommender (:8000)
  ▼
ai-recommender:
  1. embeds the query with sentence-transformers (local, CPU)
  2. similarity search in ChromaDB (local vector store)
  3. calls HuggingFace Inference API (Mistral-7B) for a natural-language reason
        (outbound HTTPS via the NAT Gateway)
  ▼
returns ranked items + reasons → Browser
```
The LLM (Mistral-7B) is **not** hosted in AWS — it is a remote HuggingFace
Inference API call. Only lightweight embeddings + vector store run on the pod.

### 2.5 Flow E — AI demand forecast
```
Browser → /api/recommend_forecast → ai-recommender
  ▼
for each item: real demand from SQS-fed counter (fallback: estimate)
  → compute stock risk (UNDERSTOCK/OPTIMAL/OVERSTOCK)
  → HuggingFace LLM generates an insight sentence
  ▼
returns insights → AI Dashboard in the frontend
```

### 2.6 Flow F — Testimonial video upload (serverless)
```
Browser → CloudFront /api/testimonials/presign
  ▼  (or directly to the API Gateway endpoint)
Amazon API Gateway (HTTP API)     ← AWS::ApiGatewayV2::Api "testimonials_api"
  ▼  proxy integration
AWS Lambda (presign function)     ← issues an S3 pre-signed PUT URL
  ▼
Browser uploads the video directly to S3 (testimonials bucket) via the presigned URL
  ▼
CloudFront serves it back at /testimonials/* from the testimonials S3 origin
```
A second Lambda ("notification") handles order/event notifications.

### 2.7 Flow G — Authentication
```
Browser → /auth/* → auth Service → auth-service (:8001)
  ▼
Amazon Cognito (two User Pools)   ← customers pool + restaurants pool
  │  SignUp / InitiateAuth / token issuance
  ▼
returns JWT tokens → Browser
```
The auth-service reads its Cognito pool/client ids from environment variables
(injected from Secrets Manager via External Secrets Operator on EKS; from SSM
Parameter Store on the EC2 topology).

### 2.8 Flow H — Disaster Recovery agent (scheduled, autonomous)
```
Amazon EventBridge (scheduled rule)   ← cron(0 2 * * ? *) daily 02:00 UTC
  ▼ triggers
AWS Lambda "cloudkitchen-dr-agent"    ← LangGraph state machine
  graph: observe → reason → (act | skip) → report
  ▼
observe: boto3 calls →
   • RDS DescribeDBInstances (DB health)
   • SQS GetQueueAttributes (DLQ depth)
reason:  HuggingFace Mistral-7B writes an incident narrative (fallback: rules)
act:     publish to SNS if an incident is detected
report:  structured log to CloudWatch Logs
```
In Topology A the agent also checked ALB target health and ASG instance counts;
in Topology B (EKS) those are removed (no ALB/ASG for the app), and EKS health is
observed via Prometheus/Container Insights instead.

### 2.9 Flow I — Monitoring & alerting
```
EKS pods / nodes
  ├─ Prometheus scrapes metrics (in-cluster) ───► Grafana dashboards (public LB)
  │                                          └──► Alertmanager → Slack webhook
  └─ CloudWatch agent + Fluent Bit (Container Insights add-on)
                                              └──► Amazon CloudWatch (metrics+logs)
CloudWatch alarms (DLQ depth, Lambda errors) ─────► Amazon SNS → email
```

---

## 3. AWS Service Catalog (every service, configuration, and rationale)

Each entry: **What** it is, **Config** in this project, **Why** it was chosen,
**Connections** (what it talks to), and **Code** (Terraform file).

### 3.1 Amazon VPC (Virtual Private Cloud)
- **What:** an isolated virtual network that contains all compute and data.
- **Config:** one VPC (`aws_vpc.main`), CIDR `10.0.0.0/16` (see `var.vpc_cidr`),
  DNS support + DNS hostnames enabled, spanning **two Availability Zones** for
  high availability.
- **Why:** network isolation is the foundation of cloud security — it lets us put
  databases and compute in private subnets with no public IPs, and control all
  traffic with security groups and route tables. Multi-AZ gives resilience to a
  single data-center failure.
- **Connections:** contains all subnets, the NAT/Internet gateways, RDS, EKS
  nodes/control-plane ENIs, and (Topology A) EC2 + ALB.
- **Code:** `main.tf`.

### 3.2 Subnets (public, private-app, private-db)
- **What:** subdivisions of the VPC CIDR, each bound to one AZ.
- **Config:** three tiers, each replicated across the 2 AZs:
  - **Public subnets** (`aws_subnet.public`): host the NAT Gateway, the Internet
    Gateway attachment, and (Topology A) the internet-facing ALB. EKS control
    plane ENIs and the public-facing NLB also live here.
  - **Private application subnets** (`aws_subnet.private_app`): host the EKS
    worker nodes (and pods) and, in Topology A, the EC2 ASGs. No public IPs.
  - **Private database subnets** (`aws_subnet.private_db`): host RDS only, via an
    RDS DB Subnet Group. The most isolated tier.
- **Why:** the three-tier subnet model is a standard AWS best practice — public
  for ingress/egress edge, private-app for stateless compute, private-db for
  stateful data. It minimizes the public attack surface (only load balancers are
  internet-facing) and supports multi-AZ.
- **Connections:** public ↔ Internet Gateway; private ↔ NAT Gateway; private-db ↔
  RDS subnet group. Subnets are tagged for Kubernetes
  (`kubernetes.io/role/elb`, `kubernetes.io/role/internal-elb`,
  `kubernetes.io/cluster/<name>`) so the EKS load-balancer integration can place
  NLBs/ALBs correctly.
- **Code:** `main.tf`, subnet tags in `eks.tf`.

### 3.3 Internet Gateway (IGW)
- **What:** the VPC's door to the public internet.
- **Config:** one IGW attached to the VPC; the public route table sends
  `0.0.0.0/0` to it.
- **Why:** required for anything in public subnets to be reachable from / reach
  the internet (the NAT Gateway, the ALB/NLB).
- **Connections:** public subnets' default route; upstream of the NAT Gateway.
- **Code:** `main.tf`.

### 3.4 NAT Gateway
- **What:** a managed Network Address Translation service that lets private
  resources make **outbound** internet connections without being publicly
  reachable.
- **Config:** NAT Gateway(s) in the public subnet(s) with an Elastic IP; the
  private route table sends `0.0.0.0/0` to the NAT Gateway.
- **Why:** private compute (EKS pods, EC2 app instances, the AI service) needs
  outbound internet for: pulling container images, calling the **HuggingFace
  Inference API**, downloading the sentence-transformers model, reaching AWS
  service endpoints, and OS/package installs — all **without** exposing those
  instances to inbound internet traffic.
- **Connections:** private subnets → NAT Gateway → IGW → internet. Used by AI
  recommender (HF API), all pods (ECR pulls), the DR agent.
- **Cost note:** the NAT Gateway is a always-on paid component (~$32/month +
  data) and is one of the main reasons to `destroy` between demos.
- **Code:** `main.tf`.

### 3.5 Route Tables
- **What:** rules that decide where subnet traffic goes.
- **Config:** a **public** route table (`0.0.0.0/0` → IGW) associated with public
  subnets; a **private** route table (`0.0.0.0/0` → NAT Gateway) associated with
  private subnets. Local VPC routes are implicit.
- **Why:** they enforce the public/private split — public subnets can talk to the
  internet directly; private subnets only via NAT (outbound) and never inbound.
- **Connections:** bind subnets to IGW / NAT Gateway.
- **Code:** `main.tf`.

### 3.6 Security Groups (stateful firewalls)
- **What:** instance/ENI-level virtual firewalls (stateful: return traffic auto
  allowed).
- **Config (key groups):**
  - **`db_sg`** (RDS): inbound `5432` only from the application security
    groups / the EKS cluster security group. Egress open.
  - **EKS cluster security group** (managed by EKS): used by nodes/pods; RDS
    allows `5432` from it via `aws_security_group_rule.eks_to_db` (see `eks.tf`).
  - **Topology A only:** `ext_alb_sg` (ALB, inbound 80/443 from internet),
    `app_sg` (EC2 app tier, inbound 8080 from ALB SG), and per-service SGs.
- **Why:** least-privilege network access — the database only accepts connections
  from the application layer, not the whole VPC or internet; load balancers are
  the only internet-facing entry. Security groups are referenced *by group id*
  (not CIDR) so rules track the right sources even as IPs change.
- **Connections:** `db_sg` ← app/EKS SGs; `ext_alb_sg` ← internet; `app_sg` ←
  `ext_alb_sg`.
- **Code:** `main.tf` (db_sg, ext_alb_sg, app_sg), `eks.tf` (eks_to_db rule).

### 3.7 Amazon EKS (Elastic Kubernetes Service) — Topology B
- **What:** managed Kubernetes control plane.
- **Config:** `aws_eks_cluster.cloudkitchen`, version **1.30**, endpoints both
  private and public, control-plane logging (`api`, `audit`, `authenticator`).
  Subnets = public + private-app. A **managed node group**
  (`aws_eks_node_group.main`) of **t3.medium** instances, `desired=3 / min=1 /
  max=5`, in private-app subnets.
- **Why:** EKS is the industry-standard way to run containers at scale on AWS
  with declarative deployment, self-healing, horizontal scaling, and a rich
  ecosystem (Gateway API, ArgoCD, Prometheus). It replaces the hand-rolled EC2
  ASG topology with a portable, cloud-native platform and is the target of the
  GitOps pipeline.
- **Connections:** nodes run the app pods + kgateway (Envoy) + ArgoCD + External
  Secrets Operator + Prometheus/Grafana; nodes pull images from **ECR**; pods
  reach **RDS** (5432), **SQS**, **Cognito**, **Secrets Manager** (via IRSA), and
  the **HuggingFace API** (via NAT). The OIDC provider underpins IRSA.
- **Code:** `eks.tf`.

### 3.8 EKS Managed Node Group (EC2 under the hood)
- **What:** a managed group of EC2 worker nodes that join the EKS cluster.
- **Config:** t3.medium (2 vCPU / 4 GB), `desired=3` (raised from 2 to fit
  Prometheus/Grafana), `max=5`, in private-app subnets across both AZs. Node IAM
  role has: `AmazonEKSWorkerNodePolicy`, `AmazonEKS_CNI_Policy`,
  `AmazonEC2ContainerRegistryReadOnly` (image pulls), `CloudWatchAgentServerPolicy`
  (Container Insights).
- **Why:** managed node groups handle the EC2 lifecycle (AMI, joining, draining,
  rolling updates) so we don't manage launch templates/ASGs by hand. t3.medium is
  the cost-effective size that fits all four small services plus the platform.
- **Connections:** registers with the EKS control plane; runs all pods; pulls
  from ECR; talks to RDS/SQS/etc. via pod networking.
- **Code:** `eks.tf`.

### 3.9 EKS Add-ons
- **What:** AWS-managed cluster components.
- **Config:** `vpc-cni` (pod networking), `coredns` (in-cluster DNS),
  `kube-proxy` (service routing), and **`amazon-cloudwatch-observability`**
  (Container Insights: CloudWatch agent + Fluent Bit). The EBS CSI driver add-on
  was intentionally **omitted** (the services are stateless; it requires IRSA and
  was causing a 20-minute install timeout).
- **Why:** these are the baseline networking/DNS components every EKS cluster
  needs; the observability add-on gives container/pod metrics and logs in
  CloudWatch with no app changes.
- **Connections:** vpc-cni assigns pod IPs from the VPC; coredns resolves Service
  names; the observability agent ships metrics/logs to CloudWatch.
- **Code:** `eks.tf`.

### 3.10 IAM Roles for Service Accounts (IRSA) + OIDC provider
- **What:** the mechanism that lets specific Kubernetes pods assume specific IAM
  roles using a short-lived web-identity token — **no static AWS keys in pods**.
- **Config:** an `aws_iam_openid_connect_provider` for the EKS cluster's OIDC
  issuer. Three IRSA roles (`irsa.tf`):
  - **`cloudkitchen-ai-irsa`** — trust = `system:serviceaccount:production:ai`;
    permission = SQS receive/delete on the orders queue (AI consumes events).
  - **`cloudkitchen-order-irsa`** — trust = `...:production:order`; permission =
    SQS send on the orders queue (order publishes events).
  - **`cloudkitchen-eso-irsa`** — trust = `...:production:external-secrets-sa`;
    permission = Secrets Manager `GetSecretValue` on the db + app-runtime secrets.
- **Why:** IRSA is the AWS-recommended, rubric-required pattern for pod→AWS access
  with **least privilege and no long-lived credentials**. Each pod gets exactly
  the AWS permissions it needs and nothing more.
- **Connections:** STS `AssumeRoleWithWebIdentity` ← pod service account token →
  scoped IAM role → AWS service (SQS / Secrets Manager).
- **Code:** `irsa.tf`.

### 3.11 Amazon ECR (Elastic Container Registry)
- **What:** private Docker image registry.
- **Config:** five repositories — `cloudkitchen-app-repo` (frontend/backend
  catch-all), `cloudkitchen-menu-repo`, `cloudkitchen-order-repo`,
  `cloudkitchen-auth-repo`, `cloudkitchen-ai-repo`. Each: image scanning on push,
  `MUTABLE` tags, `force_delete = true` (so `terraform destroy` can remove
  non-empty repos), and a lifecycle policy that keeps only the last 5 images.
- **Why:** EKS needs container images from a private, IAM-controlled registry;
  ECR integrates natively with EKS node IAM for pulls and with CI for pushes.
  `force_delete` + lifecycle keep the daily destroy/recreate clean and cheap.
- **Connections:** CI (cloudkitchen-app `build.yml`) pushes images; EKS nodes pull
  them (via `AmazonEC2ContainerRegistryReadOnly`).
- **Code:** `ecr.tf`.

### 3.12 Amazon RDS for PostgreSQL
- **What:** managed relational database.
- **Config:** `aws_db_instance.this`, engine PostgreSQL, class **db.t3.micro**, in
  the **private-db** subnets via a DB subnet group, security group `db_sg`
  (5432 from app/EKS only), not publicly accessible, storage encrypted. Database
  name `cloudkitchen`, master user `postgres`. The **menu-service owns the schema**
  and runs Flyway migrations; order-service shares the same database with Flyway
  disabled.
- **Why:** orders require ACID transactions and relational integrity — a managed
  Postgres gives durability, backups, and patching without us operating a
  database. db.t3.micro is free-tier-eligible and sufficient for a review.
- **Connections:** receives JDBC (5432) from menu-service and order-service;
  credentials stored in **Secrets Manager**; the DR agent reads its health via
  `rds:DescribeDBInstances`.
- **Code:** `main.tf`.

### 3.13 AWS Secrets Manager
- **What:** managed secret storage with encryption and rotation support.
- **Config:** two secrets:
  - **`cloudkitchen/db/credentials-new`** — DB host, port, dbname, username,
    password.
  - **`cloudkitchen/app/runtime`** (`irsa.tf`) — DB JDBC URL, DB username, HF API
    token, SQS queue URL, HF model name, and the four Cognito pool/client ids.
    Created with `recovery_window_in_days = 0` so daily destroy/recreate is not
    blocked by the 7–30 day deletion window.
- **Why:** secrets must never live in code, container images, or git. Secrets
  Manager centralizes them, encrypts them with KMS, and is the source that
  External Secrets Operator syncs into Kubernetes — giving the rubric's
  `Secrets Manager → ESO → K8s Secret → Pod` chain.
- **Connections:** written by Terraform; read by the EKS **External Secrets
  Operator** (via the `eso-irsa` role) and, in Topology A, by EC2 instances (via
  their instance roles). Values originate from `terraform.tfvars` (HF token) and
  from the Cognito/RDS/SQS resources.
- **Code:** `irsa.tf` (app_runtime), RDS module (db secret).

### 3.14 Amazon Cognito (User Pools)
- **What:** managed user identity, sign-up/sign-in, and JWT token issuance.
- **Config:** **two user pools** — a **customers** pool and a **restaurants**
  pool — each with its own app client (`aws_cognito_user_pool.users` /
  `.restaurants` + clients). Pool/client ids are also written to **SSM Parameter
  Store** and into the app-runtime Secrets Manager secret.
- **Why:** offloading identity to Cognito removes the need to store/secure
  passwords ourselves; it provides managed MFA, token issuance, and separate
  tenancy for the two account types (customers vs restaurants).
- **Connections:** auth-service calls Cognito (`SignUp`, `InitiateAuth`); ids are
  consumed by auth-service via env (from Secrets Manager/ESO on EKS, SSM on EC2).
- **Code:** `auth.tf`.

### 3.15 Amazon SQS (Simple Queue Service)
- **What:** managed message queue for asynchronous, decoupled communication.
- **Config:** a main queue **`cloudkitchen-orders-queue`** (visibility timeout
  30s, long-polling 20s, 4-day retention) and a **Dead Letter Queue**
  **`cloudkitchen-orders-dlq`** (14-day retention). Redrive policy:
  `maxReceiveCount = 3` → failed messages go to the DLQ.
- **Why:** decoupling order writes from downstream processing makes ordering
  resilient and fast — a slow or offline AI consumer never blocks a customer
  order. The DLQ captures poison messages for inspection instead of losing them.
  This is the project's event-driven backbone (a bonus rubric item).
- **Connections:** **producer** = order-service (SQS send, via `order-irsa` on
  EKS); **consumer** = ai-recommender (SQS receive/delete, via `ai-irsa`); the DR
  agent reads DLQ depth; a CloudWatch alarm watches the DLQ.
- **Code:** `sqs.tf`.

### 3.16 AWS Lambda
- **What:** serverless functions (pay-per-invocation, no servers to manage).
- **Config (three functions):**
  - **`cloudkitchen-dr-agent`** — Python 3.11, 512 MB, 120s timeout; a LangGraph
    agent packaged from `lambda/dr-agent/` and stored in S3; triggered daily by
    EventBridge. Env: RDS identifier, DLQ URL, SNS topic, HF token/model.
  - **presign** — issues S3 pre-signed PUT URLs for testimonial uploads; fronted
    by API Gateway.
  - **notification** — order/event notifications.
- **Why:** Lambda is ideal for spiky, event-driven, or scheduled work — the
  presign endpoint and the once-a-day DR agent would be wasteful as always-on
  servers. Serverless = lower cost and less ops.
- **Connections:** dr-agent ← EventBridge, → RDS/SQS/SNS/CloudWatch; presign ←
  API Gateway, → S3 (presigned URL); both have least-privilege IAM roles.
- **Code:** `dr-agent.tf` (DR agent), `addons.tf` (presign, notification).

### 3.17 Amazon API Gateway (HTTP API)
- **What:** managed API front door for the serverless testimonial-upload path.
- **Config:** an HTTP API (`aws_apigatewayv2_api.testimonials_api`) with a
  `$default` stage and a route (e.g. `POST /api/testimonials/presign`) integrated
  with the presign Lambda (Lambda proxy).
- **Why:** API Gateway gives a managed, scalable HTTPS endpoint for the Lambda
  without running a server, with built-in throttling and CORS. It keeps large
  video uploads off the application servers (the browser uploads straight to S3
  using the presigned URL).
- **Connections:** Browser/CloudFront → API Gateway → presign Lambda → S3.
- **Code:** `addons.tf`.

### 3.18 Amazon EventBridge (scheduled rule)
- **What:** event bus / scheduler.
- **Config:** a scheduled rule `cron(0 2 * * ? *)` (daily 02:00 UTC) that targets
  the DR-agent Lambda, plus the Lambda permission allowing EventBridge to invoke
  it.
- **Why:** EventBridge is the serverless way to run scheduled work (cron) without
  a dedicated server; it decouples "when" from "what."
- **Connections:** EventBridge rule → Lambda (dr-agent).
- **Code:** `dr-agent.tf`.

### 3.19 Amazon S3 (Simple Storage Service)
- **What:** object storage.
- **Config (buckets):**
  - **frontend** (`cloudkitchen-frontend-<acct>`) — the built React SPA; private,
    served via CloudFront OAC.
  - **testimonials** (`cloudkitchen-testimonials-<acct>`) — user-uploaded videos
    *and* (Topology A) deployment artifacts (service zips); CORS configured for
    browser uploads.
  - **backups** (`cloudkitchen-db-backups-<acct>`) — DB backups; versioned,
    encrypted, lifecycle to STANDARD_IA at 30 days, expire at 90.
  - **tfstate** (`cloudkitchen-tfstate-<acct>`) — Terraform remote state; created
    by the `bootstrap/` config; versioned + encrypted + public-access blocked.
- **Why:** S3 is the cheapest, most durable (11 nines) store for static assets,
  user media, backups, and Terraform state. Pairing it with CloudFront gives a
  global, cache-accelerated static site with no servers.
- **Connections:** CloudFront ← frontend + testimonials buckets (OAC); presign
  Lambda → testimonials bucket; Terraform → tfstate bucket; RDS backups →
  backups bucket.
- **Code:** `main.tf` (backups), `addons.tf` (frontend, testimonials),
  `bootstrap/main.tf` (tfstate).

### 3.20 Amazon CloudFront (CDN)
- **What:** global content delivery network at AWS edge locations.
- **Config:** one distribution (`aws_cloudfront_distribution.cdn`) with origins:
  the **frontend S3** bucket (default behavior), the **testimonials S3** bucket
  (`/testimonials/*`), and — in Topology A — the **ALB** (`/api/*`). Uses
  **Origin Access Control** for S3, HTTPS redirect, and an SPA 404→index.html
  fallback. In Topology B the ALB origin is removed; the API behavior points at
  the EKS NLB (or the frontend calls the NLB directly).
- **Why:** CloudFront gives low-latency global delivery + TLS + caching for the
  SPA, and acts as a single front door that can route static vs API traffic. It
  keeps the S3 buckets private (only CloudFront can read them).
- **Connections:** Browser → CloudFront → {S3 frontend, S3 testimonials, ALB/NLB}.
- **Code:** `addons.tf`.

### 3.21 Origin Access Control (OAC)
- **What:** the modern way CloudFront authenticates to private S3 origins.
- **Config:** `aws_cloudfront_origin_access_control.s3_oac`; S3 bucket policies
  allow the CloudFront service principal with a `SourceArn` condition.
- **Why:** keeps S3 buckets fully private — objects are only reachable through
  CloudFront, not via direct S3 URLs. Replaces the legacy Origin Access Identity.
- **Connections:** CloudFront → S3 (frontend, testimonials).
- **Code:** `addons.tf`.

### 3.22 Amazon CloudWatch (Logs, Metrics, Alarms, Container Insights)
- **What:** AWS's observability service.
- **Config:**
  - **Log groups:** `/cloudkitchen/app`, per-service log groups (Topology A),
    `/aws/lambda/cloudkitchen-dr-agent` (30-day retention).
  - **Alarms:** `cloudkitchen-orders-dlq-depth` (DLQ non-empty → SNS),
    `cloudkitchen-dr-agent-errors` (Lambda errors → SNS), and (Topology A only)
    `cloudkitchen-alb-5xx`.
  - **Container Insights:** via the `amazon-cloudwatch-observability` EKS add-on —
    cluster/node/pod metrics and container logs.
- **Why:** centralized logs + metrics + alarms are essential for operating any
  cloud system; Container Insights gives Kubernetes-aware visibility without
  instrumenting the apps.
- **Connections:** receives logs/metrics from Lambda, EC2 (Topology A), and EKS
  (Container Insights agent); alarms publish to SNS.
- **Code:** `main.tf`, `sqs.tf`, `dr-agent.tf`, `addons.tf`, `eks.tf`.

### 3.23 Amazon SNS (Simple Notification Service)
- **What:** pub/sub notification service.
- **Config:** a topic `cloudkitchen-alerts` with an **email** subscription
  (`var.admin_email`).
- **Why:** a single fan-out point for operational alerts — CloudWatch alarms and
  the DR agent publish here, and subscribers (email today; could be Slack/SMS) get
  notified.
- **Connections:** ← CloudWatch alarms, DR-agent Lambda; → email subscriber.
- **Code:** `addons.tf` (topic + subscription).

### 3.24 AWS IAM (Identity and Access Management)
- **What:** the permissions system for everything in AWS.
- **Config (representative roles):** EKS cluster role, EKS node role, the three
  **IRSA** roles (ai/order/eso), the DR-agent Lambda role, the presign/notification
  Lambda roles, and (Topology A) per-EC2-service instance roles + instance
  profiles. Policies are scoped to specific ARNs and actions (least privilege).
- **Why:** least-privilege IAM is the core of cloud security — every component
  gets only the permissions it needs. IRSA extends this down to individual pods.
- **Connections:** every service that calls another AWS service does so through an
  IAM role/policy.
- **Code:** across `main.tf`, `auth.tf`, `irsa.tf`, `dr-agent.tf`, `addons.tf`,
  `eks.tf`.

### 3.25 Amazon DynamoDB (Terraform state lock)
- **What:** managed NoSQL key-value database; here used only for state locking.
- **Config:** table `cloudkitchen-tfstate-lock`, `PAY_PER_REQUEST`, hash key
  `LockID` (created by `bootstrap/`). The S3 backend references it via
  `dynamodb_table`.
- **Why:** prevents two `terraform apply` runs from corrupting the shared remote
  state by acquiring a distributed lock. (Newer Terraform offers S3-native
  `use_lockfile`, but DynamoDB is the widely-taught, rubric-named approach.)
- **Connections:** Terraform ↔ DynamoDB (lock) + S3 (state).
- **Code:** `bootstrap/main.tf`, `backend.tf`.

### 3.26 AWS Systems Manager Parameter Store (SSM)
- **What:** hierarchical configuration/parameter storage.
- **Config:** parameters under `/cloudkitchen/...` — e.g. `cors_origins` and the
  four Cognito pool/client ids (`auth.tf`).
- **Why:** a lightweight, free way to distribute non-secret configuration to the
  EC2 services (Topology A) at boot; on EKS this role is largely replaced by
  Secrets Manager + ESO, but the parameters remain as a config source.
- **Connections:** written by Terraform; read by EC2 instances (Topology A).
- **Code:** `auth.tf`, `main.tf`.

### 3.27 AWS Config (optional / "commented")
- **What:** continuous compliance and resource-configuration auditing.
- **Config:** gated behind `var.enable_aws_config` (**default `false`**, so
  normally **not deployed**). When enabled it provisions a configuration recorder
  and managed rules: `s3-bucket-public-read-prohibited` and `encrypted-volumes`.
- **Why:** demonstrates a compliance/governance capability (detect public S3
  buckets, unencrypted volumes). It is off by default to save cost during reviews,
  but the design is present and can be switched on with one variable.
- **Connections:** AWS Config recorder → evaluates resources → compliance status;
  no runtime dependency from the app.
- **Code:** `addons.tf` (guarded by `count = var.enable_aws_config ? 1 : 0`).

### 3.28 AWS KMS (encryption — implicit)
- **What:** key management for encryption at rest.
- **Config:** used implicitly — S3 server-side encryption (AES256), Secrets
  Manager encryption (AWS-managed key), RDS storage encryption, EBS volume
  encryption on nodes.
- **Why:** encryption at rest is a baseline security requirement; using
  AWS-managed keys keeps it simple and free while satisfying the control.
- **Connections:** S3, Secrets Manager, RDS, EBS all encrypt via KMS.
- **Code:** encryption blocks in `main.tf`, `addons.tf`, `bootstrap/main.tf`.

### 3.29 AWS STS (Security Token Service — implicit)
- **What:** issues temporary credentials.
- **Config:** used by **IRSA** (`AssumeRoleWithWebIdentity`) so pods get
  short-lived credentials, and by GitHub Actions if OIDC is enabled (currently CI
  uses static keys instead).
- **Why:** temporary credentials are safer than long-lived keys; STS is the engine
  behind IRSA.
- **Connections:** pod SA token → STS → temporary role credentials → AWS APIs.
- **Code:** implied by `irsa.tf` trust policies.

### 3.30 Application Load Balancer + Target Groups (Topology A only)
- **What:** L7 HTTP load balancer that routes by path to backend target groups.
- **Config (Topology A):** internet-facing ALB in public subnets; target groups
  per service (8080/8082/8001/8000); listener rules: `/api/orders*`→order,
  `/api/recommend*`→ai, `/auth/*`→auth, default→menu. Health checks per group.
- **Why:** the ALB was the entry point for the EC2 deployment, giving path-based
  routing, health checks, and TLS termination. **In Topology B it is removed** —
  kgateway + an NLB perform the equivalent role inside Kubernetes.
- **Connections:** CloudFront `/api/*` → ALB → target groups → EC2 ASG instances.
- **Code:** `main.tf` (removed in the EKS-only `cloudkitchen-infra`).

### 3.31 EC2 Auto Scaling Groups + Launch Templates (Topology A only)
- **What:** self-healing groups of EC2 instances built from launch templates.
- **Config (Topology A):** one ASG per service; launch templates run user-data
  that pulls the service code from S3 and starts it; ELB health checks; scaling
  configs. **Removed in Topology B** (replaced by EKS deployments).
- **Why:** the original compute tier — auto-healing and scalable without
  Kubernetes. Superseded by EKS for portability and GitOps.
- **Connections:** ASG instances ← target groups; → RDS, SQS, Secrets Manager.
- **Code:** `main.tf`, (formerly) `ai.tf`, `order.tf`, `auth.tf`.

### 3.32 Network Load Balancer (Topology B, created by Kubernetes)
- **What:** an L4 load balancer that fronts the kgateway Envoy proxy.
- **Config:** **not created by Terraform** — it is provisioned by Kubernetes when
  kgateway's `Gateway` requests a `Service type: LoadBalancer` (annotation
  `aws-load-balancer-type: nlb`). Internet-facing; targets the EKS nodes.
- **Why:** it gets external traffic onto the cluster (L4), where Envoy then does
  L7 routing. Using the in-tree provider avoids needing the AWS Load Balancer
  Controller + IRSA for a review.
- **Connections:** CloudFront/clients → NLB → kgateway Envoy pods → Services.
- **Important caveat:** because it is **outside Terraform state**, it must be
  deleted (by removing the Gateway / LoadBalancer Service) **before**
  `terraform destroy`, or its ENIs block VPC deletion. `destroy.sh` handles this.
- **Code:** created via the gitops Helm chart's `Gateway`, not Terraform.

---

## 4. Networking Deep Dive

### 4.1 The layered network
```
Internet
  │
  ▼
Internet Gateway ───────────────── public subnets (AZ-a, AZ-b)
  │                                   • NAT Gateway (+ EIP)
  │                                   • NLB / ALB (internet-facing)
  │                                   • EKS public ENIs
  ▼ (NAT for egress)
private-app subnets (AZ-a, AZ-b)
  • EKS worker nodes + pods
  • (Topology A) EC2 app ASGs
  │
  ▼ (5432 only, via security groups)
private-db subnets (AZ-a, AZ-b)
  • RDS PostgreSQL (DB subnet group)
```

### 4.2 Inbound path (how the internet reaches a pod)
1. DNS resolves the CloudFront domain → CloudFront edge.
2. CloudFront serves static from S3, or forwards `/api`,`/auth` to the **NLB**.
3. The **NLB** (in public subnets) forwards L4 to a node port that maps to the
   **kgateway Envoy** pods.
4. Envoy reads **HTTPRoute** rules and forwards to the right **ClusterIP Service**.
5. The Service load-balances to a healthy **pod**.

### 4.3 Outbound path (how a pod reaches the internet)
1. Pod (private-app subnet) sends traffic to `0.0.0.0/0`.
2. Private route table → **NAT Gateway** (public subnet).
3. NAT Gateway → **Internet Gateway** → internet (e.g., HuggingFace API, ECR).

### 4.4 Database path
- menu/order pods → (security group `db_sg` allows 5432 from the EKS cluster SG) →
  RDS in private-db subnets. RDS has **no public IP** and is unreachable from the
  internet.

### 4.5 Why three subnet tiers
- **Public:** only load balancers and NAT live here — the minimal internet-facing
  surface.
- **Private-app:** compute with outbound-only internet (via NAT).
- **Private-db:** data with no internet at all, reachable only from app SGs.

---

## 5. Security Model

### 5.1 Principles
1. **Least privilege everywhere** — scoped IAM roles/policies; IRSA per pod.
2. **No static credentials in pods** — IRSA + STS temporary tokens.
3. **No secrets in git or images** — Secrets Manager + External Secrets Operator;
   `terraform.tfvars` (HF token) is gitignored.
4. **Private by default** — RDS and compute have no public IPs; S3 is private
   behind CloudFront OAC; only load balancers face the internet.
5. **Encryption at rest** — S3 (AES256), Secrets Manager (KMS), RDS, EBS.
6. **HTTPS in transit** — CloudFront redirects to HTTPS.

### 5.2 The secret-management chain (Topology B)
```
terraform.tfvars (gitignored: HF token)         RDS / Cognito / SQS (Terraform-known values)
        │                                                 │
        └──────────────► AWS Secrets Manager ◄────────────┘
                          • cloudkitchen/db/credentials-new
                          • cloudkitchen/app/runtime
                                   │  (read via eso-irsa role, IRSA)
                                   ▼
                   External Secrets Operator (in EKS)
                                   │  materializes
                                   ▼
                   Kubernetes Secret "cloudkitchen-secrets" (namespace: production)
                                   │  envFrom
                                   ▼
                   Application pods (menu/order/auth/ai)
```

### 5.3 IRSA role-to-permission map
| Pod (ServiceAccount) | IAM role | Permissions |
|---|---|---|
| `ai` | cloudkitchen-ai-irsa | SQS ReceiveMessage/DeleteMessage on orders queue |
| `order` | cloudkitchen-order-irsa | SQS SendMessage on orders queue |
| `external-secrets-sa` | cloudkitchen-eso-irsa | SecretsManager GetSecretValue on db + app-runtime secrets |

### 5.4 Kubernetes-layer security (for completeness; K8s pillar)
- Pods run **non-root** (numeric UID), `runAsNonRoot`, dropped Linux capabilities,
  no privilege escalation, seccomp `RuntimeDefault`.
- **NetworkPolicy** default-denies ingress, allowing only the kgateway namespace.
- **RBAC** Role/RoleBinding gives the app SAs minimal in-namespace permissions.
- Images are **multistage** and run as non-root.

---

## 6. Data & State

### 6.1 Relational data (RDS)
- Single PostgreSQL database `cloudkitchen`.
- Schema owner: **menu-service** (Flyway migrations create `categories`,
  `menu_items`, `orders`, `order_items` + seed data).
- order-service uses the same DB (Flyway disabled). auth-service uses Cognito, not
  the DB.

### 6.2 Event data (SQS)
- `OrderPlaced` events flow order-service → orders queue → ai-recommender.
- The AI service keeps an **in-memory** per-item demand counter (resets if the AI
  pod restarts — a known limitation; production would persist to RDS/Redis).

### 6.3 Object data (S3)
- Frontend bundle, testimonial videos, DB backups, Terraform state.

### 6.4 Secrets (Secrets Manager)
- DB credentials + consolidated app runtime config (see §5.2).

### 6.5 Terraform state
- Remote state in the **S3 tfstate bucket**, locked by the **DynamoDB lock table**,
  both created by `bootstrap/` (run before the main stack).

---

## 7. Observability & Alerting

### 7.1 Metrics & dashboards
- **Prometheus** (in EKS) scrapes cluster/node/pod metrics.
- **Grafana** (in EKS, exposed via a public LoadBalancer) shows Kubernetes
  dashboards; reachable from any machine via the LB DNS link.
- **CloudWatch Container Insights** (EKS add-on) provides AWS-native
  cluster/pod metrics + container logs.

### 7.2 Alerting
- **Alertmanager → Slack:** the kube-prometheus-stack's built-in alert rules
  (pod crashloop, node not ready, high memory, target down, …) route
  warning/critical alerts to a Slack webhook (stored in a K8s secret, not git).
- **CloudWatch alarms → SNS → email:** DLQ depth and DR-agent Lambda errors.

### 7.3 Autonomous DR agent
- A scheduled LangGraph Lambda observes RDS + DLQ, reasons with an LLM, and alerts
  via SNS — an "AI watching the infrastructure" capability (see §2.8).

---

## 8. The Two Topologies (compared)

| Concern | Topology A — EC2 baseline | Topology B — EKS target |
|---|---|---|
| Compute | EC2 ASGs + launch templates | EKS managed node group (pods) |
| Ingress | ALB + target groups | kgateway (Envoy) + NLB |
| Routing | ALB listener rules | Gateway API HTTPRoutes |
| Image build | on-instance (Maven) / Terraform-built AI image | CI builds → ECR |
| Config/secrets | SSM + instance-role Secrets Manager reads | Secrets Manager → ESO → K8s Secret |
| Pod→AWS auth | EC2 instance roles | IRSA (per-pod roles) |
| Deploy | `terraform apply` builds everything | Terraform (infra) + ArgoCD (apps) |
| CloudFront `/api` origin | ALB | NLB |
| State of code | the original monorepo (`terraform-trouble`) | the 3 split repos (`repos/`) |

**Which is "current"?** Topology B (EKS) is the modernization target and the
canonical answer for production questions. Topology A still exists in the monorepo
and is what historically ran live.

---

## 9. Connection Matrix (what talks to what)

```
Browser ───────────────► CloudFront (HTTPS)
CloudFront ─────────────► S3 frontend (OAC)            [static]
CloudFront ─────────────► S3 testimonials (OAC)        [/testimonials/*]
CloudFront ─────────────► NLB (B) / ALB (A)            [/api/*, /auth/*]
NLB ────────────────────► kgateway Envoy (EKS nodes)
kgateway ───────────────► Service menu/order/auth/ai   [HTTPRoute by path]
menu-service ───────────► RDS PostgreSQL (5432)
order-service ──────────► RDS PostgreSQL (5432)
order-service ──────────► SQS orders queue (send)      [via order-irsa]
ai-recommender ◄──────── SQS orders queue (receive)    [via ai-irsa]
ai-recommender ─────────► HuggingFace API (HTTPS, via NAT)
auth-service ───────────► Cognito (SignUp/InitiateAuth)
SQS orders queue ───────► SQS DLQ (after 3 failures)
EventBridge ────────────► Lambda dr-agent (daily)
Lambda dr-agent ────────► RDS (describe), SQS (DLQ depth), SNS (publish), CW Logs
API Gateway ────────────► Lambda presign ─────────────► S3 testimonials (presigned PUT)
External Secrets Op ◄──── Secrets Manager (db + app_runtime) [via eso-irsa]
External Secrets Op ────► K8s Secret cloudkitchen-secrets
Pods ◄──────────────────  K8s Secret cloudkitchen-secrets (envFrom)
EKS nodes ──────────────► ECR (image pull)
CI (build.yml) ─────────► ECR (image push) ───────────► bump tag in gitops repo
ArgoCD ◄──────────────── gitops repo (Git) ───────────► applies Helm chart to EKS
Prometheus ─────────────► Grafana (dashboards), Alertmanager ──► Slack
Container Insights ─────► CloudWatch (metrics + logs)
CloudWatch alarms ──────► SNS ───────────────────────► email
Terraform ──────────────► S3 tfstate + DynamoDB lock
```

---

## 10. Cost Model

**Always-on (while deployed):** EKS control plane (~$72/mo), EKS nodes (3×
t3.medium), NAT Gateway (~$32/mo + data), NLB/ALB, RDS db.t3.micro. **Free-tier /
pay-per-use:** Lambda, SQS, SNS (low volume), S3, CloudFront (1 TB free), Cognito,
Secrets Manager (small), DynamoDB (lock, tiny), CloudWatch (basic). **AI:** the
LLM is HuggingFace's free Inference API (no Bedrock cost). The project is designed
to be **destroyed between demos** (`destroy.sh`) so nothing bills when idle.

---

## 11. Failure Modes & Recovery

| Failure | Detection | Mitigation |
|---|---|---|
| Order consumer crashes | SQS DLQ depth alarm → SNS | messages retained (4d) + DLQ (14d); reprocess |
| DB unhealthy | DR agent `rds:DescribeDBInstances` → SNS | RDS Multi-AZ option; backups bucket |
| Pod crashloop | Prometheus alert → Slack; ArgoCD self-heal | Deployment restarts; ArgoCD reconciles |
| Node failure | EKS managed node group | replaced automatically; multi-AZ |
| Bad deploy | ArgoCD diff/health | rollback to a previous Git commit |
| HF API down | AI falls back to rule-based output | recommendations/forecasts degrade gracefully |
| NLB orphan on destroy | — | `destroy.sh` deletes LB Services before `terraform destroy` |

---

## 12. FAQ (anticipated questions)

**Q: Where does the application run?**
A: On Amazon EKS (Topology B) as pods, or on EC2 Auto Scaling Groups (Topology A,
the original monorepo). EKS is the current/target model.

**Q: How do users reach the app?**
A: Through CloudFront. Static content comes from S3; `/api` and `/auth` are
forwarded to the EKS NLB → kgateway → the right service (or to the ALB in
Topology A).

**Q: How do pods get AWS permissions without access keys?**
A: IRSA — each pod's Kubernetes ServiceAccount is annotated with an IAM role; the
pod exchanges its projected token with STS for temporary credentials.

**Q: Where are secrets stored?**
A: AWS Secrets Manager (`cloudkitchen/db/credentials-new` and
`cloudkitchen/app/runtime`). External Secrets Operator syncs them into a
Kubernetes Secret. The HuggingFace token's source is the gitignored
`terraform.tfvars`, mirrored into Secrets Manager by Terraform.

**Q: What database is used and who owns the schema?**
A: Amazon RDS for PostgreSQL. menu-service owns the schema and runs Flyway
migrations; order-service shares the DB; auth-service uses Cognito instead.

**Q: How is the order pipeline event-driven?**
A: order-service publishes `OrderPlaced` to SQS; ai-recommender consumes it to
track real demand. Failed messages go to a DLQ after 3 attempts; a CloudWatch
alarm watches the DLQ.

**Q: What AI models are used and why not Bedrock?**
A: Mistral-7B via the HuggingFace Inference API (LLM reasoning) + local
sentence-transformers embeddings + ChromaDB vector store. HuggingFace is free and
open-source/portable; Bedrock bills per token and is AWS-locked — for a
cost-sensitive review the open-source path was chosen, with a clean migration path
to Bedrock for production.

**Q: Is the LLM hosted in AWS?**
A: No. Only the small embedding model + vector store run on the pod; the 7B LLM is
a remote HuggingFace API call (outbound via the NAT Gateway).

**Q: How is Terraform state managed?**
A: Remote state in an S3 bucket with a DynamoDB lock table, both created by the
`bootstrap/` configuration before the main stack.

**Q: What is the NAT Gateway for?**
A: Outbound internet for private resources (ECR pulls, HuggingFace API, package
installs) without making them publicly reachable.

**Q: Why is RDS not publicly accessible?**
A: It lives in private-db subnets with a security group that only allows 5432 from
the application/EKS security groups — never the internet.

**Q: What does the DR agent do?**
A: A scheduled LangGraph Lambda (daily via EventBridge) checks RDS and the SQS DLQ,
uses an LLM to write an incident summary, and alerts via SNS. It demonstrates
autonomous, explainable operations.

**Q: Is AWS Config used?**
A: It is implemented but gated behind `enable_aws_config` (default false), so
normally not deployed. When enabled it audits for public S3 buckets and
unencrypted volumes.

**Q: How does monitoring work?**
A: Prometheus + Grafana (Grafana exposed via a public LoadBalancer) inside EKS,
plus CloudWatch Container Insights. Alertmanager sends warning/critical alerts to
Slack; CloudWatch alarms send to SNS/email.

**Q: How are container images delivered?**
A: CI (cloudkitchen-app `build.yml`) builds, scans (Trivy/Semgrep), and pushes to
ECR, then bumps the image tag in the gitops repo; ArgoCD deploys the new tag to
EKS.

**Q: What is kgateway and why not just the ALB?**
A: kgateway is an Envoy-based Gateway API implementation running in the cluster. On
EKS it does L7 path routing (replacing the ALB's listener rules). The NLB just
gets traffic into the cluster; kgateway routes it to services.

**Q: What happens to the NLB on destroy?**
A: It is created by Kubernetes (not Terraform), so `destroy.sh` deletes the
LoadBalancer Services first; otherwise its ENIs block VPC deletion.

**Q: Which subnets host what?**
A: Public → NAT/IGW/load balancers; private-app → EKS nodes/pods (and EC2 in
Topology A); private-db → RDS only.

**Q: How is encryption handled?**
A: At rest via KMS (S3 AES256, Secrets Manager, RDS, EBS); in transit via HTTPS at
CloudFront.

**Q: Where do Cognito ids come from at runtime?**
A: From the `cloudkitchen/app/runtime` Secrets Manager secret (synced by ESO into
the K8s secret) on EKS, and from SSM Parameter Store on the EC2 topology.

**Q: How many Availability Zones?**
A: Two — every subnet tier and the EKS node group span both for resilience.

**Q: What is the testimonial upload path?**
A: Browser → API Gateway → presign Lambda → returns an S3 pre-signed URL → browser
uploads directly to the testimonials S3 bucket → CloudFront serves it back.

**Q: What is the single managed AWS service requirement satisfied by?**
A: Several — RDS, SQS, Cognito, Secrets Manager, API Gateway, EKS are all managed
services.

**Q: How is least privilege enforced for CI?**
A: CI currently uses scoped AWS access keys in GitHub Secrets (ECR push for the app
pipeline; broader for Terraform). GitHub OIDC is the documented hardening upgrade.

---

## 13. Glossary

- **AZ** — Availability Zone (an isolated datacenter within a region).
- **IRSA** — IAM Roles for Service Accounts (pod-level AWS auth via OIDC/STS).
- **OAC** — Origin Access Control (CloudFront→private S3 auth).
- **OIDC** — OpenID Connect (token-based federation; powers IRSA).
- **NLB / ALB** — Network (L4) / Application (L7) Load Balancer.
- **DLQ** — Dead Letter Queue (SQS holding area for failed messages).
- **ESO** — External Secrets Operator (Secrets Manager → K8s Secret).
- **Gateway API / HTTPRoute** — the Kubernetes standard for L7 routing (used by
  kgateway).
- **kgateway** — Envoy-based Gateway API implementation (in-cluster ingress/router).
- **Flyway** — database schema migration tool (owned by menu-service).
- **kube-prometheus-stack** — Helm chart bundling Prometheus + Grafana +
  Alertmanager.
- **Container Insights** — CloudWatch's Kubernetes metrics/logs feature.
- **STS** — Security Token Service (issues temporary credentials).
- **KMS** — Key Management Service (encryption keys).

---

## 14. Quick Index — service → Terraform file
| AWS Service | File(s) |
|---|---|
| VPC, subnets, IGW, NAT, route tables, SGs | `main.tf` |
| RDS PostgreSQL + db secret | `main.tf` |
| EKS cluster, node group, add-ons, eks→db SG rule, Container Insights | `eks.tf` |
| IRSA (OIDC provider, ai/order/eso roles), app-runtime secret | `irsa.tf` |
| ECR repositories + lifecycle | `ecr.tf` |
| SQS queue + DLQ + alarm | `sqs.tf` |
| Cognito pools/clients + SSM params | `auth.tf` |
| CloudFront, S3 (frontend/testimonials), API Gateway, presign/notification Lambdas, SNS, AWS Config | `addons.tf` |
| DR-agent Lambda, EventBridge schedule, DR IAM | `dr-agent.tf` |
| Backend (S3 + DynamoDB lock) | `backend.tf`, `bootstrap/main.tf` |
| Outputs | `outputs.tf` |
| Variables | `variables.tf` |

---

## 15. Detailed IAM Permissions (every role, exact actions)

This section lists the concrete permissions each IAM role/identity holds, so an AI
can answer "what can X do in AWS."

### 15.1 EKS cluster role (`cloudkitchen-eks-cluster-role`)
- Trust: `eks.amazonaws.com`.
- Managed policy: `AmazonEKSClusterPolicy`.
- Purpose: lets the EKS control plane manage cluster networking, ENIs, and AWS
  integrations on your behalf.

### 15.2 EKS node role (`cloudkitchen-eks-nodes-role`)
- Trust: `ec2.amazonaws.com`.
- Managed policies:
  - `AmazonEKSWorkerNodePolicy` — node ↔ control-plane communication.
  - `AmazonEKS_CNI_Policy` — vpc-cni assigns pod IPs from the VPC.
  - `AmazonEC2ContainerRegistryReadOnly` — pull images from ECR.
  - `CloudWatchAgentServerPolicy` — Container Insights agent pushes metrics/logs.
- Purpose: everything a worker node needs to join the cluster, network pods, pull
  images, and emit telemetry.

### 15.3 IRSA — `cloudkitchen-ai-irsa` (the `ai` pod)
- Trust: web identity from the EKS OIDC provider, condition
  `system:serviceaccount:production:ai` + audience `sts.amazonaws.com`.
- Inline policy (`cloudkitchen-ai-sqs-consume`):
  - `sqs:ReceiveMessage`, `sqs:DeleteMessage`, `sqs:GetQueueAttributes` on the
    orders queue ARN.
- Purpose: the AI pod consumes order events to build the real-time demand counter.

### 15.4 IRSA — `cloudkitchen-order-irsa` (the `order` pod)
- Trust: condition `system:serviceaccount:production:order`.
- Inline policy (`cloudkitchen-order-sqs-send`):
  - `sqs:SendMessage`, `sqs:GetQueueUrl`, `sqs:GetQueueAttributes` on the orders
    queue ARN.
- Purpose: the order pod publishes `OrderPlaced` events.

### 15.5 IRSA — `cloudkitchen-eso-irsa` (External Secrets Operator)
- Trust: condition `system:serviceaccount:production:external-secrets-sa`.
- Inline policy (`cloudkitchen-eso-secrets-read`):
  - `secretsmanager:GetSecretValue`, `secretsmanager:DescribeSecret` on the
    `cloudkitchen/db/credentials-new` and `cloudkitchen/app/runtime` secret ARNs.
- Purpose: ESO reads exactly those two secrets to materialize the K8s secret.

### 15.6 DR-agent Lambda role (`cloudkitchen-dr-agent-role`)
- Trust: `lambda.amazonaws.com`.
- Inline policy statements:
  - **Logs:** create log group/stream + put events on
    `/aws/lambda/cloudkitchen-dr-agent`.
  - **ReadHealth:** `rds:DescribeDBInstances` (+ historically ELB/ASG describe).
  - **SqsDlqRead:** `sqs:GetQueueAttributes` on the DLQ ARN.
  - **SnsPublish:** `sns:Publish` on the alerts topic ARN.
  - **S3Code:** `s3:GetObject` on its own deployment zip in the testimonials
    bucket.
- Purpose: least-privilege for an agent that observes health and alerts.
- Note (EKS-only cleanup item): the ELB/ASG describe + ASG scaling actions are now
  unused and can be trimmed for strict least privilege.

### 15.7 Lambda roles — presign / notification
- Trust: `lambda.amazonaws.com`.
- presign: `s3:PutObject` (and presign) on the testimonials bucket + logs.
- notification: SNS/SQS/logs as needed for notifications.

### 15.8 Topology A — EC2 instance roles (historical)
- `cloudkitchen-app-role` (menu/app): Secrets Manager read (db secret), SSM param
  read, S3 read (deployment zip), CloudWatch Logs, SSM Managed Instance Core.
- `cloudkitchen-auth-role`: Cognito (SignUp/AdminConfirmSignUp/InitiateAuth) on
  both pools, S3 read, CloudWatch Logs, SSM core.
- `cloudkitchen-order-role` / `cloudkitchen-ai-role`: SQS send / receive (now
  replaced by IRSA on EKS).

### 15.9 Terraform / CI identities
- Local Terraform: the operator's AWS credentials (admin-ish) provision everything.
- CI: AWS access keys in GitHub Secrets (app pipeline scoped to ECR push;
  Terraform pipeline broader). GitHub OIDC is the documented hardening upgrade.

---

## 16. Scenario Walkthroughs (narrative, end-to-end)

These narratives stitch services together so an AI can explain "what happens when…"

### 16.1 A customer orders Butter Chicken
1. The customer opens the site → CloudFront serves the React SPA from S3.
2. The SPA calls `GET /api/menu` → CloudFront → NLB → kgateway → menu Service →
   menu-service → RDS → returns the menu (including Butter Chicken).
3. The customer adds it to the cart and submits → `POST /api/orders` → … →
   order-service.
4. order-service writes the order + order_items to RDS in a transaction.
5. order-service publishes an `OrderPlaced` event to the SQS orders queue (using
   temporary credentials from the `order-irsa` role).
6. The ai-recommender's background SQS consumer (using `ai-irsa`) receives the
   event and increments the in-memory demand counter for "Butter Chicken."
7. The customer (or an operator) opens the AI dashboard → `GET
   /api/demand/realtime` → now shows Butter Chicken's real order count.
8. If the consumer had failed 3×, the message would land in the DLQ and the
   `cloudkitchen-orders-dlq-depth` CloudWatch alarm would publish to SNS → email.

### 16.2 An operator views the demand forecast
1. Operator opens the AI Dashboard → it loads `/api/menu` for the item list.
2. The dashboard calls `POST /api/recommend_forecast` with items + inventory.
3. ai-recommender, per item: takes the **real** demand from the SQS-fed counter
   (or an estimate if none yet), computes stock risk, and asks the HuggingFace
   Mistral-7B model (outbound via NAT) for a one-line insight.
4. The dashboard renders risk badges (UNDERSTOCK/OPTIMAL/OVERSTOCK) + AI insights,
   labeling each row "real orders" or "estimated."

### 16.3 A developer ships a code change (CI/CD + GitOps)
1. Developer pushes to `cloudkitchen-app` `main`.
2. `build.yml` runs: lint → unit tests → Semgrep (SAST) → Trivy (FS + image
   scan) → `docker build` → push to ECR tagged with the commit SHA.
3. A gated `deploy` job (GitHub Environment `production`, requires approval)
   checks out `cloudkitchen-gitops`, bumps the Helm `imageTag` to the SHA, commits.
4. ArgoCD detects the Git change and syncs the Helm chart to EKS.
5. ESO ensures `cloudkitchen-secrets` exists; the new pods roll out; kgateway
   routes traffic to them.

### 16.4 A nightly DR check
1. EventBridge fires at 02:00 UTC → invokes the dr-agent Lambda.
2. The LangGraph graph runs: **observe** (RDS status + DLQ depth) → **reason**
   (Mistral-7B writes a summary, or a rule-based fallback) → **act** (publish to
   SNS only if an incident is found) → **report** (structured CloudWatch log).
3. If RDS is not "available" or the DLQ exceeds the threshold, an SNS email goes
   out with the LLM narrative.

### 16.5 A full deploy (`deploy.sh`)
1. Bootstrap: create the S3 state bucket + DynamoDB lock table.
2. `terraform apply`: VPC, subnets, NAT, RDS, Secrets Manager, Cognito, SQS, ECR,
   EKS (cluster + nodes + add-ons + Container Insights), IRSA roles, DR-agent
   Lambda, EventBridge, S3 + CloudFront + API Gateway + SNS.
3. Build + push all 5 images to ECR.
4. `bootstrap/install.sh`: Gateway API CRDs, kgateway, External Secrets Operator,
   ArgoCD (public LB), kube-prometheus-stack (Grafana public LB + Alertmanager→
   Slack).
5. `kubectl apply` the ArgoCD project + application → ArgoCD deploys the app;
   ESO syncs secrets; kgateway provisions the NLB.
6. Output: public links for ArgoCD, Grafana, and the EKS NLB.

### 16.6 A full teardown (`destroy.sh`)
1. Delete the ArgoCD application (prunes the workloads + the gateway).
2. Delete **all** Kubernetes LoadBalancer Services (gateway, ArgoCD, Grafana) so
   their AWS NLBs/ELBs are removed and don't block VPC deletion.
3. `terraform destroy`: removes all Terraform-managed AWS resources. ECR
   `force_delete` clears images; the app-runtime secret has a 0-day recovery
   window so it can be recreated immediately next time. The S3 state bucket +
   DynamoDB lock (bootstrap) are intentionally **kept** so state persists.

---

## 17. Data Contracts (schemas an AI may be asked about)

### 17.1 Relational schema (RDS, owned by menu-service / Flyway `V1__init_schema.sql`)
- **categories**(`id` PK, `name` unique, `description`, `icon`, `created_at`)
- **menu_items**(`id` PK, `name`, `description`, `price` numeric, `category_id` FK→
  categories, `image_url`, `is_available` bool, `is_veg` bool, `prep_time` int,
  `rating` numeric, `created_at`, `updated_at`)
- **orders**(`id` PK, `customer_name`, `customer_email`, `customer_phone`,
  `delivery_address`, `status` default `PLACED`, `total_amount`, `payment_method`
  default `CASH_ON_DELIVERY`, `special_notes`, `created_at`, `updated_at`)
- **order_items**(`id` PK, `order_id` FK→orders ON DELETE CASCADE, `menu_item_id`
  FK→menu_items, `quantity`, `unit_price`, `subtotal`)
- Seed data: 6 categories, 22 menu items (Indian cuisine).

### 17.2 SQS `OrderPlaced` event (JSON body)
```json
{
  "orderId": 123,
  "customerEmail": "jane@example.com",
  "customerName": "Jane Doe",
  "items": [
    { "menuItemId": 5, "name": "Butter Chicken", "quantity": 2, "unitPrice": 399.00 }
  ],
  "totalAmount": 798.00,
  "timestamp": "2026-06-21T10:15:00"
}
```
The AI consumer keys its demand counter on the lowercased `name`.

### 17.3 HTTP endpoints by service
- **menu-service:** `GET /api/menu`, `GET /api/categories`.
- **order-service:** `POST /api/orders` (create), `GET /api/orders` (list — also
  the ALB/health path historically).
- **auth-service:** `POST /auth/...` for customer + restaurant register/login
  (Cognito-backed).
- **ai-recommender:** `POST /api/recommend`, `POST /api/recommend_quick`,
  `POST /api/recommend_forecast`, `GET /api/demand/realtime`,
  `POST /api/update_user_preferences`, `GET /api/health`.

### 17.4 Kubernetes routing (HTTPRoute path → service)
| Path prefix | Service | Port |
|---|---|---|
| `/api/orders` | order | 8082 |
| `/api/recommend`, `/api/demand`, `/api/update_user_preferences` | ai | 8000 |
| `/auth` | auth | 8001 |
| `/api` (catch-all) | menu | 8080 |

---

## 18. Operational Runbook (per-service health & common issues)

### 18.1 menu-service
- **Healthy when:** `GET /api/menu` returns 200 with items; the ALB/NLB target /
  pod is healthy.
- **Common failure (history):** could not pull its deployment zip from S3 (403) on
  the EC2 topology → service never started → empty menu + cart/order failures. On
  EKS this is a container image pulled from ECR (no S3 dependency).
- **DB dependency:** if RDS is unreachable (security group / down), Flyway/Hibernate
  fail at startup.

### 18.2 order-service
- **Healthy when:** `POST /api/orders` returns 200 and the order persists.
- **Common failure (history):** Jackson serialization of a lazy Hibernate proxy
  threw 500 on order create/list; fixed via `spring.jackson.serialization.
  fail-on-empty-beans: false`.
- **SQS dependency:** needs `order-irsa` (EKS) to send events; if missing, orders
  still save but events aren't published (the publisher logs and continues).

### 18.3 auth-service
- **Healthy when:** Cognito calls succeed; pool/client ids are present in env.
- **Common failure:** missing/incorrect Cognito ids → auth calls fail. Ids come
  from Secrets Manager (ESO) on EKS.

### 18.4 ai-recommender
- **Healthy when:** `GET /api/health` returns 200; the embedding model loaded.
- **Common failure (history):** a 12 GB image (CUDA torch) was too large; fixed
  with CPU-only torch (~2.5 GB). Also a pydantic/langchain version conflict broke
  `pip install`; fixed by relaxing the pydantic pin. If the HuggingFace token is
  missing/invalid, LLM calls fail and the service falls back to rule-based output.
- **Demand counter caveat:** in-memory; resets when the pod restarts.

### 18.5 Platform components (EKS)
- **kgateway:** if the `Gateway` is not `PROGRAMMED`, the NLB won't appear; check
  the kgateway controller and the GatewayClass.
- **ESO:** if the K8s secret is empty, check the `eso-irsa` annotation on the
  `external-secrets-sa` SA and that the Secrets Manager secrets exist.
- **ArgoCD:** app `OutOfSync`/`Degraded` → check image tags exist in ECR and the
  repoURL/branch are correct.
- **Prometheus/Grafana:** Grafana LB DNS appears ~2 min after install; admin
  password is in `monitoring/values.yaml`.

### 18.6 Destroy-time gotchas
- The k8s-created **NLB** must be deleted before `terraform destroy` (handled by
  `destroy.sh`).
- ECR repos need `force_delete` to delete with images (set).
- Secrets Manager deletion window set to 0 so names free immediately.

---

## 19. Requirement → AWS Service Mapping

| Requirement | Satisfied by |
|---|---|
| VPC, public/private subnets, multi-AZ, NAT | Amazon VPC, subnets, NAT Gateway (§3.1–3.5) |
| EKS cluster + managed node group + autoscaling | Amazon EKS + node group (§3.7–3.8) |
| Remote Terraform state + locking | S3 tfstate bucket + DynamoDB lock (§3.19, §3.25) |
| ECR | Amazon ECR (§3.11) |
| CloudWatch | CloudWatch logs/metrics/alarms + Container Insights (§3.22) |
| IAM + IRSA | IAM roles + OIDC/IRSA (§3.10, §3.24, §15) |
| At least one managed AWS service | RDS, SQS, Cognito, Secrets Manager, API Gateway, EKS |
| No static creds for pods | IRSA (§3.10, §5.3) |
| Secrets management | Secrets Manager → ESO → K8s Secret (§3.13, §5.2) |
| Event-driven communication (bonus) | SQS orders queue + DLQ (§3.15) |
| Monitoring (bonus) | Prometheus/Grafana + Container Insights (§7) |
| CDN / static hosting | CloudFront + S3 + OAC (§3.19–3.21) |
| Serverless | Lambda + API Gateway + EventBridge (§3.16–3.18) |
| Compliance/governance | AWS Config (optional, §3.27) |
| Encryption at rest | KMS via S3/Secrets Manager/RDS/EBS (§3.28) |

---

## 20. Extended FAQ

**Q: How many VPCs are there?** One, spanning two AZs.

**Q: Is the database multi-AZ?** It runs in multi-AZ *subnets*; RDS Multi-AZ
failover can be enabled on the instance for production (db.t3.micro is single-AZ by
default in the demo).

**Q: Can the AI service work if HuggingFace is down?** Yes — it falls back to
rule-based recommendations/insights; the app degrades gracefully rather than
erroring.

**Q: What protocol does the order→AI communication use?** Asynchronous messaging
over Amazon SQS (not a direct HTTP call), which decouples them.

**Q: Where is the Slack webhook stored?** In a Kubernetes secret
(`alertmanager-slack`) created from the gitignored tfvars — not in git, not in
Secrets Manager (that's a possible future consistency improvement).

**Q: What creates the NLB?** Kubernetes, when kgateway's Gateway requests a
`Service type: LoadBalancer` (in-tree AWS cloud provider). It is not a Terraform
resource.

**Q: How does CloudFront keep S3 private?** Origin Access Control + a bucket policy
allowing only the CloudFront service principal with a SourceArn condition; public
access is fully blocked on the buckets.

**Q: What is the difference between the orders queue and the DLQ?** The orders
queue carries live `OrderPlaced` events; the DLQ receives messages that failed
processing 3 times, for inspection/reprocessing.

**Q: Why two Cognito pools?** To separate customer identities from restaurant
identities (different tenancy and app clients).

**Q: Where does the HuggingFace token come from?** From `terraform.tfvars`
(gitignored); Terraform stores it in the `cloudkitchen/app/runtime` Secrets
Manager secret, which ESO syncs into the K8s secret consumed by the AI pod (and it
is also passed to the DR-agent Lambda's env).

**Q: How are images kept small/secure?** Multistage Docker builds, non-root users,
and Trivy scanning in CI; ECR keeps only the last 5 images per repo.

**Q: What happens to Terraform state on destroy?** The application stack is
destroyed, but the S3 state bucket + DynamoDB lock (created by `bootstrap/`) are
intentionally retained so state survives across destroy/recreate cycles.

**Q: How does a pod prove its identity to AWS?** Its ServiceAccount has a
projected OIDC token; it calls STS `AssumeRoleWithWebIdentity` against the role
named in the SA's `eks.amazonaws.com/role-arn` annotation.

**Q: Which components are internet-facing?** Only CloudFront and the load balancers
(NLB/ALB). Everything else (RDS, pods, EC2) is private.

**Q: How is the frontend deployed in the EKS model?** Built by CI and uploaded to
the S3 frontend bucket (served via CloudFront); it can also run as a container
image (the repo has a non-root Nginx Dockerfile).

**Q: What region and why?** ap-south-1 (Mumbai), chosen for the project's locale;
all services are regional except CloudFront (global) and IAM (global).

**Q: How are CloudWatch alarms wired to humans?** Alarms publish to the SNS topic
`cloudkitchen-alerts`, which has an email subscription.

**Q: What is Container Insights collecting?** Node/pod/cluster metrics and
container logs via the CloudWatch agent + Fluent Bit deployed by the
`amazon-cloudwatch-observability` add-on.

**Q: Is there autoscaling?** EKS node group min/desired/max (1/3/5); app-level HPA
and Cluster Autoscaler are roadmap items. Topology A used EC2 ASGs.

**Q: How is least privilege demonstrated?** Per-pod IRSA roles scoped to a single
queue/secret; per-Lambda roles scoped to specific ARNs; node role with only the
managed policies it needs.

**Q: What is the SPA fallback behavior?** CloudFront maps 404 → `/index.html`
(200) so deep links resolve to the React app.

**Q: How would you add a new microservice?** Add a Dockerfile + CI matrix entry
(app repo), add it to the Helm `services` list + an HTTPRoute (gitops), and (if it
needs AWS access) an IRSA role (infra) + SA annotation.

**Q: Where are the Cognito ids surfaced for the frontend/auth?** In the
`cloudkitchen/app/runtime` secret (USER_POOL_ID, USER_CLIENT_ID,
RESTAURANT_POOL_ID, RESTAURANT_CLIENT_ID), synced by ESO.

**Q: What encrypts Terraform state?** S3 server-side encryption on the state
bucket; access is locked via DynamoDB.

**Q: Does the DR agent take destructive actions?** No — in the EKS model it only
observes (RDS + DLQ) and publishes SNS alerts; it does not auto-scale or delete.

**Q: What's the blast radius if the NAT Gateway fails?** Private resources lose
outbound internet (ECR pulls, HuggingFace API) but stay reachable internally;
multi-AZ NAT can be added for resilience.

**Q: Why SQS instead of direct HTTP from order to AI?** Resilience and decoupling:
orders complete even if the AI service is down; the queue buffers and retries.

**Q: How is the gateway's traffic encrypted?** Today the NLB→Envoy path is HTTP
(no TLS at the gateway); CloudFront provides HTTPS to the client. TLS/ACM on the
gateway is a production hardening item.

**Q: What identifies resources as belonging to this project?** The `cloudkitchen`
name prefix and `var.global_tags` on every resource.

**Q: Where is the DR-agent code?** In `cloudkitchen-infra/lambda/dr-agent/`
(agent.py = LangGraph graph, tools.py = boto3 health checks), packaged by a
Terraform `null_resource` and uploaded to S3.

**Q: How do you point CloudFront at the EKS API in Topology B?** Set the
CloudFront `/api` (and `/auth`) behavior origin to the EKS NLB DNS after deploy,
or have the frontend call the NLB directly.

---

## 21. Deep Configuration Appendix (key parameters)

- **VPC CIDR:** `10.0.0.0/16` (see `var.vpc_cidr`).
- **AZs:** two (`var.availability_zones`).
- **EKS version:** 1.30. **Node type:** t3.medium. **Node count:** 1/3/5.
- **RDS:** PostgreSQL, db.t3.micro, db name `cloudkitchen`, user `postgres`,
  port 5432, private, encrypted.
- **SQS:** orders queue visibility 30s, long-poll 20s, retention 4d; DLQ retention
  14d; `maxReceiveCount` 3.
- **DR agent:** Python 3.11, 512 MB, 120s timeout, schedule `cron(0 2 * * ? *)`.
- **CloudWatch retention:** 30 days on the documented log groups.
- **ECR:** keep last 5 images per repo; scan on push; `force_delete = true`.
- **CloudFront:** default cert (HTTPS), redirect-to-https, SPA 404→index.html.
- **Secrets Manager:** `recovery_window_in_days = 0` on the app-runtime secret.
- **DynamoDB lock table:** `cloudkitchen-tfstate-lock`, PAY_PER_REQUEST, key
  `LockID`.
- **Grafana:** exposed via NLB; admin password in `monitoring/values.yaml`.
- **kube-prometheus-stack:** Prometheus retention 6h; Alertmanager → Slack on
  `warning|critical`.

---

## 22. Design Decisions & Trade-offs (why X, not Y)

For each major choice: the options considered and the rationale. Useful when a
reviewer (or AI) asks "why did you choose ___ instead of ___."

### 22.1 EKS vs ECS vs plain EC2
- **Options:** EKS (managed Kubernetes), ECS (AWS-native containers), EC2 ASGs.
- **Chosen:** EKS (Topology B), after starting on EC2 ASGs (Topology A).
- **Why:** the project requires Kubernetes (GitOps, ArgoCD, Gateway API,
  Prometheus). EKS is the portable, industry-standard choice and the rubric names
  EKS explicitly. ECS is simpler but AWS-locked and lacks the K8s ecosystem. EC2
  ASGs were the initial baseline but require hand-rolling deployment/scaling.

### 22.2 RDS PostgreSQL vs DynamoDB vs self-managed DB
- **Options:** RDS (managed relational), DynamoDB (managed NoSQL), DB on EC2.
- **Chosen:** RDS PostgreSQL.
- **Why:** orders need ACID transactions and relational integrity (orders ↔
  order_items ↔ menu_items). DynamoDB is great for key-value/scale but awkward for
  relational joins. Self-managing Postgres on EC2 means patching/backups/HA work
  we don't want. (DynamoDB *is* used — but only for Terraform state locking.)

### 22.3 SQS vs SNS vs Kafka/MSK vs direct HTTP
- **Options:** SQS (queue), SNS (pub/sub), MSK/Kafka (streaming), direct HTTP.
- **Chosen:** SQS for the order→AI path (SNS is used separately for alerts).
- **Why:** SQS gives a durable, decoupled, retryable queue with a DLQ — ideal for
  "process each order event once." SNS is fan-out (used for alerts, not work
  queues). Kafka/MSK is overkill and costly for this volume. Direct HTTP would
  couple order-service to the AI service's availability.

### 22.4 Cognito vs custom auth vs Auth0
- **Options:** Cognito (managed), roll-your-own (store password hashes), Auth0.
- **Chosen:** Cognito with two user pools.
- **Why:** managed identity removes the risk/effort of storing credentials,
  provides MFA + token issuance, and is native/free-tier on AWS. Two pools cleanly
  separate customers from restaurants.

### 22.5 HuggingFace Inference API vs Amazon Bedrock vs self-hosted LLM
- **Options:** HuggingFace API (Mistral-7B), Bedrock (Claude/Nova/Titan),
  self-hosted model on GPU.
- **Chosen:** HuggingFace Inference API + local sentence-transformers + ChromaDB.
- **Why:** cost (HF free tier vs Bedrock per-token), open-source/portability (no
  vendor lock-in), and Bedrock model access being gated per-region. Self-hosting a
  7B model needs GPUs (expensive). The AI layer is model-agnostic (LangChain),
  so a Bedrock swap is a small change for production.

### 22.6 External Secrets Operator vs HashiCorp Vault vs Secrets Store CSI
- **Options:** ESO (sync Secrets Manager → K8s), Vault (run a secret server),
  Secrets Store CSI driver (mount secrets as volumes).
- **Chosen:** ESO with AWS Secrets Manager.
- **Why:** ESO is the simplest, lowest-cost enterprise pattern when AWS Secrets
  Manager is already the source of truth — no extra server to run/unseal like
  Vault. CSI driver mounts work too but ESO's "materialize a native K8s Secret"
  model is cleaner for `envFrom`.

### 22.7 IRSA vs node instance role vs static access keys (for pods)
- **Options:** IRSA (per-pod roles), node role (all pods share it), static keys.
- **Chosen:** IRSA.
- **Why:** least privilege per pod + no long-lived credentials. The node role
  approach over-grants (every pod gets the node's permissions); static keys are the
  worst (leak risk, rotation burden). IRSA satisfies the rubric's "no static
  credentials."

### 22.8 kgateway (Gateway API) vs ALB Ingress vs Nginx Ingress
- **Options:** kgateway (Envoy + Gateway API), AWS Load Balancer Controller
  (ALB Ingress), ingress-nginx.
- **Chosen:** kgateway.
- **Why:** Gateway API is the modern successor to Ingress; kgateway (Envoy) gives
  powerful L7 routing and a clean `Gateway`/`HTTPRoute` model. ALB Ingress needs
  the LB Controller + IRSA setup; ingress-nginx is older. kgateway + an in-tree
  NLB avoids extra controller setup for the review.

### 22.9 NLB vs ALB (for the EKS entry point)
- **Options:** NLB (L4), ALB (L7).
- **Chosen:** NLB in front of kgateway.
- **Why:** the L7 routing is done by Envoy (kgateway) inside the cluster, so the
  external LB only needs to be a fast L4 pass-through (NLB). An ALB would duplicate
  the L7 logic. (In Topology A, with no in-cluster router, an ALB was the right L7
  choice.)

### 22.10 CloudFront + S3 vs serving the SPA from a pod
- **Options:** CloudFront + S3 (static), Nginx pod serving the SPA.
- **Chosen:** CloudFront + S3 for the SPA.
- **Why:** cheapest, most scalable, globally cached static hosting with free TLS
  and no servers. (A non-root Nginx container exists as an alternative for a fully
  in-cluster deployment.)

### 22.11 Lambda vs containers for presign + DR agent
- **Options:** Lambda (serverless), a long-running container/service.
- **Chosen:** Lambda.
- **Why:** both are event-driven/intermittent (presign per upload; DR agent once a
  day). Lambda is pay-per-invocation with zero idle cost — far cheaper and simpler
  than an always-on container for spiky/scheduled work.

### 22.12 DynamoDB lock vs S3 native lockfile (Terraform state)
- **Options:** DynamoDB table lock, S3 `use_lockfile` (newer).
- **Chosen:** DynamoDB lock (with `use_lockfile` as the modern alternative noted).
- **Why:** DynamoDB locking is the widely-taught, rubric-named approach and works
  on all Terraform versions. The bootstrap already provisions the table.

### 22.13 GitHub Actions keys vs OIDC (CI → AWS)
- **Options:** static AWS keys in GitHub Secrets, GitHub OIDC federation.
- **Chosen:** static keys (for the review), OIDC documented as the upgrade.
- **Why:** simplicity for the review; the rubric's "no static credentials" applies
  to *pods* (solved by IRSA). OIDC is the production-grade CI hardening and is a
  small, isolated change.

### 22.14 Three repos vs monorepo
- **Options:** one monorepo, three repos (app/infra/gitops).
- **Chosen:** three repos (the rubric requires it).
- **Why:** clean separation of concerns and access control; GitOps wants the
  manifests in their own repo that ArgoCD watches. The monorepo
  (`terraform-trouble`) remains as the original/working reference.

### 22.15 Multi-AZ + private subnets vs single-AZ public
- **Options:** simple single-AZ public deployment, multi-AZ private.
- **Chosen:** multi-AZ with private subnets.
- **Why:** resilience (AZ failure) and security (no public IPs on compute/data).
  The cost (NAT Gateway, multi-AZ) is accepted for a production-shaped design and
  mitigated by destroy-between-demos.

---

## 23. Per-Microservice Cloud Touchpoints

For each service: the AWS resources it depends on and the environment variables it
consumes (sourced from the synced K8s secret / Secrets Manager on EKS).

### 23.1 menu-service (Java, :8080)
- **AWS deps:** RDS (read/write), CloudWatch Logs.
- **Env:** `SPRING_DATASOURCE_URL`, `SPRING_DATASOURCE_USERNAME`,
  `SPRING_DATASOURCE_PASSWORD` (from `cloudkitchen-secrets`).
- **IAM:** none on EKS (DB access is via credentials, not an AWS API).
- **Notes:** owns Flyway migrations; the only service that creates the schema.

### 23.2 order-service (Java, :8082)
- **AWS deps:** RDS (read/write), **SQS** (send), CloudWatch Logs.
- **Env:** `SPRING_DATASOURCE_*`, `SQS_ORDERS_QUEUE_URL`, `AWS_REGION`.
- **IAM:** `cloudkitchen-order-irsa` (SQS send) via the `order` ServiceAccount.
- **Notes:** publishes `OrderPlaced`; Jackson lazy-proxy fix applied.

### 23.3 auth-service (Java, :8001)
- **AWS deps:** **Cognito** (two pools), CloudWatch Logs.
- **Env:** `USER_POOL_ID`, `USER_CLIENT_ID`, `RESTAURANT_POOL_ID`,
  `RESTAURANT_CLIENT_ID`, `AWS_REGION`.
- **IAM:** on EKS, Cognito calls can use the node role or an IRSA role; ids come
  from the secret. (On EC2, the auth instance role had explicit Cognito perms.)
- **Notes:** no database; identity is fully delegated to Cognito.

### 23.4 ai-recommender (Python, :8000)
- **AWS deps:** **SQS** (receive/delete), outbound **HuggingFace API** (via NAT),
  CloudWatch Logs.
- **Env:** `SQS_ORDERS_QUEUE_URL`, `AWS_REGION`, `HUGGINGFACEHUB_API_TOKEN`,
  `HF_MODEL`.
- **IAM:** `cloudkitchen-ai-irsa` (SQS consume) via the `ai` ServiceAccount.
- **Notes:** runs the SQS consumer thread; embeddings + ChromaDB local; LLM remote.

### 23.5 frontend (React/Nginx)
- **AWS deps:** S3 (hosting) + CloudFront (delivery); calls the API via the NLB.
- **Env (build-time):** API base URL (CloudFront / NLB).
- **Notes:** served as static from S3+CloudFront (or as a non-root Nginx pod).

---

## 24. Regional vs Global Services
- **Global:** CloudFront (edge), IAM (roles/policies/OIDC providers), Route 53 (not
  used here — CloudFront default domain is used).
- **Regional (ap-south-1):** VPC, EKS, EC2, RDS, SQS, SNS, Lambda, API Gateway,
  Cognito, Secrets Manager, ECR, CloudWatch, DynamoDB, SSM, EventBridge, S3
  (buckets are regional but the namespace is global).

---

## 25. Lifecycle of a Resource (create → use → destroy)
Taking the orders queue as an example:
1. **Create:** `terraform apply` creates `cloudkitchen-orders-queue` + DLQ
   (`sqs.tf`); IRSA policies (`irsa.tf`) grant order (send) and ai (receive).
2. **Use:** order-service sends events; ai-recommender consumes; DR agent reads
   DLQ depth; a CloudWatch alarm watches the DLQ.
3. **Destroy:** `terraform destroy` deletes both queues; the alarm and IAM policies
   go with them. No manual cleanup needed (no LB attached).

Contrast with the **NLB** (created by Kubernetes): it must be removed by deleting
the LoadBalancer Service *before* `terraform destroy`, because Terraform doesn't
own it.

---

## 26. Even More FAQ

**Q: What is `local.env_prefix`?** The string `cloudkitchen`, prepended to every
resource name for consistency and easy identification.

**Q: How do I find the public app URL?** It's the CloudFront distribution domain
(`terraform output cloudfront_url`).

**Q: How do I find the EKS API entry point?** `kubectl get gateway
cloudkitchen-gateway -n production -o jsonpath='{.status.addresses[0].value}'`
returns the NLB DNS.

**Q: What runs the Flyway migrations?** menu-service, on startup, against RDS.

**Q: Which services are stateless?** All four microservices (state is in RDS / SQS
/ Secrets Manager / S3), which is why no EBS persistence is needed on EKS.

**Q: What's the maximum number of EKS nodes?** 5 (node group `max_size`).

**Q: How are pod IPs assigned?** By the vpc-cni add-on, from the VPC subnet CIDR
(pods get real VPC IPs).

**Q: Does the order service fail if SQS is unavailable?** No — the order is saved
first; the SQS publish is best-effort and logged on failure, so the customer's
order still succeeds.

**Q: What's in the testimonials bucket?** User-uploaded videos (and, on Topology A,
service deployment zips).

**Q: How is the DR agent packaged?** A Terraform `null_resource` runs `pip install`
into a `package/` dir, an `archive_file` zips it, and it's uploaded to S3 and used
as the Lambda code.

**Q: Why is the app-runtime secret recovery window 0?** So a destroy/recreate the
same day isn't blocked by Secrets Manager's default 7–30 day name-reservation.

**Q: What CloudWatch alarms exist?** DLQ depth (→ SNS), DR-agent Lambda errors (→
SNS), and (Topology A) ALB 5xx.

**Q: How is HTTPS provided?** CloudFront with its default certificate
(redirect-to-https). Custom domain + ACM is a future item.

**Q: Where does Prometheus store data?** In-cluster (kube-prometheus-stack),
retention 6h (kept short for the small cluster).

**Q: What's the Grafana admin password?** Set in
`cloudkitchen-gitops/monitoring/values.yaml` (`cloudkitchen-admin` for the demo —
rotate for real use).

**Q: Are there any always-free components?** Effectively: Lambda (1M req/mo), SQS
(1M/mo), CloudFront (1 TB/mo), Cognito (MAU tier), within free-tier limits.

**Q: What's the single biggest idle cost?** The EKS control plane + NAT Gateway +
load balancers — hence destroy between demos.

**Q: How does ArgoCD know what to deploy?** From the `cloudkitchen-gitops` repo
(repoURL in `argocd/application.yaml`), path `helm/cloudkitchen`, branch `main`.

**Q: What namespace do the apps run in?** `production`.

**Q: How are images tagged?** By Git commit SHA (and `latest`) in CI; the GitOps
repo's `imageTag` is bumped to the SHA to trigger ArgoCD.

**Q: Can this run in another AWS account?** Yes — update the account id in the
backend bucket name + IRSA ARNs (or templatize), set tfvars, and apply. Names are
otherwise prefix-based and portable.

**Q: What's the relationship between this doc and ARCHITECTURE.md?** ARCHITECTURE.md
was an earlier, shorter overview; this document is the detailed AWS-cloud
reference and supersedes it for cloud questions.

**Q: How do the EC2 (Topology A) services get their config?** Via SSM Parameter
Store + Secrets Manager reads using their instance roles, at boot (user-data).

**Q: How does the AI demand counter survive deploys?** It doesn't — it's in-memory
and resets on pod restart; persistence (RDS/Redis) is a roadmap item. For demos,
seed it by placing orders (or replay events).

**Q: What is the `app_repo` ECR repository for?** A general/backend image
repository; the frontend image can use it. The four service-specific repos are
menu/order/auth/ai.

**Q: How is the gateway's public IP stable across recreates?** It isn't — the NLB
DNS changes each recreate; consumers (CloudFront origin / frontend config) must be
repointed, which is why the frontend API URL is injected at build/deploy time.

**Q: What protocol does CloudFront use to the ALB origin (Topology A)?** HTTP on
port 80 (`origin_protocol_policy = http-only`), since the ALB listens on 80.

**Q: How is the DLQ alarm evaluated?** `ApproximateNumberOfMessagesVisible > 0`
over a 60s period → publish to SNS.

**Q: What IAM principal does ESO use?** The `external-secrets-sa` ServiceAccount,
annotated with the `cloudkitchen-eso-irsa` role ARN.

**Q: Is there a WAF?** Not currently; AWS WAF on CloudFront/ALB is a possible
security enhancement.

**Q: How would you enable Bedrock instead of HuggingFace?** Swap the LLM call in
the AI recommender/DR agent to `langchain-aws` `ChatBedrock`, grant the pod/Lambda
`bedrock:InvokeModel` via IAM/IRSA, and enable the model in the region.

---

## 27. One-paragraph Summary (for quick context)
CloudKitchen is a microservices food-delivery platform on AWS. A React SPA is
served globally via CloudFront from a private S3 bucket. Dynamic traffic enters
through CloudFront to a Network Load Balancer, then kgateway (Envoy) on Amazon EKS
routes by path to four containerized services (menu, order, auth, ai). menu/order
use Amazon RDS PostgreSQL; order publishes events to Amazon SQS which the AI
service consumes for real-time demand; auth uses Amazon Cognito; the AI service
calls the HuggingFace Inference API (Mistral-7B) plus local embeddings/ChromaDB.
Pods get AWS permissions via IRSA (no static keys); secrets flow from AWS Secrets
Manager through the External Secrets Operator into Kubernetes. Testimonial uploads
are serverless (API Gateway → Lambda → S3 presigned URL). A scheduled LangGraph
Lambda (EventBridge) watches RDS + the SQS DLQ and alerts via SNS. Observability is
Prometheus + Grafana (public) plus CloudWatch Container Insights, with
Alertmanager → Slack and CloudWatch alarms → SNS → email. Everything is Terraform
(remote state in S3 + DynamoDB lock) and deployed via GitOps with ArgoCD; one
command brings it up and one tears it down.

---

## 28. Comprehensive Q&A by Category

### 28.1 Networking
**Q: What CIDR is the VPC?** `10.0.0.0/16`.
**Q: How many subnets total?** Six — public ×2, private-app ×2, private-db ×2
(one of each per AZ).
**Q: What lives in the public subnets?** NAT Gateway, Internet Gateway attachment,
and the internet-facing load balancers (NLB in B, ALB in A); EKS public ENIs.
**Q: Can RDS be reached from the internet?** No — it has no public IP and its
security group only allows 5432 from app/EKS security groups.
**Q: How do private pods reach the HuggingFace API?** Outbound via the NAT Gateway
→ Internet Gateway.
**Q: What port does the database use?** 5432 (PostgreSQL).
**Q: What ports do the services listen on?** menu 8080, order 8082, auth 8001, ai
8000; frontend container 8080 (or static via S3).
**Q: Is there a service mesh?** No mesh; kgateway (Envoy) is the edge router. A
mesh (e.g., Istio/Linkerd) is optional future work.
**Q: How is east-west traffic restricted?** A default-deny NetworkPolicy allows
only kgateway → app pods; egress is open (for RDS/SQS/HF/DNS).
**Q: What provides in-cluster DNS?** The coredns EKS add-on.
**Q: Are pod IPs from the VPC range?** Yes, via the vpc-cni add-on.

### 28.2 Security & IAM
**Q: How many IRSA roles are there?** Three: ai (SQS consume), order (SQS send),
eso (Secrets Manager read).
**Q: What is the trust condition on an IRSA role?** The OIDC subject
`system:serviceaccount:<namespace>:<sa-name>` + audience `sts.amazonaws.com`.
**Q: Do any pods hold static AWS keys?** No — all pod→AWS access is via IRSA.
**Q: Where is the HuggingFace token?** In gitignored tfvars → mirrored to Secrets
Manager (`cloudkitchen/app/runtime`) → ESO → K8s secret → AI pod env (and the
DR-agent Lambda env).
**Q: What encrypts data at rest?** KMS-backed encryption on S3 (AES256), Secrets
Manager, RDS storage, and EBS volumes.
**Q: What enforces HTTPS?** CloudFront (`redirect-to-https`).
**Q: How are S3 buckets kept private?** Public access blocks + CloudFront OAC +
bucket policies allowing only the CloudFront service principal.
**Q: What's the least-privilege story for Lambda?** Each Lambda has a role scoped
to specific ARNs (its log group, the DLQ, the SNS topic, its S3 object).
**Q: Is MFA available?** Yes via Cognito (configurable on the user pools).
**Q: How are secrets rotated?** Secrets Manager supports rotation; not automated
here, but the values refresh on each `terraform apply` (e.g., Cognito ids).

### 28.3 Data & State
**Q: Which service owns the DB schema?** menu-service (Flyway).
**Q: How many tables?** Four: categories, menu_items, orders, order_items.
**Q: How are orders linked to items?** order_items has FKs to orders (cascade
delete) and menu_items.
**Q: How is the order event shaped?** JSON with orderId, customer fields, items
(name + quantity + unitPrice), totalAmount, timestamp.
**Q: Where is Terraform state?** S3 (`cloudkitchen-tfstate-<acct>`), locked by the
DynamoDB table `cloudkitchen-tfstate-lock`.
**Q: What happens to state on destroy?** Preserved — only the app stack is
destroyed; the bootstrap state backend persists.
**Q: Where are DB backups?** The `cloudkitchen-db-backups-<acct>` S3 bucket
(versioned, lifecycle to IA at 30d, expire at 90d) plus RDS automated backups.
**Q: Is the AI demand data durable?** No — in-memory in the AI pod; resets on
restart (roadmap: persist to RDS/Redis).

### 28.4 Compute & Scaling
**Q: What instance type are the EKS nodes?** t3.medium (2 vCPU / 4 GB).
**Q: How many nodes?** desired 3, min 1, max 5.
**Q: How do the apps scale?** By Deployment replica count (2 each, ai 1); HPA is a
roadmap item. Nodes scale within the node group min/max.
**Q: What runtime is the AI service?** Python 3.12 (FastAPI) in a CPU-only
container (~2.5 GB after the CUDA-torch fix).
**Q: What runtime are the Java services?** Java 17 (Spring Boot 3.2), multistage
images running as non-root.
**Q: How is the DR agent run?** As a scheduled Lambda (Python 3.11), not a
container.
**Q: How does EKS replace a failed node?** The managed node group provisions a
replacement automatically; pods reschedule.

### 28.5 Observability
**Q: What dashboards does Grafana show?** kube-prometheus-stack's default
Kubernetes cluster/node/pod dashboards.
**Q: How is Grafana reached?** A public LoadBalancer DNS link (admin /
cloudkitchen-admin).
**Q: What sends alerts to Slack?** Alertmanager (warning|critical rules) → Slack
webhook (from a K8s secret).
**Q: What sends alerts to email?** CloudWatch alarms → SNS topic → email.
**Q: What does Container Insights collect?** Node/pod/cluster metrics + container
logs via the CloudWatch agent + Fluent Bit add-on.
**Q: What metrics does Prometheus scrape?** Cluster/node/pod metrics (kube-state-
metrics, node-exporter, kubelet). App `/metrics` + ServiceMonitor is a roadmap
item for service-level panels.
**Q: How long is Prometheus retention?** 6 hours (kept small for the cluster).

### 28.6 Cost
**Q: What costs money while running?** EKS control plane, EKS nodes, NAT Gateway,
load balancers, RDS.
**Q: What's effectively free/pay-per-use?** Lambda, SQS, SNS, S3, CloudFront,
Cognito, DynamoDB (lock), CloudWatch basic.
**Q: How is cost controlled?** Single-command `destroy.sh` between demos; small
instance classes; ECR keep-last-5; HuggingFace free LLM instead of Bedrock.
**Q: Does the AI feature cost per call?** No — HuggingFace Inference API free tier;
embeddings/vector store run locally on the pod.

### 28.7 The cloud↔CI/CD↔K8s boundary
**Q: Who builds images?** CI in cloudkitchen-app (`build.yml`) → pushes to ECR.
**Q: Who deploys to EKS?** ArgoCD, watching the cloudkitchen-gitops repo.
**Q: Who provisions AWS?** Terraform in cloudkitchen-infra.
**Q: How does a code change reach production?** push → CI builds/scans/pushes →
bumps the GitOps image tag → ArgoCD syncs → EKS rolls out.
**Q: Where do the IRSA role ARNs used by K8s come from?** Terraform outputs
(`ai_irsa_role_arn`, `order_irsa_role_arn`, `eso_irsa_role_arn`); the gitops chart
references them in ServiceAccount annotations (deterministic ARNs).

### 28.8 Troubleshooting (cloud symptoms)
**Q: Empty menu / cart errors — cloud cause?** menu-service can't reach RDS, or
(history) couldn't pull its artifact; check the DB security group + the pod logs.
**Q: 502 on /api/*?** The target (pod/instance) is unhealthy or the LB has no
healthy targets; check kgateway/Service endpoints and pod readiness.
**Q: AI "warming up" / 502?** The AI pod is still pulling the image or installing;
check the pod status and image in ECR.
**Q: terraform destroy hangs on the VPC?** A k8s-created NLB's ENIs are still
present; delete the LoadBalancer Services first (`destroy.sh` does this).
**Q: terraform destroy fails on ECR?** Repos contain images; `force_delete = true`
is set to handle this.
**Q: Secrets Manager "scheduled for deletion" on recreate?** Mitigated by
`recovery_window_in_days = 0` on the app-runtime secret.
**Q: ESO secret empty?** Check the `eso-irsa` SA annotation and that the Secrets
Manager secrets exist + the SecretStore region is correct.

### 28.9 "Explain to a reviewer" prompts
**Q: Explain the request flow in one sentence.** Browser → CloudFront →
NLB → kgateway (Envoy) → Kubernetes Service → pod → (RDS / SQS / Cognito / HF API).
**Q: Explain the secret flow in one sentence.** AWS Secrets Manager → External
Secrets Operator (via IRSA) → Kubernetes Secret → pod env.
**Q: Explain the event flow in one sentence.** order-service → SQS → ai-recommender
(with a DLQ for failures and a CloudWatch alarm).
**Q: Explain the deploy flow in one sentence.** Terraform builds AWS infra; CI
builds images to ECR; ArgoCD deploys the Helm chart to EKS from Git.
**Q: Name the managed AWS services used.** EKS, RDS, SQS, SNS, Cognito, Secrets
Manager, API Gateway, Lambda, CloudFront, ECR, CloudWatch, EventBridge, DynamoDB,
SSM, (optional) Config.

---

## 29. Ports & Protocols Reference
| From | To | Port/Protocol | Purpose |
|---|---|---|---|
| Browser | CloudFront | 443 / HTTPS | all client traffic |
| CloudFront | S3 | 443 / HTTPS (OAC) | static + media |
| CloudFront | NLB (B) / ALB (A) | 80 or 443 | API/auth |
| NLB | kgateway Envoy | 80 / TCP | L4 into cluster |
| kgateway | Service/pod | service port / HTTP | L7 routing |
| menu/order pod | RDS | 5432 / TCP (PostgreSQL) | data |
| order pod | SQS | 443 / HTTPS (AWS API) | send events |
| ai pod | SQS | 443 / HTTPS | receive events |
| ai pod / DR Lambda | HuggingFace | 443 / HTTPS (via NAT) | LLM |
| auth pod | Cognito | 443 / HTTPS | identity |
| ESO | Secrets Manager | 443 / HTTPS (IRSA/STS) | read secrets |
| EKS nodes | ECR | 443 / HTTPS | image pull |
| EventBridge | Lambda | AWS internal | scheduled trigger |
| API Gateway | Lambda | AWS internal | presign |
| Browser | S3 (presigned) | 443 / HTTPS PUT | video upload |
| CloudWatch alarm | SNS | AWS internal | alert |
| SNS | email | SMTP/AWS | notify |
| Prometheus | pods/nodes | scrape / HTTP | metrics |
| Alertmanager | Slack | 443 / HTTPS | alert |

---

## 30. Service-Name Cheat Sheet (resource → friendly name)
| Terraform/AWS name | What it is |
|---|---|
| `aws_vpc.main` | The VPC |
| `aws_subnet.public/private_app/private_db` | The three subnet tiers |
| `aws_nat_gateway.main` | NAT Gateway |
| `aws_eks_cluster.cloudkitchen` | EKS control plane |
| `aws_eks_node_group.main` | EKS worker nodes |
| `aws_iam_openid_connect_provider.eks` | OIDC provider for IRSA |
| `aws_iam_role.ai_irsa/order_irsa/eso_irsa` | IRSA roles |
| `aws_db_instance.this` | RDS PostgreSQL |
| `aws_secretsmanager_secret.db` | DB credentials secret |
| `aws_secretsmanager_secret.app_runtime` | App runtime config secret |
| `aws_cognito_user_pool.users/restaurants` | The two Cognito pools |
| `aws_sqs_queue.orders_queue/orders_dlq` | Orders queue + DLQ |
| `aws_lambda_function.dr_agent` | DR agent Lambda |
| `aws_cloudfront_distribution.cdn` | CloudFront |
| `aws_s3_bucket.frontend/testimonials/backups` | App S3 buckets |
| `aws_apigatewayv2_api.testimonials_api` | API Gateway (presign) |
| `aws_sns_topic.alerts` | Alerts topic |
| `aws_dynamodb_table.tfstate_lock` (bootstrap) | State lock table |
| `aws_ecr_repository.*_repo` | The 5 ECR repos |

---

*End of AWS Cloud Reference (v4 — 2000+ lines). Pillars: CI/CD
(`cloudkitchen-app/.github/workflows`), Infrastructure (`cloudkitchen-infra`
Terraform), Kubernetes (`cloudkitchen-gitops`), Cloud (this document).
Self-sufficient for any AI assistant answering questions about the project's AWS
cloud design.*
