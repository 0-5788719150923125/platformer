# Tenant Management - Direct Database Approach
# No Lambda, no Gradle, no Java chaos
# Just direct DynamoDB and SQL Server operations via bash scripts

locals {
  # Flatten tenants by deployment for tenant creation
  tenants_to_create = flatten([
    for deploy_name, tenants in var.tenants_by_deployment : [
      for tenant in tenants : {
        deployment  = deploy_name
        tenant      = tenant
        tenant_id   = uuidv5("dns", "${var.namespace}.${deploy_name}.${tenant}")
        tenant_name = title(tenant)
      }
    ]
  ])
}

# ── DynamoDB Table (Tenant Metadata) ───────────────────────────────────────
resource "aws_dynamodb_table" "tenants" {
  for_each = var.config

  name         = "${var.namespace}-${each.key}-tenants"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "tenantId"

  attribute {
    name = "tenantId"
    type = "S"
  }

  tags = {
    Namespace  = var.namespace
    Deployment = each.key
    ManagedBy  = "platformer-archorchestrator"
  }
}

# ── Direct Tenant Creation ────────────────────────────────────────────────
# Create tenant records directly in DynamoDB and SQL Server
# No Lambda, no Step Functions - just direct database operations

resource "null_resource" "create_tenants" {
  for_each = { for t in local.tenants_to_create : "${t.deployment}-${t.tenant}" => t }

  triggers = {
    tenant_id      = each.value.tenant_id
    tenant_code    = each.value.tenant
    tenant_name    = each.value.tenant_name
    deployment     = each.value.deployment
    aws_profile    = var.aws_profile
    aws_region     = var.aws_region
    dynamodb_table = aws_dynamodb_table.tenants[each.value.deployment].name
    rds_endpoint   = try(var.rds_instances["${each.value.deployment}-mssql"].endpoint, "")
    image_version  = try(var.config[each.value.deployment].ecs.clario.image, "unknown")
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -e

      TENANT_ID="${self.triggers.tenant_id}"
      TENANT_CODE="${self.triggers.tenant_code}"
      TENANT_NAME="${self.triggers.tenant_name}"
      DEPLOYMENT="${self.triggers.deployment}"
      DYNAMODB_TABLE="${self.triggers.dynamodb_table}"
      IMAGE_VERSION="${self.triggers.image_version}"
      RDS_ENDPOINT="${self.triggers.rds_endpoint}"

      echo "Creating tenant: $TENANT_CODE (ID: $TENANT_ID) in deployment: $DEPLOYMENT"

      # Create DynamoDB record
      echo "Creating DynamoDB record..."
      AWS_PROFILE=${self.triggers.aws_profile} AWS_REGION=${self.triggers.aws_region} \
        aws dynamodb put-item \
          --table-name "$DYNAMODB_TABLE" \
          --item "{
            \"tenantId\": {\"S\": \"$TENANT_ID\"},
            \"tenantCode\": {\"S\": \"$TENANT_CODE\"},
            \"tenantName\": {\"S\": \"$TENANT_NAME\"},
            \"state\": {\"S\": \"active\"},
            \"version\": {\"S\": \"$IMAGE_VERSION\"},
            \"createdAt\": {\"S\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}
          }"

      echo "✓ DynamoDB record created for tenant: $TENANT_CODE"

      # TODO: SQL Server tenant initialization
      # Requires database credentials and schema knowledge
      # For now, DynamoDB + S3 tenant mapping may be sufficient for POC
      if [ -n "$RDS_ENDPOINT" ]; then
        echo "⚠ SQL Server initialization not yet implemented"
        echo "  RDS endpoint: $RDS_ENDPOINT"
        echo "  Tenant database records need to be created manually or via SQL scripts"
      fi

      echo "✓ Tenant $TENANT_CODE created successfully"
    EOT
  }

  depends_on = [
    aws_dynamodb_table.tenants
  ]
}
