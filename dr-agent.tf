# =============================================================================
# CLOUDKITCHEN – DISASTER RECOVERY AI AGENT
#
# A LangGraph-based autonomous agent that runs every 5 minutes via EventBridge.
#
# Graph: observe → reason (Mistral-7B) → [act | skip] → report
#
# What it checks:
#   • RDS PostgreSQL instance status
#   • ALB target group health (all 4 services)
#   • ASG in-service instance counts
#   • SQS orders dead-letter queue depth
#
# What it can do automatically:
#   • Scale up a degraded ASG (safe: capped at max_size)
#   • Publish an SNS incident alert with LLM-generated narrative
#   • Emit structured CloudWatch logs on every run
# =============================================================================

locals {
  dr_lambda_name = "${local.env_prefix}-dr-agent"
}

# ── 1. Build Lambda package ──────────────────────────────────────────────────
# Rebuilds whenever agent.py, tools.py, or requirements.txt change.
# Searches common Windows Python install paths so it works even if Python
# was just installed and the current shell hasn't picked up the new PATH yet.

resource "null_resource" "dr_agent_build" {
  triggers = {
    agent_hash = filemd5("${path.module}/lambda/dr-agent/agent.py")
    tools_hash = filemd5("${path.module}/lambda/dr-agent/tools.py")
    reqs_hash  = filemd5("${path.module}/lambda/dr-agent/requirements.txt")
  }

  # Install deps + copy sources into package/
  # Uses bash so it works on Linux CI (ubuntu-latest) AND Windows Git Bash.
  # Falls back through several pip locations for Windows where Python may not be in PATH.
  provisioner "local-exec" {
    working_dir = "${path.module}/lambda/dr-agent"
    interpreter = ["bash", "-c"]
    command     = <<-CMD
      set -e
      rm -rf package && mkdir -p package
      echo "DR Agent: installing Python dependencies..."
      pip3 install -r requirements.txt -t package -q 2>/dev/null \
        || pip install -r requirements.txt -t package -q 2>/dev/null \
        || python3 -m pip install -r requirements.txt -t package -q 2>/dev/null \
        || "$HOME/AppData/Local/Programs/Python/Python313/Scripts/pip3.exe" install -r requirements.txt -t package -q \
        || "$HOME/AppData/Local/Programs/Python/Python312/Scripts/pip3.exe" install -r requirements.txt -t package -q \
        || "$HOME/AppData/Local/Programs/Python/Python311/Scripts/pip3.exe" install -r requirements.txt -t package -q \
        || { echo "ERROR: pip not found. Install Python 3.11+ and re-run terraform apply."; exit 1; }
      cp agent.py tools.py package/
      echo "DR Agent Lambda package ready."
    CMD
  }
}

data "archive_file" "dr_agent_zip" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/dr-agent/package"
  output_path = "${path.module}/dr_agent.zip"
  depends_on  = [null_resource.dr_agent_build]
}

# ── 2. Upload to S3 ──────────────────────────────────────────────────────────

resource "aws_s3_object" "dr_agent_code" {
  bucket = aws_s3_bucket.testimonials.id
  key    = "deployments/dr_agent.zip"
  source = data.archive_file.dr_agent_zip.output_path
  etag   = data.archive_file.dr_agent_zip.output_md5
}

# ── 3. IAM Role for Lambda ────────────────────────────────────────────────────

resource "aws_iam_role" "dr_agent_role" {
  name = "${local.env_prefix}-dr-agent-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.global_tags
}

