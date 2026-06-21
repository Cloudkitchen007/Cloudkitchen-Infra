# =============================================================================
# CLOUDKITCHEN – TERRAFORM OUTPUTS
# =============================================================================

# ── Networking ────────────────────────────────────────────────────────────

output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "Public subnet IDs (Web Tier)"
  value       = [for s in aws_subnet.public : s.id]
}

output "private_app_subnet_ids" {
  description = "Private App Tier subnet IDs"
  value       = [for s in aws_subnet.private_app : s.id]
}

output "private_db_subnet_ids" {
  description = "Private DB Tier subnet IDs"
  value       = [for s in aws_subnet.private_db : s.id]
}

# ── Load Balancers ────────────────────────────────────────────────────────

output "external_alb_dns" {
  description = "Public URL of the External ALB – API Entrypoint"
  value       = "http://EKS-NLB-DNS"
}

# ── Database ──────────────────────────────────────────────────────────────

output "rds_endpoint" {
  description = "RDS PostgreSQL endpoint (private – accessible from App Tier only)"
  value       = aws_db_instance.this.address
}

output "rds_port" {
  description = "RDS PostgreSQL port"
  value       = aws_db_instance.this.port
}

output "rds_db_name" {
  description = "Database name"
  value       = aws_db_instance.this.db_name
}

# ── Secrets ───────────────────────────────────────────────────────────────

output "db_secret_arn" {
  description = "ARN of the Secrets Manager secret holding DB credentials"
  value       = aws_secretsmanager_secret.db.arn
}

output "db_secret_name" {
  description = "Name of the Secrets Manager secret"
  value       = aws_secretsmanager_secret.db.name
}

# ── Security Groups ───────────────────────────────────────────────────────

output "ext_alb_sg_id" {
  description = "External ALB security group ID"
  value       = aws_security_group.ext_alb_sg.id
}

output "app_sg_id" {
  description = "App Tier security group ID"
  value       = aws_security_group.app_sg.id
}

output "db_sg_id" {
  description = "DB Tier security group ID"
  value       = aws_security_group.db_sg.id
}

# ── S3 ────────────────────────────────────────────────────────────────────

output "backup_bucket_name" {
  description = "S3 bucket name for DB backups"
  value       = aws_s3_bucket.backups.bucket
}

# ── Quick Reference ───────────────────────────────────────────────────────

output "quick_reference" {
  description = "Copy-paste commands for common admin tasks"
  value       = <<-EOT

    ═══════════════════════════════════════════════════════
    CLOUDKITCHEN – QUICK REFERENCE
    ═══════════════════════════════════════════════════════

    🌐 Application URL (CloudFront):
       https://${aws_cloudfront_distribution.cdn.domain_name}

    🔗 API Base URL:
       https://${aws_cloudfront_distribution.cdn.domain_name}/api

    📋 App Tier logs (on App instance via SSM):
       sudo journalctl -u cloudkitchen -f
       sudo tail -f /var/log/cloudkitchen/app.log

    🗄️  Connect to RDS (from App instance):
       PGPASSWORD=$(aws secretsmanager get-secret-value \
         --secret-id ${aws_secretsmanager_secret.db.name} \
         --query SecretString --output text | jq -r .password) \
       psql -h ${aws_db_instance.this.address} -U postgres -d cloudkitchen

    🔍 Test App Tier health (via ALB):
       curl http://EKS-NLB-DNS/api/categories

    ═══════════════════════════════════════════════════════
  EOT
}

output "cloudfront_url" {
  description = "CloudFront Global CDN URL"
  value       = aws_cloudfront_distribution.cdn.domain_name
}

output "api_gateway_url" {
  description = "API Gateway URL for Video Testimonials Presign"
  value       = aws_apigatewayv2_stage.default.invoke_url
}

# ── Auth / Cognito ────────────────────────────────────────────────────────

output "cognito_user_pool_id" {
  description = "Cognito User Pool ID (customers)"
  value       = aws_cognito_user_pool.users.id
}

output "cognito_restaurant_pool_id" {
  description = "Cognito User Pool ID (restaurants)"
  value       = aws_cognito_user_pool.restaurants.id
}

output "auth_service_endpoints" {
  description = "Auth microservice API endpoints (via ALB)"
  value       = <<-EOT
    POST /auth/user/register       – register a new customer
    POST /auth/user/login          – customer login → JWT tokens
    POST /auth/restaurant/register – register a new restaurant
    POST /auth/restaurant/login    – restaurant login → JWT tokens
    GET  /auth/health              – health check
  EOT
}

# ── Menu Service ──────────────────────────────────────────────────────────

output "menu_service_endpoints" {
  description = "Menu microservice API endpoints (via ALB)"
  value       = <<-EOT
    GET  /api/categories           – list all categories
    GET  /api/menu                 – list all menu items
    GET  /api/menu/{id}            – get menu item by ID
    GET  /api/menu/category/{id}   – items by category
    GET  /api/menu/search?q=       – keyword search
  EOT
}

# ── Order Service ─────────────────────────────────────────────────────────

