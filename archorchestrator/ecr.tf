# ECR Image Replication
# Creates a local ECR repository and replicates images from the source account
# Follows the secrets module pattern: read from source account, create local copies

# ── Local ECR Repository ────────────────────────────────────────────────────
# Single repo per namespace, images differentiated by tag (matches source pattern)

resource "aws_ecr_repository" "main" {
  name                 = "${var.namespace}-io"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = false
  }

  tags = {
    Name      = "${var.namespace}-io"
    Namespace = var.namespace
    ManagedBy = "platformer-archorchestrator"
  }
}

# ── Image Replication via Docker ────────────────────────────────────────────
# Pull from source ECR, tag for local ECR, push to local ECR
# Triggers on image tag changes (new deployment = new image version)

resource "null_resource" "ecr_replicate" {
  for_each = local.ecs_services

  triggers = {
    image_tag     = each.value.image_tag
    source_repo   = each.value.ecr_source_repo
    source_acct   = each.value.ecr_source_account_id
    source_rgn    = each.value.ecr_source_region
    source_prof   = each.value.ecr_source_profile
    dest_repo     = aws_ecr_repository.main.repository_url
    dest_registry = "${var.aws_account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
    dest_rgn      = var.aws_region
    dest_profile  = var.aws_profile
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -e

      SOURCE_URI="${self.triggers.source_acct}.dkr.ecr.${self.triggers.source_rgn}.amazonaws.com/${self.triggers.source_repo}:${self.triggers.image_tag}"
      DEST_URI="${self.triggers.dest_repo}:${self.triggers.image_tag}"

      echo "Replicating image: $SOURCE_URI -> $DEST_URI"

      # Authenticate to source ECR
      AWS_PROFILE=${self.triggers.source_prof} aws ecr get-login-password --region ${self.triggers.source_rgn} \
        | docker login --username AWS --password-stdin ${self.triggers.source_acct}.dkr.ecr.${self.triggers.source_rgn}.amazonaws.com

      # Authenticate to destination ECR
      AWS_PROFILE=${self.triggers.dest_profile} aws ecr get-login-password --region ${self.triggers.dest_rgn} \
        | docker login --username AWS --password-stdin ${self.triggers.dest_registry}

      # Pull, tag, push
      docker pull "$SOURCE_URI"
      docker tag "$SOURCE_URI" "$DEST_URI"
      docker push "$DEST_URI"

      # Clean up local images
      docker rmi "$SOURCE_URI" "$DEST_URI" 2>/dev/null || true

      echo "Successfully replicated: ${self.triggers.image_tag}"
    EOT
  }

  depends_on = [aws_ecr_repository.main]
}
