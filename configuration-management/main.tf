# Local variables for document discovery and configuration
locals {
  # Discover all YAML files in documents/ directory
  document_files = fileset("${path.module}/documents", "*.yaml")

  # Create map of documents with their metadata
  documents = {
    for file in local.document_files :
    replace(file, ".yaml", "") => {
      file_path       = "${path.module}/documents/${file}"
      document_name   = replace(file, ".yaml", "")
      formatted_name  = join("-", [for word in split("-", replace(file, ".yaml", "")) : title(word)])
      iam_policy_file = "${path.module}/documents/${replace(file, ".yaml", ".iam.json")}"
      has_iam_policy  = fileexists("${path.module}/documents/${replace(file, ".yaml", ".iam.json")}")
      enabled         = can(var.config.documents[replace(file, ".yaml", "")].enabled) ? var.config.documents[replace(file, ".yaml", "")].enabled : false
    }
  }

  # Filter to only enabled documents
  enabled_documents = {
    for name, doc in local.documents : name => doc
    if doc.enabled
  }

  # Pre-compute which document keys exist in the config map
  # Note: Key existence doesn't guarantee all properties are set (properties may be null)
  # This avoids repeated key lookups and makes the intent clear
  doc_key_exists = {
    for name in keys(local.enabled_documents) : name =>
    contains(keys(var.config.documents), name)
  }

  # Document-specific association configs with defaults
  # Strategy: If doc key exists, try its properties; coalesce handles nulls by falling back to global defaults
  association_configs = {
    for name, doc in local.enabled_documents : name => {
      # For each field: coalesce doc-specific override (if key exists and property not null) with global default
      schedule_expression = coalesce(
        local.doc_key_exists[name] ? var.config.documents[name].schedule_expression : null,
        var.config.schedule_expression
      )
      max_concurrency = coalesce(
        local.doc_key_exists[name] ? var.config.documents[name].max_concurrency : null,
        var.config.max_concurrency
      )
      max_errors = coalesce(
        local.doc_key_exists[name] ? var.config.documents[name].max_errors : null,
        var.config.max_errors
      )
      compliance_severity = coalesce(
        local.doc_key_exists[name] ? var.config.documents[name].compliance_severity : null,
        var.config.compliance_severity
      )
      parameters = coalesce(
        local.doc_key_exists[name] ? var.config.documents[name].parameters : null,
        { ParameterStorePrefix = var.config.parameter_store_prefix }
      )

      # Targeting: explicit override or smart default
      targets = local.doc_key_exists[name] && var.config.documents[name].targets != null ? (
        # Explicit targets specified - use them
        var.config.documents[name].targets
        ) : (
        # Default targeting: Use Class AND Namespace tags for proper isolation
        # This ensures multi-developer/multi-environment deployments don't cross-contaminate
        length(var.instances_by_class) > 0 ? [
          {
            key    = "tag:Class"
            values = keys(var.instances_by_class)
          },
          {
            key    = "tag:Namespace"
            values = [var.namespace]
          }
        ] : []
      )
    }
  }

  # Filter associations to only those with valid targets
  # If targets is empty (no instances exist and no explicit override), don't create association
  enabled_associations = {
    for name, config in local.association_configs : name => config
    if length(config.targets) > 0
  }
}

# SSM Documents - dynamically created for all YAML files in documents/
resource "aws_ssm_document" "document" {
  for_each = local.enabled_documents

  name            = "${each.value.formatted_name}-${var.namespace}"
  document_type   = "Command"
  document_format = "YAML"

  content = file(each.value.file_path)
}

# SSM State Manager Associations - one per document with valid targets
resource "aws_ssm_association" "document_association" {
  for_each = local.enabled_associations

  name             = aws_ssm_document.document[each.key].name
  association_name = "${each.key}-${var.namespace}"

  # Schedule configuration (default: rate(30 minutes))
  schedule_expression = each.value.schedule_expression

  # Parameters (if any)
  parameters = each.value.parameters

  # Targets configuration
  dynamic "targets" {
    for_each = each.value.targets
    content {
      key    = targets.value.key
      values = targets.value.values
    }
  }

  # Optional: Store execution logs in S3 (bucket provided by storage module)
  dynamic "output_location" {
    for_each = var.ssm_association_log_bucket != "" ? [1] : []
    content {
      s3_bucket_name = var.ssm_association_log_bucket
      s3_key_prefix  = "${each.key}-logs"
    }
  }

  # Compliance and control settings
  compliance_severity = each.value.compliance_severity
  max_concurrency     = each.value.max_concurrency
  max_errors          = each.value.max_errors
}
