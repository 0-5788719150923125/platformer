# archbot

Event-driven AI assistant for Atlassian tickets. Ingests webhook events via API Gateway, rebuilds full ticket context from the REST API, delegates to a configurable AI backend (Bedrock, Devin, or test), and posts responses as comments.

## Architecture

Jira Automation rule -> API Gateway HTTP API -> SQS -> Lambda -> AI backend -> Atlassian REST API (comment)

API Gateway forwards directly to SQS (no Lambda at ingestion). Failed messages retry 3 times before landing in a dead letter queue (14-day retention). The Lambda re-fetches full ticket context on every invocation - no persistence layer.

## Jira Automation Setup

After `terraform apply`, create Jira Automation rules to forward events to the webhook endpoint. Both rules use the same `webhook_url` Terraform output. This does not require Jira administrator permissions - any project member can create automation rules.

> **Limitation:** The system webhooks API and the Automation REST API both require Jira administrator permissions that InfoSec will not grant. Automation rules must be configured through the Jira UI.

### Rule 1: New issues

1. Go to your Jira project (e.g. MAINT) -> **Project settings** -> **Automation**
2. Click **Create rule**
3. **Trigger:** Select "Issue created"
4. **Action:** Select "Send web request"
   - **URL:** Paste the `webhook_url` Terraform output
   - **HTTP method:** POST
   - **Web request body:** Custom data
   - **Custom data:**
     ```json
     {
       "event": "issue_created",
       "issue": {
         "key": "{{issue.key}}"
       }
     }
     ```
   - **Headers:** None required (the endpoint is unauthenticated)
5. Name the rule (e.g. "archbot - forward new issues") and **Turn it on**

### Rule 2: New comments

1. Go to your Jira project -> **Project settings** -> **Automation**
2. Click **Create rule**
3. **Trigger:** Select "Comment created"
4. **Action:** Select "Send web request"
   - **URL:** Paste the `webhook_url` Terraform output (same URL as Rule 1)
   - **HTTP method:** POST
   - **Web request body:** Custom data
   - **Custom data:**
     ```json
      {
        "event": "comment_created",
        "issue": {
          "key": "{{issue.key}}"
        }
      }
     ```
   - **Headers:** None required
5. Name the rule (e.g. "archbot - forward new comments") and **Turn it on**

> **Do NOT include `{{comment.body}}` in the webhook payload.** Atlassian Automation interpolates smart values without JSON-escaping them. Any quotes, code blocks, or special characters in the comment body will produce invalid JSON and the Lambda will not be able to parse the payload. The Lambda re-fetches the full ticket (including all comments) from the Jira REST API on every invocation, so the webhook only needs to signal the event type and ticket key.

### Loop prevention

The Lambda uses two loop guards to prevent responding to its own comments:

1. **Pre-fetch guard:** If the webhook payload includes a `comment.body` field, the Lambda checks whether it starts with `*[archbot]*` (the prefix that `_post_comment()` always adds). If it matches, processing stops.
2. **Post-fetch guard:** After re-fetching the ticket from the Jira API, the Lambda checks whether the most recent comment starts with `*[archbot]*`. This catches bot-echo events even when the webhook JSON was malformed and the pre-fetch guard could not read the body.

If both guards fail (e.g. malformed webhook AND a race condition on comment ordering), the AI backend will still see its own prior response as an assistant turn in the conversation, which limits the damage to a single unnecessary reply.

Repeat both rules for each project in `project_keys` if they are separate Jira projects.

## Atlassian API Token

The token requires these scopes on the target project(s):

- Browse Projects
- View Issue (`read:jira-work`)
- Add Comments (`write:jira-work`)

Auth uses Basic (email:token), not Bearer. The email is configured via `atlassian_email` in the state fragment.
