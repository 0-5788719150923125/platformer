output "webhook_url" {
  value       = "${trimsuffix(aws_apigatewayv2_stage.default.invoke_url, "/")}/events"
  description = "HTTPS endpoint receiving Atlassian webhook events"
}

output "queue_url" {
  value       = aws_sqs_queue.main.url
  description = "SQS queue URL receiving Atlassian events"
}

output "dlq_url" {
  value       = aws_sqs_queue.dlq.url
  description = "Dead letter queue URL for failed event processing"
}

output "lambda_function_name" {
  value       = aws_lambda_function.atlassian_bot.function_name
  description = "Lambda function name for log tailing and manual invocation"
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
  value = var.config.knowledge_base_enabled ? [
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
  value = var.config.knowledge_base_enabled ? [
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

output "service_url_entry" {
  value = {
    url        = "${trimsuffix(aws_apigatewayv2_stage.default.invoke_url, "/")}/events"
    service    = "archbot"
    module     = "archbot"
    tenants    = []
    deployment = "archbot-atlassian-bot"
    metadata = {
      type        = "api-gateway"
      protocol    = "https"
      description = "Jira Automation webhook receiver - issue created events"
      queue_url   = aws_sqs_queue.main.url
      dlq_url     = aws_sqs_queue.dlq.url
      lambda      = aws_lambda_function.atlassian_bot.function_name
    }
  }
  description = "Structured service URL entry for the portal service registry"
}
