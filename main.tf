# =============================================================================
# CLOUDKITCHEN – MAIN TERRAFORM  (COMPLETE, PRODUCTION-READY)
# =============================================================================
#
# Architecture:
#   Internet → External ALB → Web Tier (Nginx/React) + App Tier (Spring Boot)
#                Internal ALB → App Tier → RDS PostgreSQL
#
# Key fixes vs previous version:
#   • Removed frontend EC2 web tier, now using CloudFront + S3
#   • External ALB routes directly to App Tier
#   • deletion_protection=false + skip_final_snapshot=true (safe destroy)
#   • health_check_grace_period 900s on App ASG (Maven build takes time)
#   • Removed legacy EC2-DB variables
# =============================================================================

terraform {
  required_version = ">= 1.0.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

data "aws_caller_identity" "current" {}

locals {
  # Dynamically calculate the environment prefix based on the active Terraform workspace.
  # "default" workspace acts as Production and uses the raw project name.
  # e.g., "cloudkitchen" vs "cloudkitchen-dev"
  env_prefix = terraform.workspace == "default" ? var.project_name : "${var.project_name}-${terraform.workspace}"
}

# =============================================================================
# 1. VPC & NETWORKING
# =============================================================================

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = merge({ Name = local.env_prefix }, var.global_tags)
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags   = merge({ Name = "${local.env_prefix}-igw" }, var.global_tags)
}

resource "aws_subnet" "public" {
  for_each = {
    az1 = { cidr = var.public_subnet_cidrs[0], az = var.availability_zones[0] }
    az2 = { cidr = var.public_subnet_cidrs[1], az = var.availability_zones[1] }
  }
  vpc_id                  = aws_vpc.main.id
  cidr_block              = each.value.cidr
  availability_zone       = each.value.az
  map_public_ip_on_launch = true
  tags                    = merge({ Name = "${local.env_prefix}-public-${each.key}", Tier = "Public" }, var.global_tags)
}

resource "aws_subnet" "private_app" {
  for_each = {
    az1 = { cidr = var.private_app_subnet_cidrs[0], az = var.availability_zones[0] }
    az2 = { cidr = var.private_app_subnet_cidrs[1], az = var.availability_zones[1] }
  }
  vpc_id                  = aws_vpc.main.id
  cidr_block              = each.value.cidr
  availability_zone       = each.value.az
  map_public_ip_on_launch = false
  tags                    = merge({ Name = "${local.env_prefix}-app-${each.key}", Tier = "PrivateApp" }, var.global_tags)
}

resource "aws_subnet" "private_db" {
  for_each = {
    az1 = { cidr = var.private_db_subnet_cidrs[0], az = var.availability_zones[0] }
    az2 = { cidr = var.private_db_subnet_cidrs[1], az = var.availability_zones[1] }
  }
  vpc_id                  = aws_vpc.main.id
  cidr_block              = each.value.cidr
  availability_zone       = each.value.az
  map_public_ip_on_launch = false
  tags                    = merge({ Name = "${local.env_prefix}-db-${each.key}", Tier = "PrivateDB" }, var.global_tags)
}

resource "aws_eip" "nat" {
  for_each   = aws_subnet.public
  domain     = "vpc"
  tags       = merge({ Name = "${local.env_prefix}-nat-eip-${each.key}" }, var.global_tags)
  depends_on = [aws_internet_gateway.igw]
}

resource "aws_nat_gateway" "main" {
  for_each      = aws_subnet.public
  allocation_id = aws_eip.nat[each.key].id
  subnet_id     = each.value.id
  tags          = merge({ Name = "${local.env_prefix}-nat-${each.key}" }, var.global_tags)
  depends_on    = [aws_internet_gateway.igw]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = merge({ Name = "${local.env_prefix}-public-rt" }, var.global_tags)
}

resource "aws_route_table" "private" {
  for_each = aws_subnet.public
  vpc_id   = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main[each.key].id
  }
  tags = merge({ Name = "${local.env_prefix}-private-rt-${each.key}" }, var.global_tags)
}

resource "aws_route_table_association" "public" {
  for_each       = aws_subnet.public
  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private_app" {
  for_each       = aws_subnet.private_app
  subnet_id      = each.value.id
  route_table_id = aws_route_table.private[each.key].id
}

resource "aws_route_table_association" "private_db" {
  for_each       = aws_subnet.private_db
  subnet_id      = each.value.id
  route_table_id = aws_route_table.private[each.key].id
}

# =============================================================================
# 2. SECURITY GROUPS
# =============================================================================

# ── External ALB ─────────────────────────────
resource "aws_security_group" "ext_alb_sg" {
  name        = "${local.env_prefix}-ext-alb-sg"
  description = "External ALB"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP from internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS from internet"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge({ Name = "${local.env_prefix}-ext-alb-sg" }, var.global_tags)
}

