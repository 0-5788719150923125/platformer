# archbot

Multi-target AI bot module. Routes config by target type:

- **atlassian**: API Gateway → SQS → Lambda → Bedrock → Jira REST API
- **discord**: Local Docker container → Bedrock → Discord API

Both targets share a common AI backend (`lambdas/shared/ai_backend.py`) for Bedrock Converse, KB retrieval, tool execution, and prompt composition.

## Configuration

`var.config` is a `map(object({...}))` keyed by bot name. Each bot declares a `target` ("atlassian" or "discord") and the module creates the appropriate infrastructure.

```yaml
# states/archbot-example.yaml
services:
  archbot:
    jira-bot:
      target: atlassian
      atlassian_base_url: "https://example.atlassian.net"
      atlassian_email: "bot@example.com"
      ai_backend: bedrock
      knowledge_base_enabled: true
      kb_document_paths:
        - "./"

    ryan:
      target: discord
      discord_nickname: "Ryan"
      ai_backend: bedrock
      bedrock_model_id: "us.anthropic.claude-haiku-4-5-20251001-v1:0"
      response_rate: 1.0
      knowledge_base_enabled: true
      kb_document_paths:
        - "./"
        - "../praxis"
```

The Knowledge Base is shared across all KB-enabled bots — document paths are merged, and a single Bedrock KB + S3 Vectors index is provisioned.

## Discord Bot

### Prerequisites

- Docker
- AWS credentials available at `~/.aws` (the container mounts this read-only)
- `DISCORD_TOKEN` in `.env` at the repo root

### How it works

Terraform generates a `compose.yml` per Discord bot and runs `docker compose up -d --build`. The container connects to Discord and responds to @mentions, replies, and DMs using Bedrock Converse.

The bot loads its system prompt from SSM (same pattern as the Atlassian Lambda), applies deny list filtering and response rate sampling, and optionally enriches the system prompt with KB retrieval context.

### Build script

`scripts/build-lambdas.sh` copies `lambdas/shared/ai_backend.py` into each bot directory before Terraform packages them. This runs automatically via a `null_resource` triggered by the shared module's source hash.

## Atlassian Bot

### Architecture

Jira Automation rule → API Gateway HTTP API → SQS → Lambda → AI backend → Jira REST API (comment)

API Gateway forwards directly to SQS (no Lambda at ingestion). Failed messages retry 3 times before landing in a dead letter queue (14-day retention). The Lambda re-fetches full ticket context on every invocation — no persistence layer.

### Jira Automation Setup

After `terraform apply`, create Jira Automation rules to forward events to the webhook endpoint. Both rules use the same `webhook_urls["<bot-name>"]` output. This does not require Jira administrator permissions.

> **Limitation:** The system webhooks API and the Automation REST API both require Jira administrator permissions that InfoSec will not grant. Automation rules must be configured through the Jira UI.

#### Rule 1: New issues

1. Go to your Jira project → **Project settings** → **Automation**
2. Click **Create rule**
3. **Trigger:** "Issue created"
4. **Action:** "Send web request"
   - **URL:** Paste the `webhook_urls` output for your bot
   - **HTTP method:** POST
   - **Web request body:** Custom data
   - **Custom data:**
     ```json
     {
       "event": "issue_created",
       "issue": { "key": "{{issue.key}}" }
     }
     ```
   - **Headers:** None required (unauthenticated endpoint)
5. Name the rule and turn it on

#### Rule 2: New comments

Same as above, but with trigger "Comment created" and payload:
```json
{
  "event": "comment_created",
  "issue": { "key": "{{issue.key}}" }
}
```

> **Do NOT include `{{comment.body}}` in the webhook payload.** Atlassian Automation interpolates smart values without JSON-escaping. The Lambda re-fetches the full ticket from the Jira REST API, so the webhook only needs the event type and ticket key.

#### Loop prevention

Two guards prevent the bot from responding to its own comments:

1. **Pre-fetch:** Checks webhook `comment.body` for the `*[archbot]*` prefix
2. **Post-fetch:** After re-fetching the ticket, checks the latest comment for the same prefix

### Atlassian API Token

Required scopes: Browse Projects, View Issue (`read:jira-work`), Add Comments (`write:jira-work`). Auth uses Basic (email:token). The email is configured via `atlassian_email` in the state fragment.
