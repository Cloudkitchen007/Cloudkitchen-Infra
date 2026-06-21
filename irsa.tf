# =============================================================================
# IRSA (IAM Roles for Service Accounts) + ESO secret source
#
# Lets EKS pods assume scoped IAM roles via the cluster's OIDC provider — no
# static AWS access keys in pods. Two roles:
#   • eso-irsa : External Secrets Operator reads from AWS Secrets Manager
#   • ai-irsa  : the AI pod consumes the SQS orders queue
#
# Also publishes a consolidated app-runtime secret in Secrets Manager that ESO
# syncs into the `cloudkitchen-secrets` Kubernetes Secret (GitOps secret flow).
# =============================================================================

# ── OIDC provider (the IRSA foundation) ──────────────────────────────────────
data "tls_certificate" "eks" {
  url = aws_eks_cluster.cloudkitchen.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  url             = aws_eks_cluster.cloudkitchen.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  tags            = var.global_tags
}

locals {
  oidc_url      = replace(aws_eks_cluster.cloudkitchen.identity[0].oidc[0].issuer, "https://", "")
  k8s_namespace = "production"
}

# ── IRSA role: External Secrets Operator (read Secrets Manager) ───────────────
data "aws_iam_policy_document" "eso_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_url}:sub"
      values   = ["system:serviceaccount:${local.k8s_namespace}:external-secrets-sa"]
    }
  }
}

resource "aws_iam_role" "eso_irsa" {
  name               = "${local.env_prefix}-eso-irsa"
  assume_role_policy = data.aws_iam_policy_document.eso_assume.json
  tags               = var.global_tags
}

resource "aws_iam_role_policy" "eso_secrets_read" {
  name = "${local.env_prefix}-eso-secrets-read"
  role = aws_iam_role.eso_irsa.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
      Resource = [aws_secretsmanager_secret.db.arn, aws_secretsmanager_secret.app_runtime.arn]
    }]
  })
}

# ── IRSA role: AI pod (consume SQS orders queue) ──────────────────────────────
data "aws_iam_policy_document" "ai_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_url}:sub"
      values   = ["system:serviceaccount:${local.k8s_namespace}:ai"]
    }
  }
}

resource "aws_iam_role" "ai_irsa" {
  name               = "${local.env_prefix}-ai-irsa"
  assume_role_policy = data.aws_iam_policy_document.ai_assume.json
  tags               = var.global_tags
}

resource "aws_iam_role_policy" "ai_sqs" {
  name = "${local.env_prefix}-ai-sqs-consume"
  role = aws_iam_role.ai_irsa.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
      Resource = [aws_sqs_queue.orders_queue.arn]
    }]
  })
}

# ── IRSA role: order pod (publish to SQS orders queue) ────────────────────────
data "aws_iam_policy_document" "order_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_url}:sub"
      values   = ["system:serviceaccount:${local.k8s_namespace}:order"]
    }
  }
}

resource "aws_iam_role" "order_irsa" {
  name               = "${local.env_prefix}-order-irsa"
  assume_role_policy = data.aws_iam_policy_document.order_assume.json
  tags               = var.global_tags
}

resource "aws_iam_role_policy" "order_sqs" {
  name = "${local.env_prefix}-order-sqs-send"
  role = aws_iam_role.order_irsa.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["sqs:SendMessage", "sqs:GetQueueUrl", "sqs:GetQueueAttributes"]
      Resource = [aws_sqs_queue.orders_queue.arn]
    }]
  })
}

# ── Consolidated app-runtime secret (ESO syncs this → cloudkitchen-secrets) ───
# Non‑DB‑password values are assembled by Terraform from live resources, so a
# destroy/recreate always produces fresh Cognito IDs / endpoints. The DB
# password stays only in the existing `aws_secretsmanager_secret.db`.
resource "aws_secretsmanager_secret" "app_runtime" {
  name                    = "cloudkitchen/app/runtime"
  recovery_window_in_days = 0 # allow immediate re-create on daily destroy/apply
  tags                    = var.global_tags
}

resource "aws_secretsmanager_secret_version" "app_runtime" {
  secret_id = aws_secretsmanager_secret.app_runtime.id
  secret_string = jsonencode({
    SPRING_DATASOURCE_URL      = "jdbc:postgresql://${aws_db_instance.this.address}:5432/${aws_db_instance.this.db_name}"
    SPRING_DATASOURCE_USERNAME = aws_db_instance.this.username
    HUGGINGFACEHUB_API_TOKEN   = var.hf_api_token
    SQS_ORDERS_QUEUE_URL       = aws_sqs_queue.orders_queue.url
    HF_MODEL                   = "mistralai/Mistral-7B-Instruct-v0.3"
    USER_POOL_ID               = aws_cognito_user_pool.users.id
    USER_CLIENT_ID             = aws_cognito_user_pool_client.users.id
    RESTAURANT_POOL_ID         = aws_cognito_user_pool.restaurants.id
    RESTAURANT_CLIENT_ID       = aws_cognito_user_pool_client.restaurants.id
  })
}

# ── Outputs: role ARNs for the GitOps ServiceAccount annotations ──────────────
output "oidc_provider_arn" {
  description = "EKS OIDC provider ARN (IRSA)"
  value       = aws_iam_openid_connect_provider.eks.arn
}
output "eso_irsa_role_arn" {
  description = "IRSA role ARN for External Secrets Operator"
  value       = aws_iam_role.eso_irsa.arn
}
output "ai_irsa_role_arn" {
  description = "IRSA role ARN for the AI service account"
  value       = aws_iam_role.ai_irsa.arn
}
output "order_irsa_role_arn" {
  description = "IRSA role ARN for the order service account"
  value       = aws_iam_role.order_irsa.arn
}
