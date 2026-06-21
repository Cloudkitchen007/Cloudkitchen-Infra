# =============================================================================
# BOOTSTRAP – Creates S3 bucket + DynamoDB table for Terraform remote state
#
# RUN THIS ONCE BEFORE the main project:
#   cd bootstrap/
#   terraform init
#   terraform apply -auto-approve
#
# Then copy the output "state_bucket_name" into ../backend.tf
# =============================================================================

terraform {
  required_version = ">= 1.0.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 4.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

data "aws_caller_identity" "current" {}

# ── S3 Bucket for Terraform state ──────────────────────────────────────────

resource "aws_s3_bucket" "tfstate" {
  bucket        = "cloudkitchen-tfstate-${data.aws_caller_identity.current.account_id}"
  force_destroy = true # temporarily enabled to allow teardown

  tags = {
    Name      = "cloudkitchen-terraform-state"
    Project   = "CloudKitchen"
    ManagedBy = "Terraform-Bootstrap"
  }
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Block all public access before adding any bucket policy
resource "aws_s3_bucket_lifecycle_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    id     = "expire-old-versions"
    status = "Enabled"

    noncurrent_version_expiration {
      noncurrent_days = 90
    }
  }
}

# ── DynamoDB table for state locking ───────────────────────────────────────

resource "aws_dynamodb_table" "tfstate_lock" {
  name         = "cloudkitchen-tfstate-lock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  tags = {
    Name      = "cloudkitchen-terraform-lock"
    Project   = "CloudKitchen"
    ManagedBy = "Terraform-Bootstrap"
  }
}
