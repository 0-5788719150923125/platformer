# Knowledge Base (RAG) infrastructure for archbot.
# Provisions an S3 document store, S3 Vectors index, Bedrock Knowledge Base
# with data source, and an ingestion pipeline triggered at apply-time.
#
# All resources are gated behind var.config.knowledge_base_enabled.

# -- Data sources (ARN construction) ------------------------------------------

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

locals {
  kb_enabled = var.config.knowledge_base_enabled
  aws_region = data.aws_region.current.id
  account_id = data.aws_caller_identity.current.account_id
  kb_prefix  = "archbot-kb-${var.namespace}"

  # Absolute paths for each configured document source directory.
  kb_document_abs_paths = [
    for p in var.config.kb_document_paths : "${path.root}/${p}"
  ]
}

# -- S3 document store --------------------------------------------------------
# Bucket is provisioned by the storage module via bucket_requests (dependency
# inversion). The name and ARN are passed back as var.kb_documents_bucket_name
# and var.kb_documents_bucket_arn from root main.tf.

# -- Document upload ----------------------------------------------------------
# Uses aws s3 sync instead of per-file aws_s3_object resources. This keeps
# exactly 1 resource in state regardless of how many files exist. A content
# hash computed by an external data source triggers re-sync on changes.

data "external" "kb_documents_hash" {
  count   = local.kb_enabled ? 1 : 0
  program = ["bash", "${path.module}/scripts/hash-documents.sh"]

  query = {
    paths = jsonencode(local.kb_document_abs_paths)
  }
}

resource "null_resource" "kb_document_sync" {
  count = local.kb_enabled ? 1 : 0

  triggers = {
    content_hash    = data.external.kb_documents_hash[0].result.hash
    bucket_id       = var.kb_documents_bucket_name
    bucket_replaced = var.kb_documents_bucket_trigger
  }

  provisioner "local-exec" {
    command = "bash ${path.module}/scripts/kb-upload.sh"

    environment = {
      AWS_PROFILE    = var.aws_profile
      AWS_REGION     = local.aws_region
      BUCKET         = var.kb_documents_bucket_name
      SOURCE_PATHS   = jsonencode([for p in var.config.kb_document_paths : ["${path.root}/${p}", trimsuffix(trimprefix(replace(p, "../", ""), "."), "/")]])
      SUPPORTED_EXTS = jsonencode(var.config.kb_supported_extensions)
      REMAP_EXTS     = jsonencode(var.config.kb_remap_to_txt_extensions)
    }
  }
}

# -- S3 Vectors (vector store) ------------------------------------------------
# Fully managed by AWS. No access policies, no security policies, no scripts.

resource "aws_s3vectors_vector_bucket" "kb" {
  count              = local.kb_enabled ? 1 : 0
  vector_bucket_name = local.kb_prefix

  encryption_configuration {
    sse_type = "AES256"
  }

  tags = {
    Name      = local.kb_prefix
    Namespace = var.namespace
  }
}

resource "aws_s3vectors_index" "kb" {
  count              = local.kb_enabled ? 1 : 0
  index_name         = "bedrock-kb-index"
  vector_bucket_name = aws_s3vectors_vector_bucket.kb[0].vector_bucket_name
  data_type          = "float32"
  dimension          = 1024
  distance_metric    = "cosine"

  metadata_configuration {
    non_filterable_metadata_keys = [
      "AMAZON_BEDROCK_TEXT_CHUNK",
      "AMAZON_BEDROCK_METADATA",
    ]
  }
}

# -- Bedrock KB service IAM (local policies on access-created role) ------------
# Role is created by access module via access_requests. Only policies referencing
# module-internal resources (S3 Vectors bucket/index) stay here.

resource "aws_iam_role_policy" "bedrock_kb_s3vectors" {
  count = local.kb_enabled ? 1 : 0
  name  = "s3vectors-access"
  role  = var.access_iam_role_names["archbot-bedrock-kb"]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = "s3vectors:*"
        Resource = [
          aws_s3vectors_vector_bucket.kb[0].vector_bucket_arn,
          aws_s3vectors_index.kb[0].index_arn
        ]
      }
    ]
  })
}

# -- Bedrock Knowledge Base ---------------------------------------------------

resource "aws_bedrockagent_knowledge_base" "archbot" {
  count = local.kb_enabled ? 1 : 0
  name  = local.kb_prefix

  role_arn = var.access_iam_role_arns["archbot-bedrock-kb"]

  knowledge_base_configuration {
    type = "VECTOR"

    vector_knowledge_base_configuration {
      embedding_model_arn = "arn:aws:bedrock:${local.aws_region}::foundation-model/${var.config.embedding_model_id}"
    }
  }

  storage_configuration {
    type = "S3_VECTORS"

    s3_vectors_configuration {
      index_arn = aws_s3vectors_index.kb[0].index_arn
    }
  }

  tags = {
    Name      = local.kb_prefix
    Namespace = var.namespace
  }
}

# -- Bedrock Data Source (S3) -------------------------------------------------