# ── App Tier: Spring Boot EC2 instances ────────────────────────────────────
resource "aws_security_group" "app_sg" {
  name        = "${local.env_prefix}-app-sg"
  description = "App Tier - Spring Boot; receives from Ext ALB"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "Spring Boot from External ALB"
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.ext_alb_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge({ Name = "${local.env_prefix}-app-sg" }, var.global_tags)
}

# ── Database Tier: RDS PostgreSQL ──────────────────────────────────────────
# Inline ingress blocks are intentionally absent — all rules are managed as
# separate aws_security_group_rule resources (in this file and eks.tf) to
# prevent Terraform from silently dropping the EKS rule when it reconciles
# the SG. Mixing inline rules with separate rules on the same SG is a known
# Terraform footgun: inline rules win and overwrite external ones on every plan.
resource "aws_security_group" "db_sg" {
  name        = "${local.env_prefix}-db-sg"
  description = "DB Tier - PostgreSQL 5432 from App Tier only"
  vpc_id      = aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge({ Name = "${local.env_prefix}-db-sg" }, var.global_tags)
}

# Keep the app_sg → db rule as a separate resource so it co-exists safely
# with the EKS cluster SG rule defined in eks.tf (aws_security_group_rule.eks_to_db).
resource "aws_security_group_rule" "app_to_db" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.db_sg.id
  source_security_group_id = aws_security_group.app_sg.id
  description              = "PostgreSQL from App Tier"
}

# =============================================================================
# 3. DATABASE (RDS PostgreSQL)
# =============================================================================

resource "random_password" "db_password" {
  length  = 20
  special = false # avoid special chars that break JDBC URLs
}

resource "aws_db_subnet_group" "this" {
  name       = "${local.env_prefix}-db-subnet-group"
  subnet_ids = [for s in aws_subnet.private_db : s.id]
  tags       = merge({ Name = "${local.env_prefix}-db-subnet-group" }, var.global_tags)
}

resource "aws_db_instance" "this" {
  identifier        = "${local.env_prefix}-db"
  engine            = "postgres"
  engine_version    = "15"
  instance_class    = var.db_instance_class
  allocated_storage = 20
  storage_encrypted = true

  db_name  = var.db_name
  username = var.db_username
  password = random_password.db_password.result
  port     = 5432

  vpc_security_group_ids = [aws_security_group.db_sg.id]
  db_subnet_group_name   = aws_db_subnet_group.this.name
  multi_az               = false # set true for HA in production

  backup_retention_period = 7
  backup_window           = "03:00-04:00"
  maintenance_window      = "Mon:04:00-Mon:05:00"

  # FIX: Keep both false so terraform destroy completes without RDS state issues
  deletion_protection = false
  skip_final_snapshot = true

  # Performance Insights (free tier for db.t3.micro)
  performance_insights_enabled = false

  tags = merge({ Name = "${local.env_prefix}-rds" }, var.global_tags)
}

# =============================================================================
# 4. SECRETS MANAGER & SSM PARAMETER STORE
# =============================================================================

resource "aws_secretsmanager_secret" "db" {
  name                    = "${local.env_prefix}/db/credentials-new"
  description             = "RDS PostgreSQL credentials for CloudKitchen App Tier"
  recovery_window_in_days = 0 # allow immediate delete (useful for re-deployments)
  tags                    = var.global_tags
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({
    username = var.db_username
    password = random_password.db_password.result
    host     = aws_db_instance.this.address
    port     = 5432
    dbname   = var.db_name
  })
}

resource "aws_ssm_parameter" "cors_origins" {
  name  = "/${local.env_prefix}/app/cors_origins"
  type  = "String"
  value = var.cors_origins
  tags  = var.global_tags
}



# =============================================================================
# 8. S3 BUCKET (DB Backups)
# =============================================================================

resource "aws_s3_bucket" "backups" {
  bucket        = "${local.env_prefix}-db-backups-${data.aws_caller_identity.current.account_id}"
  force_destroy = true # allow destroy without emptying manually
  tags          = var.global_tags
}

resource "aws_s3_bucket_versioning" "backups" {
  bucket = aws_s3_bucket.backups.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "backups" {
  bucket                  = aws_s3_bucket.backups.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id

  rule {
    id     = "transition-and-expire"
    status = "Enabled"

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    expiration {
      days = 90
    }
  }
}

# =============================================================================
# 9. CLOUDWATCH LOG GROUP (App Tier)
# =============================================================================

resource "aws_cloudwatch_log_group" "app" {
  name              = "/cloudkitchen/app"
  retention_in_days = 30
  tags              = var.global_tags
}

