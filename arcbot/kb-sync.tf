# KB sync daemon via Docker Compose.
# When any KB bot sets kb_sync_interval, a local container rescans the document
# sources on that interval, uploads changes to the KB bucket, and re-indexes
# the Knowledge Base whenever something changed. Sources are bind-mounted
# read-only; AWS credentials come from the host's ~/.aws, like the Discord bot.

locals {
  kb_sync_source_hash = sha256(join("", [
    for f in sort(fileset("${path.module}/kb-sync", "**")) :
    filesha256("${path.module}/kb-sync/${f}")
  ]))
}

resource "local_file" "kb_sync_compose" {
  count = local.kb_sync_enabled ? 1 : 0

  filename = "${path.module}/.terraform/kb-sync/compose.yml"

  content = templatefile("${path.module}/templates/kb-sync-compose.yml.tftpl", {
    namespace         = var.namespace
    build_context     = abspath("${path.module}/kb-sync")
    aws_profile       = var.aws_profile
    aws_region        = local.aws_region
    bucket            = var.kb_documents_bucket_name
    knowledge_base_id = aws_bedrockagent_knowledge_base.arcbot[0].id
    data_source_id    = aws_bedrockagent_data_source.s3[0].data_source_id
    sync_interval     = tostring(local.kb_sync_interval)
    sources           = [for p in local.kb_document_abs_paths : abspath(p)]
    # Source i is mounted at /docs/i; prefixes match the apply-time upload.
    source_paths   = jsonencode([for i, p in local.kb_document_prefixes : ["/docs/${i}", p]])
    supported_exts = jsonencode(local.all_kb_supported_extensions)
    remap_exts     = jsonencode(local.all_kb_remap_to_txt_extensions)
  })
}

resource "null_resource" "kb_sync" {
  count = local.kb_sync_enabled ? 1 : 0

  triggers = {
    source_hash  = local.kb_sync_source_hash
    compose_hash = local_file.kb_sync_compose[0].content_md5
    compose_dir  = dirname(local_file.kb_sync_compose[0].filename)
  }

  provisioner "local-exec" {
    command     = "docker compose -f compose.yml up -d --build"
    working_dir = self.triggers.compose_dir
  }

  provisioner "local-exec" {
    when        = destroy
    command     = "docker compose -f compose.yml down"
    working_dir = self.triggers.compose_dir
    on_failure  = continue
  }
}
