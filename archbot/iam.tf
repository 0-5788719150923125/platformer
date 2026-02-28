# ArchBot IAM
# IAM roles are created by the access module via access_requests (dependency inversion).
# All values are config/variable-derived (no module-internal resource attributes).
# Local policies referencing module resources (SQS ARNs, KB ARN, S3 Vectors ARNs)
# stay as aws_iam_role_policy resources in main.tf and knowledge-base.tf.

locals {
  access_requests = concat(
    # API Gateway + Lambda roles only when atlassian bots exist
    local.has_atlassian_bots ? [
      # API Gateway SQS role - sends webhook events to SQS queue
      {
        module              = "archbot"
        type                = "iam-role"
        purpose             = "api-gateway-sqs"
        description         = "API Gateway role for sending messages to SQS"
        trust_services      = ["apigateway.amazonaws.com"]
        trust_roles         = []
        trust_actions       = ["sts:AssumeRole"]
        trust_conditions    = "{}"
        managed_policy_arns = []
        inline_policies     = {} # SQS send policy stays local (references aws_sqs_queue.main.arn)
        instance_profile    = false
      },
      # Lambda execution role - processes Atlassian ticket events
      {
        module              = "archbot"
        type                = "iam-role"
        purpose             = "lambda"
        description         = "Lambda execution role for Atlassian bot"
        trust_services      = ["lambda.amazonaws.com"]
        trust_roles         = []
        trust_actions       = ["sts:AssumeRole"]
        trust_conditions    = "{}"
        managed_policy_arns = []
        inline_policies     = {} # SQS/secrets/bedrock policy stays local
        instance_profile    = false
      },
    ] : [],
    # KB roles (conditional on knowledge base being enabled)
    local.kb_enabled ? [
      # Bedrock Knowledge Base service role
      {
        module         = "archbot"
        type           = "iam-role"
        purpose        = "bedrock-kb"
        description    = "Bedrock Knowledge Base service role (S3 + S3 Vectors + embedding model)"
        trust_services = ["bedrock.amazonaws.com"]
        trust_roles    = []
        trust_actions  = ["sts:AssumeRole"]
        trust_conditions = jsonencode({
          StringEquals = {
            "aws:SourceAccount" = local.account_id
          }
        })
        managed_policy_arns = []
        inline_policies = {
          "s3-read-access" = jsonencode({
            Version = "2012-10-17"
            Statement = [
              {
                Effect = "Allow"
                Action = ["s3:GetObject", "s3:ListBucket"]
                Resource = [
                  var.kb_documents_bucket_arn,
                  "${var.kb_documents_bucket_arn}/*"
                ]
              }
            ]
          })
          "bedrock-embedding-model" = jsonencode({
            Version = "2012-10-17"
            Statement = [
              {
                Effect   = "Allow"
                Action   = "bedrock:InvokeModel"
                Resource = "arn:aws:bedrock:${local.aws_region}::foundation-model/${local.kb_embedding_model_id}"
              }
            ]
          })
        }
        instance_profile = false
      },
      # KB Ingestion Reporter Lambda role
      {
        module              = "archbot"
        type                = "iam-role"
        purpose             = "kb-ingestion-reporter"
        description         = "Lambda role for KB ingestion reporter"
        trust_services      = ["lambda.amazonaws.com"]
        trust_roles         = []
        trust_actions       = ["sts:AssumeRole"]
        trust_conditions    = "{}"
        managed_policy_arns = []
        inline_policies     = {} # Bedrock ingestion policy stays local
        instance_profile    = false
      },
    ] : []
  )
}

locals {
  access_resource_policies = [
    for n, b in local.atlassian_bots : {
      module        = "archbot"
      resource_type = "sqs-queue-policy"
      resource_name = aws_sqs_queue.main[n].name
      policy        = aws_sqs_queue_policy.main[n].policy
    }
  ]
}