resource "aws_bedrockagent_data_source" "s3" {
  count             = local.kb_enabled ? 1 : 0
  name              = "${local.kb_prefix}-s3"
  knowledge_base_id = aws_bedrockagent_knowledge_base.archbot[0].id

  data_source_configuration {
    type = "S3"

    s3_configuration {
      bucket_arn = var.kb_documents_bucket_arn
    }
  }

  vector_ingestion_configuration {
    chunking_configuration {
      chunking_strategy = var.config.kb_chunking_strategy

      dynamic "semantic_chunking_configuration" {
        for_each = var.config.kb_chunking_strategy == "SEMANTIC" ? [1] : []
        content {
          max_token                       = 300
          buffer_size                     = 0
          breakpoint_percentile_threshold = 95
        }
      }

      dynamic "fixed_size_chunking_configuration" {
        for_each = var.config.kb_chunking_strategy == "FIXED_SIZE" ? [1] : []
        content {
          max_tokens         = 300
          overlap_percentage = 20
        }
      }
    }
  }

  data_deletion_policy = "DELETE"

  lifecycle {
    replace_triggered_by = [aws_bedrockagent_knowledge_base.archbot[0].id]
  }
}

# -- Ingestion reporter Lambda ------------------------------------------------
# Replaces the old fire-and-forget provisioner with a Lambda that starts
# the ingestion job, polls until completion, and reports lifecycle events
# to the Port event bus webhook.

locals {
  kb_ingestion_reporter_source_hash = filesha256("${path.module}/lambdas/kb-ingestion-reporter/main.py")
}

data "archive_file" "kb_ingestion_reporter" {
  count = local.kb_enabled ? 1 : 0

  type        = "zip"
  source_file = "${path.module}/lambdas/kb-ingestion-reporter/main.py"
  output_path = "${path.module}/.terraform/lambda/kb-ingestion-reporter-${local.kb_ingestion_reporter_source_hash}.zip"
}

# -- KB Ingestion Reporter IAM (local policy on access-created role) -----------
# Role is created by access module via access_requests. Policy references
# module-internal KB ARN so it stays here.

resource "aws_iam_role_policy" "kb_ingestion_reporter" {
  count = local.kb_enabled ? 1 : 0
  name  = "kb-ingestion-reporter"
  role  = var.access_iam_role_names["archbot-kb-ingestion-reporter"]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Effect = "Allow"
        Action = [
          "bedrock:StartIngestionJob",
          "bedrock:GetIngestionJob"
        ]
        Resource = aws_bedrockagent_knowledge_base.archbot[0].arn
      }
    ]
  })
}

resource "aws_lambda_function" "kb_ingestion_reporter" {
  count = local.kb_enabled ? 1 : 0

  function_name = "kb-ingestion-reporter-${var.namespace}"
  description   = "Start KB ingestion, poll to completion, report to Port event bus"
  role          = var.access_iam_role_arns["archbot-kb-ingestion-reporter"]
  handler       = "main.handler"
  runtime       = "python3.12"
  timeout       = 900

  filename         = data.archive_file.kb_ingestion_reporter[0].output_path
  source_code_hash = data.archive_file.kb_ingestion_reporter[0].output_base64sha256

  environment {
    variables = {
      WEBHOOK_URL    = lookup(var.event_bus_webhooks, "kb-ingestion-lifecycle", "")
      NAMESPACE      = var.namespace
      AWS_REGION_VAR = local.aws_region
    }
  }

  tags = {
    Name      = "kb-ingestion-reporter-${var.namespace}"
    Namespace = var.namespace
  }
}

# -- Ingestion trigger --------------------------------------------------------
# Re-syncs the KB when documents change on disk or the data source is recreated.
# Invokes the reporter Lambda asynchronously (--invocation-type Event) so
# Terraform returns immediately. The Lambda posts STARTED/SUCCEEDED/FAILED
# events to the Port webhook as the ingestion progresses.

resource "null_resource" "kb_ingestion" {
  count = local.kb_enabled ? 1 : 0

  triggers = {
    content_hash    = data.external.kb_documents_hash[0].result.hash
    data_source_id  = aws_bedrockagent_data_source.s3[0].data_source_id
    bucket_replaced = var.kb_documents_bucket_trigger
  }

  provisioner "local-exec" {
    command = "aws lambda invoke --function-name \"$FUNCTION_NAME\" --invocation-type Event --payload \"$PAYLOAD\" --cli-binary-format raw-in-base64-out --region \"$AWS_REGION\" /tmp/kb-ingestion-response.json"

    environment = {
      AWS_PROFILE   = var.aws_profile
      AWS_REGION    = local.aws_region
      FUNCTION_NAME = aws_lambda_function.kb_ingestion_reporter[0].function_name
      PAYLOAD = jsonencode({
        knowledge_base_id = aws_bedrockagent_knowledge_base.archbot[0].id
        data_source_id    = aws_bedrockagent_data_source.s3[0].data_source_id
      })
    }
  }

  depends_on = [
    null_resource.kb_document_sync,
    aws_bedrockagent_data_source.s3,
    aws_lambda_function.kb_ingestion_reporter
  ]
}

# -- Lambda IAM - KB Retrieve permission --------------------------------------
# Separate policy resource so we don't modify the existing Lambda IAM policy.

resource "aws_iam_role_policy" "lambda_kb_retrieve" {
  count = local.kb_enabled ? 1 : 0
  name  = "bedrock-kb-retrieve"
  role  = var.access_iam_role_names["archbot-lambda"]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "bedrock:Retrieve"
        Resource = aws_bedrockagent_knowledge_base.archbot[0].arn
      }
    ]
  })
}
