# =============================================================================
# AUTH SERVICE INFRASTRUCTURE
# AWS Cognito User Pools + FastAPI Auth Microservice
#
# Microservice routing (ALB priority order):
#   40 → /auth/*              Auth Service  (port 8001)  [this file]
#   50 → /api/recommend*      AI Service    (port 8000)  [ai-infrastructure.tf]
#   default → /*              App Service   (port 8080)  [main.tf]
# =============================================================================

# (EKS-only) Auth service code is built into a container image by cloudkitchen-app
# CI and pulled from ECR — no source zip built here. This file now only manages
# the Cognito user pools.

# ---------------------------------------------------------------------------
# 2. COGNITO – Customer User Pool
# ---------------------------------------------------------------------------

resource "aws_cognito_user_pool" "users" {
  name = "${local.env_prefix}-users"

  password_policy {
    minimum_length    = 8
    require_uppercase = true
    require_lowercase = true
    require_numbers   = true
    require_symbols   = false
  }

  auto_verified_attributes = ["email"]

  schema {
    name                = "email"
    attribute_data_type = "String"
    required            = true
    mutable             = true
    string_attribute_constraints {
      min_length = 5
      max_length = 100
    }
  }

  schema {
    name                = "name"
    attribute_data_type = "String"
    required            = true
    mutable             = true
    string_attribute_constraints {
      min_length = 1
      max_length = 100
    }
  }

  tags = merge({ Name = "${local.env_prefix}-users-pool" }, var.global_tags)
}

resource "aws_cognito_user_pool_client" "users" {
  name         = "${local.env_prefix}-users-client"
  user_pool_id = aws_cognito_user_pool.users.id

  explicit_auth_flows = [
    "ALLOW_USER_PASSWORD_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
  ]

  generate_secret = false
}

# ---------------------------------------------------------------------------
# 3. COGNITO – Restaurant User Pool
# ---------------------------------------------------------------------------

resource "aws_cognito_user_pool" "restaurants" {
  name = "${local.env_prefix}-restaurants"

  password_policy {
    minimum_length    = 8
    require_uppercase = true
    require_lowercase = true
    require_numbers   = true
    require_symbols   = false
  }

  auto_verified_attributes = ["email"]

  schema {
    name                = "email"
    attribute_data_type = "String"
    required            = true
    mutable             = true
    string_attribute_constraints {
      min_length = 5
      max_length = 100
    }
  }

  schema {
    name                = "name"
    attribute_data_type = "String"
    required            = true
    mutable             = true
    string_attribute_constraints {
      min_length = 1
      max_length = 100
    }
  }

  schema {
    name                     = "restaurant_name"
    attribute_data_type      = "String"
    required                 = false
    mutable                  = true
    developer_only_attribute = false
    string_attribute_constraints {
      min_length = 1
      max_length = 100
    }
  }

  tags = merge({ Name = "${local.env_prefix}-restaurants-pool" }, var.global_tags)
}

resource "aws_cognito_user_pool_client" "restaurants" {
  name         = "${local.env_prefix}-restaurants-client"
  user_pool_id = aws_cognito_user_pool.restaurants.id

  explicit_auth_flows = [
    "ALLOW_USER_PASSWORD_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
  ]

  generate_secret = false
}

# ---------------------------------------------------------------------------
# 4. SSM PARAMETERS – Cognito IDs (reachable by any service via IAM)
# ---------------------------------------------------------------------------

resource "aws_ssm_parameter" "user_pool_id" {
  name  = "/${local.env_prefix}/cognito/user_pool_id"
  type  = "String"
  value = aws_cognito_user_pool.users.id
  tags  = var.global_tags
}

resource "aws_ssm_parameter" "user_client_id" {
  name  = "/${local.env_prefix}/cognito/user_client_id"
  type  = "String"
  value = aws_cognito_user_pool_client.users.id
  tags  = var.global_tags
}

resource "aws_ssm_parameter" "restaurant_pool_id" {
  name  = "/${local.env_prefix}/cognito/restaurant_pool_id"
  type  = "String"
  value = aws_cognito_user_pool.restaurants.id
  tags  = var.global_tags
}

resource "aws_ssm_parameter" "restaurant_client_id" {
  name  = "/${local.env_prefix}/cognito/restaurant_client_id"
  type  = "String"
  value = aws_cognito_user_pool_client.restaurants.id
  tags  = var.global_tags
}

