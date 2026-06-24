# =============================================================================
# CLOUDKITCHEN – ADD-ON COMPONENTS
# SNS, CloudWatch Alarms, Video Testimonials (Lambda/APIGW/S3), CloudFront, Config
# =============================================================================

# ── 1. SNS & CloudWatch Alarms ────────────────────────────────────────────

resource "aws_sns_topic" "alerts" {
  name = "${local.env_prefix}-alerts"
  tags = var.global_tags
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.admin_email
}

# NOTE: ALB 5xx alarm removed in the EKS-only migration (no ALB). Service
# health on EKS is observed via the kgateway/NLB target health + Prometheus.

# ── 2. Testimonials S3 Bucket ─────────────────────────────────────────────

resource "aws_s3_bucket" "testimonials" {
  bucket        = "${local.env_prefix}-testimonials-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
  tags          = var.global_tags
}

resource "aws_s3_bucket_public_access_block" "testimonials" {
  bucket                  = aws_s3_bucket.testimonials.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_cors_configuration" "testimonials" {
  bucket = aws_s3_bucket.testimonials.id

  cors_rule {
    allowed_headers = ["*"]
    allowed_methods = ["PUT", "POST"]
    allowed_origins = ["*"] # In production, restrict to CloudFront domain
    expose_headers  = ["ETag"]
    max_age_seconds = 3000
  }
}

# ── 3. Lambda Functions (Video Testimonials) ──────────────────────────────

# ZIP packaging for Lambda functions
data "archive_file" "presign_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda/presign.py"
  output_path = "${path.module}/lambda/presign.zip"
}

data "archive_file" "notification_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda/notification.py"
  output_path = "${path.module}/lambda/notification.zip"
}

# Lambda IAM Role
resource "aws_iam_role" "lambda_exec" {
  name = "${local.env_prefix}-lambda-exec-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
  tags = var.global_tags
}

# Lambda basic execution policy for CloudWatch Logs
resource "aws_iam_role_policy_attachment" "lambda_logs" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Custom policy for S3 and SNS access
resource "aws_iam_role_policy" "lambda_custom_policy" {
  name = "${local.env_prefix}-lambda-custom-policy"
  role = aws_iam_role.lambda_exec.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "${aws_s3_bucket.testimonials.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = aws_sns_topic.alerts.arn
      }
    ]
  })
}

# Presign Lambda Function
resource "aws_lambda_function" "presign" {
  function_name    = "${local.env_prefix}-presign-lambda"
  role             = aws_iam_role.lambda_exec.arn
  handler          = "presign.handler"
  runtime          = "python3.11"
  filename         = data.archive_file.presign_zip.output_path
  source_code_hash = data.archive_file.presign_zip.output_base64sha256

  environment {
    variables = {
      BUCKET_NAME = aws_s3_bucket.testimonials.bucket
    }
  }
  tags = var.global_tags
}

# Notification Lambda Function
resource "aws_lambda_function" "notification" {
  function_name    = "${local.env_prefix}-notification-lambda"
  role             = aws_iam_role.lambda_exec.arn
  handler          = "notification.handler"
  runtime          = "python3.11"
  filename         = data.archive_file.notification_zip.output_path
  source_code_hash = data.archive_file.notification_zip.output_base64sha256

  environment {
    variables = {
      TOPIC_ARN = aws_sns_topic.alerts.arn
    }
  }
  tags = var.global_tags
}

# S3 Event Notification to trigger Lambda
resource "aws_s3_bucket_notification" "bucket_notification" {
  bucket = aws_s3_bucket.testimonials.id
  lambda_function {
    lambda_function_arn = aws_lambda_function.notification.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "testimonials/"
    filter_suffix       = ".webm"
  }
  depends_on = [aws_lambda_permission.allow_s3]
}

resource "aws_lambda_permission" "allow_s3" {
  statement_id  = "AllowExecutionFromS3Bucket"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.notification.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.testimonials.arn
}

# ── 4. API Gateway (HTTP API for Presign Lambda) ──────────────────────────

resource "aws_apigatewayv2_api" "testimonials_api" {
  name          = "${local.env_prefix}-testimonials-api"
  protocol_type = "HTTP"
  cors_configuration {
    allow_origins = ["*"]
    allow_methods = ["POST", "OPTIONS"]
    allow_headers = ["*"]
    max_age       = 300
  }
  tags = var.global_tags
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.testimonials_api.id
  name        = "$default"
  auto_deploy = true
  tags        = var.global_tags
}

