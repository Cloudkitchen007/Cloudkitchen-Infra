# =============================================================================
# CLOUDKITCHEN – VARIABLES
# =============================================================================

variable "aws_region" {
  description = "AWS region to deploy resources"
  type        = string
  default     = "ap-south-1"
}

variable "project_name" {
  description = "Project name used as a prefix for all resources"
  type        = string
  default     = "cloudkitchen"
}

variable "environment" {
  description = "Deployment environment (production, staging, dev)"
  type        = string
  default     = "production"
}

# =============================================================================
# NETWORKING
# =============================================================================

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "List of Availability Zones to deploy into"
  type        = list(string)
  default     = ["ap-south-1a", "ap-south-1b"]
}

variable "public_subnet_cidrs" {
  description = "CIDRs for public subnets (Web Tier + NAT Gateways)"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_app_subnet_cidrs" {
  description = "CIDRs for private App Tier subnets"
  type        = list(string)
  default     = ["10.0.3.0/24", "10.0.4.0/24"]
}

variable "private_db_subnet_cidrs" {
  description = "CIDRs for private DB Tier subnets"
  type        = list(string)
  default     = ["10.0.5.0/24", "10.0.6.0/24"]
}

# =============================================================================
# GLOBAL TAGS
# =============================================================================

variable "global_tags" {
  description = "Tags applied to every resource"
  type        = map(string)
  default = {
    Project   = "CloudKitchen"
    ManagedBy = "Terraform-Pruthvi"
  }
}

# =============================================================================
# COMPUTE
# =============================================================================

variable "web_ami_id" {
  description = "AMI ID for Web Tier EC2 instances (Ubuntu 22.04 recommended)"
  type        = string
}

variable "app_ami_id" {
  description = "AMI ID for App Tier EC2 instances (Ubuntu 22.04 recommended)"
  type        = string
}

variable "web_instance_type" {
  description = "EC2 instance type for the Web Tier"
  type        = string
  default     = "t3.small"
}

variable "app_instance_type" {
  description = "EC2 instance type for the App Tier (needs memory for JVM)"
  type        = string
  default     = "t3.small"
}

variable "key_name" {
  description = "Name of the EC2 key pair for SSH access"
  type        = string
  default     = "ustproject-mb"
}

# =============================================================================
# DATABASE (RDS PostgreSQL)
# =============================================================================

variable "db_name" {
  description = "Name of the PostgreSQL database"
  type        = string
  default     = "cloudkitchen"
}

variable "db_username" {
  description = "Master username for RDS PostgreSQL"
  type        = string
  default     = "postgres"
}

variable "db_instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t3.micro"
}

# =============================================================================
# APPLICATION
# =============================================================================

variable "github_repo" {
  description = "GitHub repository URL (public) for application code"
  type        = string
  default     = "https://github.com/PruthviBhat-UST/cloudkitchen-aws.git"
}

variable "cors_origins" {
  description = "Allowed CORS origins for the Spring Boot backend"
  type        = string
  default     = "*"
}

# =============================================================================
# NOTIFICATIONS & MONITORING
# =============================================================================

variable "admin_email" {
  description = "Email address for SNS alarm notifications"
  type        = string
}

# =============================================================================
# AI SERVICE
# =============================================================================

variable "hf_api_token" {
  description = "HuggingFace Inference API token — free at huggingface.co/settings/tokens"
  type        = string
  sensitive   = true
}

# =============================================================================
# OPTIONAL FEATURES
# =============================================================================

variable "domain_name" {
  description = "Custom domain name (optional, for future CloudFront/ACM)"
  type        = string
  default     = ""
}

variable "enable_aws_config" {
  description = "Enable AWS Config compliance monitoring"
  type        = bool
  default     = false
}