output "order_service_endpoints" {
  description = "Order microservice API endpoints (via ALB)"
  value       = <<-EOT
    POST  /api/orders              – place a new order
    GET   /api/orders/{id}         – get order by ID
    GET   /api/orders/track?email= – track orders by email
    GET   /api/orders              – list all orders
    PATCH /api/orders/{id}/status  – update order status
  EOT
}

# ── EKS ───────────────────────────────────────────────────────────────────

output "eks_cluster_name" {
  description = "EKS cluster name"
  value       = aws_eks_cluster.cloudkitchen.name
}

output "eks_cluster_endpoint" {
  description = "EKS API server endpoint"
  value       = aws_eks_cluster.cloudkitchen.endpoint
}

output "eks_kubeconfig_command" {
  description = "Run this after apply to configure kubectl"
  value       = "aws eks update-kubeconfig --name ${aws_eks_cluster.cloudkitchen.name} --region ${var.aws_region}"
}

output "ecr_push_commands" {
  description = "Commands to authenticate Docker to ECR and push images"
  value       = <<-EOT
    # 1. Authenticate Docker to ECR
    aws ecr get-login-password --region ${var.aws_region} | \
      docker login --username AWS --password-stdin \
      ${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com

    # 2. Build and push each service (run from repo root)
    # menu-service
    docker build -t ${aws_ecr_repository.menu_repo.repository_url}:latest ./terraform-trouble/services/menu-service
    docker push ${aws_ecr_repository.menu_repo.repository_url}:latest

    # order-service
    docker build -t ${aws_ecr_repository.order_repo.repository_url}:latest ./terraform-trouble/services/order-service
    docker push ${aws_ecr_repository.order_repo.repository_url}:latest

    # auth-service
    docker build -t ${aws_ecr_repository.auth_repo.repository_url}:latest ./terraform-trouble/services/auth-service
    docker push ${aws_ecr_repository.auth_repo.repository_url}:latest

    # ai-recommender
    docker build -t ${aws_ecr_repository.ai_repo.repository_url}:latest ./terraform-trouble/services/ai-recommender
    docker push ${aws_ecr_repository.ai_repo.repository_url}:latest
  EOT
}

# ── DR Agent ──────────────────────────────────────────────────────────────

output "dr_agent_function_name" {
  description = "Lambda function name of the DR Agent"
  value       = aws_lambda_function.dr_agent.function_name
}

output "dr_agent_log_group" {
  description = "CloudWatch log group for DR Agent runs"
  value       = "/aws/lambda/${aws_lambda_function.dr_agent.function_name}"
}

output "dr_agent_schedule" {
  description = "EventBridge schedule — daily at 02:00 UTC"
  value       = aws_cloudwatch_event_rule.dr_agent_schedule.schedule_expression
}

# ── SQS Queues ────────────────────────────────────────────────────────────

output "sqs_orders_queue_url" {
  description = "URL of the orders SQS queue (order-service publishes here)"
  value       = aws_sqs_queue.orders_queue.url
}

output "sqs_orders_queue_arn" {
  description = "ARN of the orders SQS queue"
  value       = aws_sqs_queue.orders_queue.arn
}

output "sqs_orders_dlq_url" {
  description = "URL of the orders Dead Letter Queue"
  value       = aws_sqs_queue.orders_dlq.url
}

# ── ECR Repositories ──────────────────────────────────────────────────────

output "ecr_repository_urls" {
  description = "ECR repository URLs for all services"
  value = {
    menu  = aws_ecr_repository.menu_repo.repository_url
    order = aws_ecr_repository.order_repo.repository_url
    auth  = aws_ecr_repository.auth_repo.repository_url
    ai    = aws_ecr_repository.ai_repo.repository_url
    app   = aws_ecr_repository.app_repo.repository_url
  }
}

# ── Microservices Summary ─────────────────────────────────────────────────

output "microservices_routing" {
  description = "ALB path-based routing across all microservices"
  value       = <<-EOT

    ═══════════════════════════════════════════════════════════════════
    CLOUDKITCHEN MICROSERVICES – ALB ROUTING TABLE
    ═══════════════════════════════════════════════════════════════════

    Priority  Path Pattern            Service          Port  Tech
    ────────  ──────────────────────  ───────────────  ────  ──────────────────────
    20        /api/orders             Order Service    8082  Spring Boot 3.2 + RDS
              /api/orders/*
    40        /auth/*                 Auth Service     8001  Spring Boot 3.2 + Cognito
    50        /api/recommend*         AI Service       8000  FastAPI + FLAN-T5
              /api/update_user_*
    Default   /*                      Menu Service     8080  Spring Boot 3.2 + Flyway
    CDN       /testimonials/*         S3 + Lambda      –     Presigned URL upload

    ── Database Ownership ─────────────────────────────────────────────
    menu-service   Flyway ENABLED  – creates and migrates all 4 tables
    order-service  Flyway DISABLED – reads shared DB (menu_items for price lookup)

    ═══════════════════════════════════════════════════════════════════
    API Base: http://EKS-NLB-DNS
    CDN:      https://${aws_cloudfront_distribution.cdn.domain_name}
    ═══════════════════════════════════════════════════════════════════
  EOT
}