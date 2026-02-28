# Discord bot deployment via Docker Compose.
# Generates a compose.yml per Discord bot and manages the container lifecycle.

locals {
  discord_bot_source_hash = sha256(join("", concat(
    [local.shared_source_hash],
    [for f in sort(fileset("${path.module}/lambdas/discord-bot", "**")) :
      filesha256("${path.module}/lambdas/discord-bot/${f}")
    ]
  )))
}

resource "local_file" "discord_compose" {
  for_each = local.discord_bots

  filename = "${path.module}/.terraform/discord/${each.key}/compose.yml"

  content = templatefile("${path.module}/templates/discord-compose.yml.tftpl", {
    bot_name              = each.key
    namespace             = var.namespace
    build_context         = abspath("${path.module}/lambdas/discord-bot")
    env_file              = abspath("${path.root}/.env")
    aws_profile           = var.aws_profile
    discord_nickname      = each.value.discord_nickname != null ? each.value.discord_nickname : each.key
    ai_backend            = each.value.ai_backend
    bedrock_model_id      = each.value.bedrock_model_id
    bedrock_max_tokens    = tostring(each.value.bedrock_max_tokens)
    bedrock_temperature   = tostring(each.value.bedrock_temperature)
    debug                 = tostring(each.value.debug)
    system_prompt_param   = aws_ssm_parameter.system_prompt[each.key].name
    deny_list             = jsonencode(each.value.deny_list)
    response_rate         = tostring(each.value.response_rate)
    discord_history_limit = tostring(each.value.discord_history_limit)
    knowledge_base_id     = each.value.knowledge_base_enabled && local.kb_enabled ? aws_bedrockagent_knowledge_base.archbot[0].id : ""
    kb_max_results        = tostring(each.value.kb_max_results)
    aws_region            = local.aws_region
  })
}

resource "null_resource" "discord_bot" {
  for_each = local.discord_bots

  triggers = {
    source_hash  = local.discord_bot_source_hash
    compose_hash = local_file.discord_compose[each.key].content_md5
    compose_dir  = dirname(local_file.discord_compose[each.key].filename)
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

  depends_on = [null_resource.build_lambdas]
}