resource "aws_iam_role_policy" "dr_agent_policy" {
  name = "${local.env_prefix}-dr-agent-policy"
  role = aws_iam_role.dr_agent_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # CloudWatch Logs
      {
        Sid      = "Logs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${local.dr_lambda_name}:*"
      },
      # Read AWS health — RDS, ALB, ASG
      {
        Sid    = "ReadHealth"
        Effect = "Allow"
        Action = [
          "rds:DescribeDBInstances",
          "elasticloadbalancing:DescribeTargetGroups",
          "elasticloadbalancing:DescribeTargetHealth",
          "autoscaling:DescribeAutoScalingGroups",
        ]
        Resource = "*"
      },
      # Recovery actions
      {
        Sid    = "RecoveryActions"
        Effect = "Allow"
        Action = [
          "autoscaling:UpdateAutoScalingGroup",
          "autoscaling:StartInstanceRefresh",
        ]
        Resource = "*"
      },
      # SQS — read DLQ depth
      {
        Sid      = "SqsDlqRead"
        Effect   = "Allow"
        Action   = ["sqs:GetQueueAttributes"]
        Resource = aws_sqs_queue.orders_dlq.arn
      },
      # SNS — publish alerts
      {
        Sid      = "SnsPublish"
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = aws_sns_topic.alerts.arn
      },
      # S3 — read own deployment zip (for potential future live reload)
      {
        Sid      = "S3Code"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${aws_s3_bucket.testimonials.arn}/deployments/dr_agent.zip"
      },
    ]
  })
}

# ── 4. Lambda Function ────────────────────────────────────────────────────────

resource "aws_lambda_function" "dr_agent" {
  function_name = local.dr_lambda_name
  role          = aws_iam_role.dr_agent_role.arn
  handler       = "agent.lambda_handler"
  runtime       = "python3.11"
  timeout       = 120 # 2 min: LLM call can take ~30s on free tier
  memory_size   = 512 # LangGraph + LangChain need reasonable headroom

  s3_bucket = aws_s3_bucket.testimonials.id
  s3_key    = aws_s3_object.dr_agent_code.key

  source_code_hash = data.archive_file.dr_agent_zip.output_base64sha256

  environment {
    variables = {
      AWS_REGION_NAME          = var.aws_region # avoid conflict with reserved AWS_REGION
      HUGGINGFACEHUB_API_TOKEN = var.hf_api_token
      HF_MODEL                 = "mistralai/Mistral-7B-Instruct-v0.3"
      DLQ_ALARM_THRESHOLD      = "5"

      # Resource identifiers — injected at deploy time by Terraform.
      # EKS-only: the agent monitors RDS health + the SQS DLQ (the EC2 ALB/ASG
      # targets were removed in the EKS migration).
      RDS_DB_IDENTIFIER = aws_db_instance.this.identifier
      ORDERS_DLQ_URL    = aws_sqs_queue.orders_dlq.url
      SNS_TOPIC_ARN     = aws_sns_topic.alerts.arn
    }
  }

  depends_on = [
    aws_iam_role_policy.dr_agent_policy,
    aws_s3_object.dr_agent_code,
  ]

  tags = var.global_tags
}

# ── 5. CloudWatch Log Group ───────────────────────────────────────────────────

resource "aws_cloudwatch_log_group" "dr_agent" {
  name              = "/aws/lambda/${local.dr_lambda_name}"
  retention_in_days = 30
  tags              = var.global_tags
}

# ── 6. EventBridge Rule — every 5 minutes ────────────────────────────────────

resource "aws_cloudwatch_event_rule" "dr_agent_schedule" {
  name                = "${local.env_prefix}-dr-agent-schedule"
  description         = "Triggers CloudKitchen DR Agent every 5 minutes for continuous health monitoring"
  schedule_expression = "cron(0 2 * * ? *)" # daily at 02:00 UTC
  state               = "ENABLED"
  tags                = var.global_tags
}

resource "aws_cloudwatch_event_target" "dr_agent_target" {
  rule      = aws_cloudwatch_event_rule.dr_agent_schedule.name
  target_id = "cloudkitchen-dr-agent"
  arn       = aws_lambda_function.dr_agent.arn

  input = jsonencode({
    source  = "aws.events"
    trigger = "scheduled-5min"
  })
}

resource "aws_lambda_permission" "eventbridge_invoke" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.dr_agent.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.dr_agent_schedule.arn
}

# ── 7. CloudWatch Alarm — Lambda errors ──────────────────────────────────────

resource "aws_cloudwatch_metric_alarm" "dr_agent_errors" {
  alarm_name          = "${local.env_prefix}-dr-agent-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = 3
  alarm_description   = "DR Agent Lambda is failing repeatedly — investigate immediately"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    FunctionName = aws_lambda_function.dr_agent.function_name
  }

  tags = var.global_tags
}
