# Backend Configuration
#
# Local Development:
#   No backend block = local backend (default)
#   State stored as terraform.tfstate in working directory
#   Just run: terraform init
#
# CI/CD Pipeline:
#   S3 backend initialized via -backend-config flag
#   Backend config generated dynamically by GitHub Actions workflow
#   State path: s3://example-tfstate-bucket/pt-terraform/platformer/<account_id>/<region>.tfstate
#
# Example CI/CD usage:
#   terraform init -backend-config=backend-config.hcl
#
#   Where backend-config.hcl contains:
#     bucket         = "example-tfstate-bucket"
#     region         = "us-east-2"
#     key            = "pt-terraform/platformer/<account_id>/<region>.tfstate"
#     encrypt        = true
#     dynamodb_table = "TFState"
#     assume_role    = { role_arn = "arn:aws:iam::222222222222:role/sre-inf_cross_account" }
#
# Note: No backend block needed here - Terraform allows backend initialization
#       via -backend-config even when no backend is defined in code.
