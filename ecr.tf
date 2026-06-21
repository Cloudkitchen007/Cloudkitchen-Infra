# =============================================================================
# ECR (Elastic Container Registry) INFRASTRUCTURE
# =============================================================================

# Backend Repository
resource "aws_ecr_repository" "app_repo" {
  name                 = "${local.env_prefix}-app-repo"
  image_tag_mutability = "MUTABLE"
  force_delete         = true # allow `terraform destroy` to delete the repo even when it holds images

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = merge({ Name = "${local.env_prefix}-app-repo" }, var.global_tags)
}

# AI Recommender Repository
resource "aws_ecr_repository" "ai_repo" {
  name                 = "${local.env_prefix}-ai-repo"
  image_tag_mutability = "MUTABLE"
  force_delete         = true # allow `terraform destroy` to delete the repo even when it holds images

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = merge({ Name = "${local.env_prefix}-ai-repo" }, var.global_tags)
}

# Auth Service Repository
resource "aws_ecr_repository" "auth_repo" {
  name                 = "${local.env_prefix}-auth-repo"
  image_tag_mutability = "MUTABLE"
  force_delete         = true # allow `terraform destroy` to delete the repo even when it holds images

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = merge({ Name = "${local.env_prefix}-auth-repo" }, var.global_tags)
}

resource "aws_ecr_lifecycle_policy" "auth_repo_policy" {
  repository = aws_ecr_repository.auth_repo.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 5 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 5
      }
      action = {
        type = "expire"
      }
    }]
  })
}

# Lifecycle Policy: Keep only the 5 most recent images to save costs
resource "aws_ecr_lifecycle_policy" "app_repo_policy" {
  repository = aws_ecr_repository.app_repo.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 5 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 5
      }
      action = {
        type = "expire"
      }
    }]
  })
}

resource "aws_ecr_lifecycle_policy" "ai_repo_policy" {
  repository = aws_ecr_repository.ai_repo.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 5 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 5
      }
      action = {
        type = "expire"
      }
    }]
  })
}

# Menu Service Repository
resource "aws_ecr_repository" "menu_repo" {
  name                 = "${local.env_prefix}-menu-repo"
  image_tag_mutability = "MUTABLE"
  force_delete         = true # allow `terraform destroy` to delete the repo even when it holds images

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = merge({ Name = "${local.env_prefix}-menu-repo" }, var.global_tags)
}

resource "aws_ecr_lifecycle_policy" "menu_repo_policy" {
  repository = aws_ecr_repository.menu_repo.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 5 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 5
      }
      action = {
        type = "expire"
      }
    }]
  })
}

# Order Service Repository
resource "aws_ecr_repository" "order_repo" {
  name                 = "${local.env_prefix}-order-repo"
  image_tag_mutability = "MUTABLE"
  force_delete         = true # allow `terraform destroy` to delete the repo even when it holds images

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = merge({ Name = "${local.env_prefix}-order-repo" }, var.global_tags)
}

resource "aws_ecr_lifecycle_policy" "order_repo_policy" {
  repository = aws_ecr_repository.order_repo.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 5 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 5
      }
      action = {
        type = "expire"
      }
    }]
  })
}
