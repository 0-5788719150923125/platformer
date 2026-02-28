# ClaireVoyance Medical AI Platform
# Nested module sourcing from hackathon-8 repository
# Provides SageMaker-based inference endpoints for medical imaging AI models

# NOTE: HuggingFace secret ("huggingface") must be created manually in AWS Secrets Manager
# This is necessary because hackathon-8 has a data source that looks up the secret
# during plan phase (before Terraform creates any resources). Manual creation is required
# to break the chicken-and-egg dependency. See README for creation instructions.

# Source the hackathon-8 infrastructure
# Using local path (relative to infra-terraform root) with provider blocks removed for count/for_each support
# module "upstream" {
#   source = "git::https://github.com/acme-sandbox/hackathon-8.git?ref=improve-compat"
#
#   namespace      = var.namespace
#   aws_region     = var.aws_region
#   aws_profile    = var.aws_profile
#   aws_account_id = var.aws_account_id
#
#   available_models       = ["medgemma", "chexagent", "medsam2", "classifier"]
#   studio_instance_type   = var.config.studio_instance_type
#   notebook_instance_type = var.config.notebook_instance_type
#   notebook_volume_size   = var.config.notebook_volume_size
#   inference_instance_type = var.config.inference_instance_type
#   inference_models        = var.config.inference_models
#   ecr_repositories        = var.config.ecr_repositories
#   domain_name             = var.config.domain_name
#   route53_zone_name       = var.config.route53_zone_name
# }