resource "aws_apigatewayv2_integration" "presign_lambda" {
  api_id                 = aws_apigatewayv2_api.testimonials_api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.presign.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "presign_route" {
  api_id    = aws_apigatewayv2_api.testimonials_api.id
  route_key = "POST /api/testimonials/presign"
  target    = "integrations/${aws_apigatewayv2_integration.presign_lambda.id}"
}

resource "aws_lambda_permission" "allow_apigw" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.presign.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.testimonials_api.execution_arn}/*/*"
}

# ── 5. CloudFront Distribution ────────────────────────────────────────────

# Frontend S3 Bucket
resource "aws_s3_bucket" "frontend" {
  bucket        = "${local.env_prefix}-frontend-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
  tags          = var.global_tags
}

resource "aws_s3_bucket_public_access_block" "frontend" {
  bucket                  = aws_s3_bucket.frontend.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# CloudFront Origin Access Control for S3
resource "aws_cloudfront_origin_access_control" "s3_oac" {
  name                              = "${local.env_prefix}-s3-oac"
  description                       = "OAC for S3 buckets"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# Origin Request Policy for API (Passes all viewer headers, cookies, and query strings)
resource "aws_cloudfront_origin_request_policy" "api_orp" {
  name    = "${local.env_prefix}-api-orp"
  comment = "Pass all viewer headers, cookies, and query strings to the API"

  cookies_config {
    cookie_behavior = "all"
  }
  headers_config {
    header_behavior = "allViewer"
  }
  query_strings_config {
    query_string_behavior = "all"
  }
}

resource "aws_cloudfront_distribution" "cdn" {
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "CloudKitchen Global CDN"
  price_class         = "PriceClass_100"
  default_root_object = "index.html"

  custom_error_response {
    error_code            = 403
    response_code         = 200
    error_caching_min_ttl = 10
    response_page_path    = "/index.html"
  }

  custom_error_response {
    error_code            = 404
    response_code         = 200
    error_caching_min_ttl = 10
    response_page_path    = "/index.html"
  }

  # Origin 1: EKS API (kgateway NLB) — only added once var.eks_api_origin is set
  # (the NLB is created by Kubernetes after the first apply, so the deploy does a
  # second apply with -var=eks_api_origin=<nlb-dns>). CloudFront terminates TLS
  # for the browser and talks HTTP to the NLB, so there is no mixed-content issue.
  dynamic "origin" {
    for_each = var.eks_api_origin != "" ? [1] : []
    content {
      domain_name = var.eks_api_origin
      origin_id   = "eks-api-origin"
      custom_origin_config {
        http_port              = 80
        https_port             = 443
        origin_protocol_policy = "http-only" # kgateway NLB listens on :80
        origin_ssl_protocols   = ["TLSv1.2"]
      }
    }
  }

  # Origin 2: Testimonials S3 Bucket
  origin {
    domain_name              = aws_s3_bucket.testimonials.bucket_regional_domain_name
    origin_id                = "s3-testimonials-origin"
    origin_access_control_id = aws_cloudfront_origin_access_control.s3_oac.id
  }

  # Origin 3: Frontend S3 Bucket
  origin {
    domain_name              = aws_s3_bucket.frontend.bucket_regional_domain_name
    origin_id                = "s3-frontend-origin"
    origin_access_control_id = aws_cloudfront_origin_access_control.s3_oac.id
  }

  # Default Cache Behavior: Route to Frontend S3 Bucket (Cache Optimized for React SPA)
  default_cache_behavior {
    target_origin_id       = "s3-frontend-origin"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]

    # Using AWS Managed Cache Policy: CachingOptimized
    cache_policy_id = "658327ea-f89d-4fab-a63d-7e88639e58f6"
  }

  # Ordered Behavior: /api/* and /auth/* -> EKS NLB (dynamic; cache disabled).
  # Created only when var.eks_api_origin is set (second apply).
  dynamic "ordered_cache_behavior" {
    for_each = var.eks_api_origin != "" ? ["/api/*", "/auth/*"] : []
    content {
      path_pattern             = ordered_cache_behavior.value
      target_origin_id         = "eks-api-origin"
      viewer_protocol_policy   = "redirect-to-https"
      allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
      cached_methods           = ["GET", "HEAD"]
      cache_policy_id          = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" # CachingDisabled
      origin_request_policy_id = aws_cloudfront_origin_request_policy.api_orp.id
    }
  }

  # Ordered Behavior 2: /testimonials/* -> Route to S3 Bucket (Cache Optimized)
  ordered_cache_behavior {
    path_pattern           = "/testimonials/*"
    target_origin_id       = "s3-testimonials-origin"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]

    cache_policy_id = "658327ea-f89d-4fab-a63d-7e88639e58f6" # CachingOptimized
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  web_acl_id = aws_wafv2_web_acl.cloudfront.arn

  tags = var.global_tags
}

# Allow CloudFront to read from the testimonials S3 bucket
resource "aws_s3_bucket_policy" "allow_cloudfront" {
  bucket = aws_s3_bucket.testimonials.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowCloudFrontServicePrincipal"
        Effect    = "Allow"
        Principal = { Service = "cloudfront.amazonaws.com" }
        Action    = "s3:GetObject"
        Resource  = "${aws_s3_bucket.testimonials.arn}/*"
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = aws_cloudfront_distribution.cdn.arn
          }
        }
      }
    ]
  })
}

# Allow CloudFront to read from the frontend S3 bucket
resource "aws_s3_bucket_policy" "allow_cloudfront_frontend" {
  bucket = aws_s3_bucket.frontend.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowCloudFrontServicePrincipal"
        Effect    = "Allow"
        Principal = { Service = "cloudfront.amazonaws.com" }
        Action    = "s3:GetObject"
        Resource  = "${aws_s3_bucket.frontend.arn}/*"
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = aws_cloudfront_distribution.cdn.arn
          }
        }
      }
    ]
  })
}

# ── 6. AWS Config (Compliance Monitoring) ─────────────────────────────────

resource "aws_s3_bucket" "config_logs" {
  count         = var.enable_aws_config ? 1 : 0
  bucket        = "${local.env_prefix}-config-logs-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
  tags          = var.global_tags
}

resource "aws_s3_bucket_public_access_block" "config_logs" {
  count                   = var.enable_aws_config ? 1 : 0
  bucket                  = aws_s3_bucket.config_logs[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_iam_role" "config_role" {
  count = var.enable_aws_config ? 1 : 0
  name  = "${local.env_prefix}-config-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "config.amazonaws.com"
        }
      }
    ]
  })
  tags = var.global_tags
}

resource "aws_iam_role_policy_attachment" "config_policy" {
  count      = var.enable_aws_config ? 1 : 0
  role       = aws_iam_role.config_role[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWS_ConfigRole"
}

resource "aws_iam_role_policy" "config_s3_policy" {
  count = var.enable_aws_config ? 1 : 0
  name  = "${local.env_prefix}-config-s3-policy"
  role  = aws_iam_role.config_role[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = ["s3:PutObject", "s3:GetBucketAcl"]
        Effect = "Allow"
        Resource = [
          aws_s3_bucket.config_logs[0].arn,
          "${aws_s3_bucket.config_logs[0].arn}/*"
        ]
      }
    ]
  })
}

resource "aws_config_configuration_recorder" "main" {
  count    = var.enable_aws_config ? 1 : 0
  name     = "${local.env_prefix}-config-recorder"
  role_arn = aws_iam_role.config_role[0].arn
  recording_group {
    all_supported                 = true
    include_global_resource_types = true
  }
}

resource "aws_config_delivery_channel" "main" {
  count          = var.enable_aws_config ? 1 : 0
  name           = "${local.env_prefix}-config-delivery-channel"
  s3_bucket_name = aws_s3_bucket.config_logs[0].bucket
  depends_on     = [aws_config_configuration_recorder.main]
}

resource "aws_config_configuration_recorder_status" "main" {
  count      = var.enable_aws_config ? 1 : 0
  name       = aws_config_configuration_recorder.main[0].name
  is_enabled = true
  depends_on = [aws_config_delivery_channel.main]
}

# ── 6. Frontend Deployment ───────────────────────────────────────────────────
# (EKS-only) The frontend build + S3 sync moved to cloudkitchen-app CI
# (.github/workflows/build.yml) — infra no longer builds app code from ../services.
# The S3 bucket + CloudFront distribution below remain; CI uploads the built SPA.

# AWS Config Managed Rule: S3 Bucket Public Read Prohibited
resource "aws_config_config_rule" "s3_public_read_prohibited" {
  count = var.enable_aws_config ? 1 : 0
  name  = "s3-bucket-public-read-prohibited"
  source {
    owner             = "AWS"
    source_identifier = "S3_BUCKET_PUBLIC_READ_PROHIBITED"
  }
  depends_on = [aws_config_configuration_recorder.main]
}

# AWS Config Managed Rule: Encrypted Volumes
resource "aws_config_config_rule" "encrypted_volumes" {
  count = var.enable_aws_config ? 1 : 0
  name  = "encrypted-volumes"
  source {
    owner             = "AWS"
    source_identifier = "ENCRYPTED_VOLUMES"
  }
  depends_on = [aws_config_configuration_recorder.main]
}
