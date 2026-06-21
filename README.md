# cloudkitchen-infra

Terraform for all CloudKitchen AWS infrastructure.

## What it provisions
VPC (multi-AZ, public/private subnets, NAT) · EKS + managed node group · ECR ·
RDS PostgreSQL · SQS (+DLQ) · Cognito · Secrets Manager · Lambda + EventBridge
(DR agent) · CloudWatch · IAM · **IRSA (OIDC provider + scoped roles)** · S3
remote state.

## Key files
| File | Purpose |
|---|---|
| `eks.tf` | EKS cluster, node group, add-ons, RDS→EKS SG rule |
| `irsa.tf` | **OIDC provider + IRSA roles** (ESO → Secrets Manager, AI → SQS) + `cloudkitchen/app/runtime` secret for ESO |
| `ecr.tf` | 5 repos (force_delete, lifecycle) |
| `backend.tf` | S3 remote state |

## Prereqs
`terraform.tfvars` (gitignored) must define `hf_api_token`, `key_name`, AMI ids.

## Outputs for the GitOps repo
`terraform output` exposes `ai_irsa_role_arn`, `eso_irsa_role_arn`,
`oidc_provider_arn` — used by the ServiceAccount IRSA annotations in
`cloudkitchen-gitops`.

## ⚠️ 3-repo note (priority-2 CI/CD)
`ai.tf` / `addons.tf` currently build the AI image and the frontend from
`../services` (monorepo layout). In the split model those builds move to
**cloudkitchen-app CI**; remove the build `null_resource`s here so this repo only
provisions infrastructure. (Tracked as the CI/CD task.)

## State locking
Add a DynamoDB lock table for the rubric (see `backend.tf`); currently uses S3
native `use_lockfile`.

```bash
terraform init && terraform apply
```
