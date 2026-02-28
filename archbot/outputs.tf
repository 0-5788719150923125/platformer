output "webhook_urls" {
  value       = { for n, _ in local.atlassian_bots : n => "${trimsuffix(aws_apigatewayv2_stage.default[n].invoke_url, "/")}/events" }
  description = "HTTPS endpoints receiving Atlassian webhook events (keyed by bot name)"
}

output "queue_urls" {
  value       = { for n, _ in local.atlassian_bots : n => aws_sqs_queue.main[n].url }
  description = "SQS queue URLs receiving Atlassian events (keyed by bot name)"
}

output "dlq_urls" {
  value       = { for n, _ in local.atlassian_bots : n => aws_sqs_queue.dlq[n].url }
  description = "Dead letter queue URLs for failed event processing (keyed by bot name)"
}

output "lambda_function_names" {
  value       = { for n, _ in local.atlassian_bots : n => aws_lambda_function.atlassian_bot[n].function_name }
  description = "Lambda function names for log tailing and manual invocation (keyed by bot name)"
}

output "knowledge_base_id" {
  value       = local.kb_enabled ? aws_bedrockagent_knowledge_base.archbot[0].id : null
  description = "Bedrock Knowledge Base ID (null when KB is disabled)"
}

output "bucket_requests" {
  description = "S3 bucket requests for the storage module (dependency inversion)"
  value = local.kb_enabled ? [
    {
      purpose            = "archbot-kb-docs"
      description        = "Bedrock Knowledge Base document store for archbot RAG"
      versioning_enabled = false
      access_logging     = false
      force_destroy      = true
    }
  ] : []
}

output "kb_documents_bucket" {
  value       = local.kb_enabled ? var.kb_documents_bucket_name : null
  description = "S3 bucket name for KB documents (null when KB is disabled)"
}

output "event_bus_requests" {
  description = "Event bus webhook subscription requests (portal creates webhooks)"
  value = local.kb_enabled ? [
    {
      purpose     = "kb-ingestion-lifecycle"
      description = "KB ingestion lifecycle events (archbot)"
      event_type  = "kb-ingestion"
      source      = "archbot"
    }
  ] : []
}

output "commands" {
  description = "Operational commands for portal self-service actions"
  value = local.kb_enabled ? [
    {
      title          = "Reindex Knowledge Base"
      description    = "Trigger KB document re-indexing for archbot RAG"
      commands       = ["aws lambda invoke --function-name ${aws_lambda_function.kb_ingestion_reporter[0].function_name} --payload '{\"knowledge_base_id\":\"${aws_bedrockagent_knowledge_base.archbot[0].id}\",\"data_source_id\":\"${aws_bedrockagent_data_source.s3[0].data_source_id}\"}' --region ${local.aws_region} /tmp/kb-reindex.json"]
      service        = "archbot"
      category       = "kb-reindex"
      target_type    = "service"
      target         = "archbot"
      execution      = "local"
      blueprint_type = "service_url"
      action_config = {
        type              = "lambda_invoke"
        function_name     = aws_lambda_function.kb_ingestion_reporter[0].function_name
        region            = local.aws_region
        knowledge_base_id = aws_bedrockagent_knowledge_base.archbot[0].id
        data_source_id    = aws_bedrockagent_data_source.s3[0].data_source_id
      }
    }
  ] : []
}

output "access_requests" {
  description = "IAM access requests for the access module (access creates resources, returns ARNs)"
  value       = local.access_requests
}

# Access: Resource Policies (dependency inversion interface for access module)
output "access_resource_policies" {
  description = "Resource-level policies for the access module (SQS queue policy)"
  value       = local.access_resource_policies
}

output "service_url_entries" {
  value = [
    for n, _ in local.atlassian_bots : {
      url        = "${trimsuffix(aws_apigatewayv2_stage.default[n].invoke_url, "/")}/events"
      service    = "archbot"
      module     = "archbot"
      tenants    = []
      deployment = "archbot-${n}"
      metadata = {
        type        = "api-gateway"
        protocol    = "https"
        description = "Jira Automation webhook receiver - ${n}"
        queue_url   = aws_sqs_queue.main[n].url
        dlq_url     = aws_sqs_queue.dlq[n].url
        lambda      = aws_lambda_function.atlassian_bot[n].function_name
      }
    }
  ]
  description = "Structured service URL entries for the portal service registry"
}

output "discord_bots" {
  value = {
    for n, b in local.discord_bots : n => {
      nickname       = b.discord_nickname
      container_name = "archbot-${n}-${var.namespace}"
    }
  }
  description = "Discord bot container info (keyed by bot name)"
}
