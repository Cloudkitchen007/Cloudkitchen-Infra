# =============================================================================
# CLOUDKITCHEN – S3 REMOTE BACKEND CONFIGURATION
# =============================================================================
#
# CURRENT STATE: Backend block is commented out → uses LOCAL state.
#
# TO ENABLE S3 REMOTE STATE (recommended for teams / production):
# ─────────────────────────────────────────────────────────────────
# Step 1 – Create the S3 bucket + DynamoDB lock table (one time only):
#
#   cd bootstrap/
#   terraform init
#   terraform apply -auto-approve
#   terraform output state_bucket_name   # e.g., cloudkitchen-tfstate-123456789012
#   cd ..
#
# Step 2 – Fill in the bucket name below and uncomment the backend block:
#
#   Replace "cloudkitchen-tfstate-ACCOUNT_ID" with the output from Step 1.
#
# Step 3 – Migrate local state to S3:
#
#   terraform init -migrate-state
#   # Answer "yes" when prompted
#
# ─────────────────────────────────────────────────────────────────
# NOTE: Backend blocks do NOT support Terraform variables or expressions.
#       The bucket name must be a literal string.
# =============================================================================

# Uncomment the block below after completing the steps above:

terraform {
  backend "s3" {
    bucket         = "cloudkitchen-tfstate-256603361470"
    key            = "cloudkitchen/terraform.tfstate"
    region         = "ap-south-1"
    dynamodb_table = "cloudkitchen-tfstate-lock" # state locking (table created by bootstrap/)
    encrypt        = true
  }
}
