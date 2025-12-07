"""
archbot - Atlassian Bot Lambda Handler

Event-driven AI assistant for Atlassian maintenance tickets.

Supported events (via payload "event" field):
  - issue_created: New ticket triage (default for backward compat)
  - comment_created: Respond to a new comment on an existing ticket

Flow per SQS record:
  1. Extract ticket key and event type from Atlassian Automation webhook payload
  2. For comment events, check loop guard (skip if author is the bot)
  3. Re-fetch full ticket context from Atlassian REST API (summary, description,
     comments, linked issues) - no reliance on webhook payload completeness
  4. Build a structured prompt from the ticket context (framing varies by event type)
  5. Route to the configured AI backend (devin, bedrock, or test)
  6. Post the AI response as a comment on the ticket

AI backends (configured via AI_BACKEND env var):
  - devin:   Creates a Devin AI session and polls until completion
  - bedrock: Amazon Bedrock Converse API - invokes a foundation model directly
  - test:    Echo bot - logs the prompt and returns a canned response

Context persistence: Jira comment thread. For Bedrock, each invocation reconstructs the
full conversation from the ticket's comment history. Comments with the *[archbot]* prefix
are mapped to the assistant role; all others become user turns. Consecutive same-role
messages are merged to satisfy Bedrock's alternating-turn constraint.
Failed messages (raised exceptions) are returned as batchItemFailures so SQS retries
only the individual message, not the whole batch.

Required Atlassian PAT permissions:
  - Browse Projects
  - View Issue (read:jira-work scope)
  - Add Comments (write:jira-work scope)
"""

import base64
import json
import logging
import os
import random
import time
import traceback
import urllib.error
import urllib.request

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# -- Environment ---------------------------------------------------------------

AI_BACKEND = os.environ.get("AI_BACKEND", "devin")
ATLASSIAN_BASE_URL = os.environ["ATLASSIAN_BASE_URL"].rstrip("/")
ATLASSIAN_EMAIL = os.environ["ATLASSIAN_EMAIL"]
ATLASSIAN_SECRET_ID = os.environ["ATLASSIAN_SECRET_ID"]
DEVIN_SECRET_ID = os.environ.get("DEVIN_SECRET_ID", "")
DEVIN_POLL_INTERVAL = int(os.environ.get("DEVIN_POLL_INTERVAL", "15"))
DEVIN_MAX_WAIT = int(os.environ.get("DEVIN_MAX_WAIT", "720"))
BEDROCK_MODEL_ID = os.environ.get("BEDROCK_MODEL_ID", "us.anthropic.claude-haiku-4-5-20251001-v1:0")
BEDROCK_MAX_TOKENS = int(os.environ.get("BEDROCK_MAX_TOKENS", "512"))
BEDROCK_TEMPERATURE = float(os.environ.get("BEDROCK_TEMPERATURE", "0.3"))
DEBUG_MODE = os.environ.get("DEBUG_MODE", "false").lower() == "true"
_ssm_param = os.environ.get("SYSTEM_PROMPT_PARAM")
if _ssm_param:
    _ssm = boto3.client("ssm", region_name=os.environ.get("AWS_REGION", "us-east-2"))
    SYSTEM_PROMPT = _ssm.get_parameter(Name=_ssm_param)["Parameter"]["Value"]
else:
    SYSTEM_PROMPT = os.environ.get("SYSTEM_PROMPT", "")
DENY_LIST = json.loads(os.environ.get("DENY_LIST", "[]"))
RESPONSE_RATE = float(os.environ.get("RESPONSE_RATE", "0.25"))
KNOWLEDGE_BASE_ID = os.environ.get("KNOWLEDGE_BASE_ID", "")
KB_MAX_RESULTS = int(os.environ.get("KB_MAX_RESULTS", "5"))


def _compose_system_prompt(base, deny_list):
    """Return the effective system prompt, appending deny list instructions when configured."""
    if not deny_list:
        return base
    items = "\n".join(f"- {entry}" for entry in deny_list)
    deny_section = (
        "## Deny List\n"
        "The following names, email addresses, topics, or identifiers must not be engaged with:\n"
        f"{items}\n\n"
        "If a ticket is reported by or primarily authored by someone on this list, or if a "
        "comment is posted by someone on this list, or if the primary subject of the ticket or "
        "comment is one of these items, reply with exactly [NO_RESPONSE] and nothing else."
    )
    separator = "\n\n" if base else ""
    return f"{base}{separator}{deny_section}"


EFFECTIVE_SYSTEM_PROMPT = _compose_system_prompt(SYSTEM_PROMPT, DENY_LIST)

DEVIN_API_BASE = "https://api.devin.ai/v1"

# Devin statuses that are still actively working - anything else is considered terminal
DEVIN_ACTIVE_STATUSES = {"new", "resuming", "claimed", "active", "running", "queued"}

# Maximum tool-use roundtrips before forcing a final response
MAX_TOOL_ITERATIONS = 5

# Sentinel the model returns to signal "I choose not to respond"
NO_RESPONSE_SENTINEL = "[NO_RESPONSE]"

# Tools available to the Bedrock backend
TOOL_DEFINITIONS = [
    {
        "toolSpec": {
            "name": "whoami",
            "description": (
                "Returns the archbot Lambda's own AWS identity (account, ARN, role name) "
                "and the IAM policies attached to its execution role. Use this when asked "
                "about the bot's own permissions, role, or identity."
            ),
            "inputSchema": {"json": {"type": "object", "properties": {}, "required": []}},
        }
    },
    {
        "toolSpec": {
            "name": "query_iam_permissions",
            "description": (
                "Looks up the IAM policies attached to an AWS principal (IAM user, IAM role, "
                "or assumed-role session) and optionally simulates whether specific actions "
                "are allowed. Use this to answer questions about what a user or service can "
                "or cannot do in AWS. Assumed-role ARNs are automatically resolved to their "
                "underlying role before lookup."
            ),
            "inputSchema": {
                "json": {
                    "type": "object",
                    "properties": {
                        "principal_arn": {
                            "type": "string",
                            "description": (
                                "Full ARN of the principal to inspect. Accepts IAM user ARNs "
                                "(arn:aws:iam::ACCOUNT:user/NAME), role ARNs "
                                "(arn:aws:iam::ACCOUNT:role/NAME), or assumed-role session ARNs "
                                "(arn:aws:sts::ACCOUNT:assumed-role/ROLE/SESSION)."
                            ),
                        },
                        "actions": {
                            "type": "array",
                            "items": {"type": "string"},
                            "description": (
                                "Optional list of IAM action strings to simulate against the "
                                "principal (e.g. ['s3:GetObject', 'ec2:DescribeInstances']). "
                                "Returns allowed/denied/implicitly-denied for each."
                            ),
                        },
                    },
                    "required": ["principal_arn"],
                }
            },
        }
    },
]


# -- Entrypoint ----------------------------------------------------------------


def handler(event, context):
    failures = []
    for record in event.get("Records", []):
        try:
            payload = _parse_webhook(record["body"])
            process_event(payload)
        except Exception as exc:
            logger.error(
                "Failed to process record %s: %s",
                record["messageId"],
                exc,
                exc_info=True,
            )
            failures.append({"itemIdentifier": record["messageId"]})
    return {"batchItemFailures": failures}


import re

# Patterns for extracting minimum fields from malformed webhook JSON.
# The event and issue.key fields appear early in the payload before any
# user-controlled content, so simple regex is reliable for them.
_RE_EVENT = re.compile(r'"event"\s*:\s*"([^"]+)"')
_RE_KEY = re.compile(r'"key"\s*:\s*"([^"]+)"')


def _parse_webhook(body):
    """Parse the Atlassian Automation webhook payload from SQS.

    Atlassian Automation interpolates smart values (like {{comment.body}})
    into the JSON template WITHOUT escaping. Any quotes, backslashes, or
    control characters in the comment body produce invalid JSON.

    When strict parsing fails, we fall back to regex extraction of the event
    type and ticket key - the only fields the Lambda actually needs from the
    webhook, since everything else is re-fetched from the Jira REST API.
    """
    try:
        return json.loads(body, strict=False)
    except json.JSONDecodeError:
        key_match = _RE_KEY.search(body)
        if not key_match:
            raise  # Can't recover without a ticket key
        event_match = _RE_EVENT.search(body)
        logger.warning(
            "Webhook JSON malformed - falling back to regex extraction (key=%s)",
            key_match.group(1),
        )
        return {
            "event": event_match.group(1) if event_match else "comment_created",
            "issue": {"key": key_match.group(1)},
        }


# -- Event processing ----------------------------------------------------------


def process_event(payload):
    ticket_key = _extract_ticket_key(payload)
    event_type = payload.get("event", "issue_created")
    logger.info("Processing %s event=%s (backend=%s)", ticket_key, event_type, AI_BACKEND)

    if event_type == "comment_created" and _should_skip_comment(payload):
        return

    # Always respond to new tickets (greeting); apply sampling only to comments
    if event_type != "issue_created" and random.random() >= RESPONSE_RATE:
        logger.info("Skipping %s event=%s (response_rate=%.2f)", ticket_key, event_type, RESPONSE_RATE)
        return

    secrets = _fetch_secrets()
    reply_context = None

    try:
        ticket = _fetch_issue(ticket_key, secrets["atlassian_pat"])

        # Second loop guard: check the actual latest comment from the API.
        # Catches bot-echo events that slipped past _should_skip_comment
        # (e.g. when the webhook JSON was malformed and the comment body
        # wasn't available for the first check).
        if event_type == "comment_created":
            latest_comments = ticket.get("fields", {}).get("comment", {}).get("comments", [])
            if latest_comments:
                latest_body = _body_to_text(latest_comments[-1].get("body", "")).strip()
                if latest_body.startswith(BOT_PREFIX):
                    logger.info("Skipping %s - latest comment is from archbot (post-fetch guard)", ticket_key)
                    return

        reply_context = payload.get("comment") if event_type == "comment_created" else None
        response_text = _get_ai_response(ticket, ticket_key, secrets, event_type=event_type,
                                         triggering_comment=reply_context)
    except Exception as exc:
        logger.error("Failed processing %s: %s", ticket_key, exc, exc_info=True)
        if DEBUG_MODE:
            tb = traceback.format_exc()
            # Truncate to keep Jira comment readable; full trace is in CloudWatch
            tb_lines = tb.strip().splitlines()
            tb_short = "\n".join(tb_lines[-20:]) if len(tb_lines) > 20 else tb
            _post_comment(
                ticket_key,
                f"_(debug) `{type(exc).__name__}: {exc}`_\n\n{{code}}\n{tb_short}\n{{code}}",
                secrets["atlassian_pat"],
                reply_context=reply_context,
            )
        raise

    # The model can opt out of responding by returning the sentinel
    if response_text.strip() == NO_RESPONSE_SENTINEL:
        logger.info("AI opted out of responding to %s event=%s", ticket_key, event_type)
        return

    _post_comment(ticket_key, response_text, secrets["atlassian_pat"], reply_context=reply_context)
    logger.info("Posted response to %s event=%s (backend=%s)", ticket_key, event_type, AI_BACKEND)


def _should_skip_comment(payload):
    """Loop guard - skip comments posted by the bot itself.

    Detection uses the *[archbot]* body prefix that _post_comment() always
    adds.  We intentionally do NOT check the author email because the bot's
    ATLASSIAN_EMAIL may match a real user during testing.

    This is a guard - if body extraction fails, the safe default is to NOT
    skip (continue processing). Worst case the bot replies to itself once and
    the next invocation catches it.
    """
    try:
        body = _body_to_text(payload.get("comment", {}).get("body", ""))
    except Exception as exc:
        logger.warning("Loop guard body extraction failed: %s", exc)
        return False

    if body.startswith("*[archbot]*"):
        logger.info("Skipping comment - body starts with archbot signature")
        return True

    return False


# -- AI backend dispatch -------------------------------------------------------


def _get_ai_response(ticket, ticket_key, secrets, event_type="issue_created", triggering_comment=None):
    if AI_BACKEND == "devin":
        prompt = _build_prompt(ticket, event_type=event_type)
        return _devin_backend(prompt, ticket_key, secrets["devin_api_key"])
    elif AI_BACKEND == "bedrock":
        messages = _build_messages(ticket, event_type, triggering_comment=triggering_comment)
        return _bedrock_backend(messages, ticket_key)
    elif AI_BACKEND == "test":
        prompt = _build_prompt(ticket, event_type=event_type)
        return _test_backend(prompt, ticket_key, event_type=event_type)
    else:
        raise ValueError(f"Unknown AI backend: {AI_BACKEND}")


def _test_backend(prompt, ticket_key, event_type="issue_created"):
    if EFFECTIVE_SYSTEM_PROMPT:
        logger.info("=== TEST BACKEND - system prompt ===\n%s", EFFECTIVE_SYSTEM_PROMPT)
    logger.info("=== TEST BACKEND - context for %s ===\n%s", ticket_key, prompt)
    logger.info("=== END context for %s ===", ticket_key)
    return (
        f"[TEST] Echo response for {ticket_key} ({event_type}). "
        "AI backend is disabled. The pipeline is working correctly."
    )


def _sanitize_messages(messages, ticket_key):
    """Remove messages with empty content and re-merge any consecutive same-role
    messages that result from the removal. Logs every skipped message so the
    root cause can be traced in CloudWatch without crashing the invocation.
    """
    clean = []
    for i, msg in enumerate(messages):
        role = msg.get("role", "unknown")
        content = msg.get("content") or []

        # Filter out content blocks that have no usable text.
        # Bedrock Converse content blocks use the key itself as the type
        # discriminator (e.g. {"text": "..."}, {"toolUse": {...}}) - there is
        # no separate "type" field.
        valid = [
            block for block in content
            if "text" not in block or (block.get("text") or "").strip()
        ]

        if not valid:
            logger.warning(
                "Dropping messages[%d] with empty content (role=%s) for %s",
                i, role, ticket_key,
            )
            continue

        # Re-merge with previous message if same role (can happen after drops)
        if clean and clean[-1]["role"] == role:
            prev_text = clean[-1]["content"][0].get("text", "")
            curr_text = valid[0].get("text", "")
            clean[-1]["content"][0]["text"] = f"{prev_text}\n\n{curr_text}".strip()
        else:
            clean.append({"role": role, "content": valid})

    logger.info(
        "Sanitized messages for %s: %d -> %d entries",
        ticket_key, len(messages), len(clean),
    )
    return clean


def _bedrock_backend(messages, ticket_key):
    # Build system prompt, optionally enriched with KB context.
    # KB query is derived from the first (ticket context) message.
    system_text = EFFECTIVE_SYSTEM_PROMPT or ""
    if KNOWLEDGE_BASE_ID:
        first_text = messages[0]["content"][0]["text"]
        summary, description = _extract_summary_description(first_text)
        kb_context = _retrieve_kb_context(summary, description)
        if kb_context:
            separator = "\n\n" if system_text else ""
            system_text = f"{system_text}{separator}## Knowledge Base Context\n{kb_context}"

    client = boto3.client("bedrock-runtime")
    kwargs: dict = {"toolConfig": {"tools": TOOL_DEFINITIONS, "toolChoice": {"auto": {}}}}
    if system_text:
        kwargs["system"] = [{"text": system_text}]

    current_messages = _sanitize_messages(list(messages), ticket_key)
    output_message = None

    # Log message structure so any remaining empty-content issues are visible in CloudWatch
    logger.info(
        "Converse payload for %s: %d messages: %s",
        ticket_key,
        len(current_messages),
        [(i, m["role"], len(m.get("content", [])),
          len((m.get("content") or [{}])[0].get("text", "") or ""))
         for i, m in enumerate(current_messages)],
    )

    for iteration in range(MAX_TOOL_ITERATIONS):
        response = client.converse(
            modelId=BEDROCK_MODEL_ID,
            messages=current_messages,
            inferenceConfig={"maxTokens": BEDROCK_MAX_TOKENS, "temperature": BEDROCK_TEMPERATURE},
            **kwargs,
        )
        stop_reason = response["stopReason"]
        output_message = response["output"]["message"]

        if stop_reason == "end_turn":
            text = output_message["content"][0]["text"]
            logger.info(
                "Bedrock response for %s: %d chars, %d turns, %d tool iterations (model=%s, kb=%s)",
                ticket_key, len(text), len(current_messages), iteration,
                BEDROCK_MODEL_ID, KNOWLEDGE_BASE_ID or "none",
            )
            return text

        if stop_reason != "tool_use":
            logger.warning("Unexpected stopReason for %s: %s", ticket_key, stop_reason)
            break

        # Execute all tool calls returned in this turn.
        # Bedrock Converse content blocks use keys as type discriminators:
        # {"text": "..."} for text, {"toolUse": {...}} for tool calls.
        current_messages.append({"role": "assistant", "content": output_message["content"]})
        tool_results = []
        for block in output_message["content"]:
            if "toolUse" not in block:
                continue
            tool_use = block["toolUse"]
            tool_name = tool_use["name"]
            tool_input = tool_use.get("input", {})
            logger.info("Tool call [%s]: %s(%s)", ticket_key, tool_name, tool_input)
            result = _execute_tool(tool_name, tool_input)
            tool_results.append({
                "toolResult": {
                    "toolUseId": tool_use["toolUseId"],
                    "content": [{"text": json.dumps(result, indent=2)}],
                }
            })
        if tool_results:
            current_messages.append({"role": "user", "content": tool_results})

    # Fell out of the loop - extract any text from the last response
    logger.warning("Tool loop exhausted for %s after %d iterations", ticket_key, MAX_TOOL_ITERATIONS)
    if output_message:
        for block in output_message.get("content", []):
            if "text" in block:
                return block["text"]
    return "I was unable to complete the analysis within the allowed number of steps."


def _retrieve_kb_context(ticket_summary, ticket_description):
    """Retrieve relevant document chunks from Bedrock Knowledge Base.

    Constructs a query from the ticket summary and description (truncated to
    keep the retrieval query focused). Returns a formatted string of retrieved
    chunks, or an empty string if retrieval fails or returns no results.
    """
    if not KNOWLEDGE_BASE_ID:
        return ""

    description_excerpt = (ticket_description or "")[:500]
    query = f"{ticket_summary}\n{description_excerpt}".strip()
    if not query:
        return ""

    try:
        client = boto3.client("bedrock-agent-runtime")
        response = client.retrieve(
            knowledgeBaseId=KNOWLEDGE_BASE_ID,
            retrievalQuery={"text": query},
            retrievalConfiguration={
                "vectorSearchConfiguration": {
                    "numberOfResults": KB_MAX_RESULTS
                }
            },
        )

        results = response.get("retrievalResults", [])
        if not results:
            logger.info("KB retrieval returned no results for query: %s", query[:100])
            return ""

        chunks = []
        for i, result in enumerate(results, 1):
            text = result.get("content", {}).get("text", "").strip()
            score = result.get("score", 0)
            source = result.get("location", {}).get("s3Location", {}).get("uri", "unknown")
            if text:
                chunks.append(f"[{i}] (score={score:.3f}, source={source})\n{text}")

        if not chunks:
            return ""

        context = "\n---\n".join(chunks)
        logger.info(
            "KB retrieval returned %d chunks for %s (query: %s)",
            len(chunks), KNOWLEDGE_BASE_ID, query[:80],
        )
        return f"Relevant knowledge base context:\n{context}"

    except Exception as exc:
        logger.warning("KB retrieval failed (non-fatal): %s", exc)
        return ""


# -- Tool execution ------------------------------------------------------------


def _execute_tool(tool_name, tool_input):
    """Dispatch a tool call and return a JSON-serialisable result dict."""
    try:
        if tool_name == "whoami":
            return _tool_whoami()
        if tool_name == "query_iam_permissions":
            return _tool_query_iam_permissions(
                principal_arn=tool_input["principal_arn"],
                actions=tool_input.get("actions"),
            )
        return {"error": f"Unknown tool: {tool_name}"}
    except Exception as exc:
        logger.warning("Tool %s failed: %s", tool_name, exc)
        return {"error": str(exc)}


def _tool_whoami():
    """Return the Lambda's own AWS identity and attached IAM policies."""
    sts = boto3.client("sts")
    iam = boto3.client("iam")

    identity = sts.get_caller_identity()
    arn = identity["Arn"]
    result = {
        "account_id": identity["Account"],
        "arn": arn,
        "user_id": identity["UserId"],
    }

    # Extract role name from assumed-role or role ARN
    if ":assumed-role/" in arn:
        role_name = arn.split(":assumed-role/")[1].split("/")[0]
    elif ":role/" in arn:
        role_name = arn.split(":role/")[1]
    else:
        return result

    result["role_name"] = role_name
    try:
        attached = iam.list_attached_role_policies(RoleName=role_name)
        result["attached_policies"] = [
            {"name": p["PolicyName"], "arn": p["PolicyArn"]}
            for p in attached.get("AttachedPolicies", [])
        ]
        inline = iam.list_role_policies(RoleName=role_name)
        result["inline_policies"] = inline.get("PolicyNames", [])
    except Exception as exc:
        result["policies_error"] = str(exc)

    return result


def _tool_query_iam_permissions(principal_arn, actions=None):
    """Look up IAM policies for a principal and optionally simulate specific actions.

    Accepts IAM user ARNs, role ARNs, and assumed-role session ARNs. Assumed-role
    ARNs are resolved to their underlying role for policy lookups.
    """
    iam = boto3.client("iam")

    # Normalise assumed-role session ARN → role ARN
    if ":assumed-role/" in principal_arn:
        account = principal_arn.split(":")[4]
        role_name = principal_arn.split(":assumed-role/")[1].split("/")[0]
        role_arn = f"arn:aws:iam::{account}:role/{role_name}"
        principal_type, principal_name, simulate_arn = "role", role_name, role_arn
    elif ":role/" in principal_arn:
        principal_type = "role"
        principal_name = principal_arn.split(":role/")[1]
        simulate_arn = principal_arn
    elif ":user/" in principal_arn:
        principal_type = "user"
        principal_name = principal_arn.split(":user/")[1]
        simulate_arn = principal_arn
    else:
        return {"error": f"Cannot determine principal type from ARN: {principal_arn}"}

    result = {
        "principal_arn": principal_arn,
        "principal_type": principal_type,
        "principal_name": principal_name,
    }

    try:
        if principal_type == "role":
            role = iam.get_role(RoleName=principal_name)["Role"]
            result["trust_principals"] = [
                s.get("Principal", {})
                for s in role.get("AssumeRolePolicyDocument", {}).get("Statement", [])
            ]
            result["attached_policies"] = [
                {"name": p["PolicyName"], "arn": p["PolicyArn"]}
                for p in iam.list_attached_role_policies(
                    RoleName=principal_name
                ).get("AttachedPolicies", [])
            ]
            result["inline_policies"] = iam.list_role_policies(
                RoleName=principal_name
            ).get("PolicyNames", [])

        elif principal_type == "user":
            iam.get_user(UserName=principal_name)  # verify existence
            result["attached_policies"] = [
                {"name": p["PolicyName"], "arn": p["PolicyArn"]}
                for p in iam.list_attached_user_policies(
                    UserName=principal_name
                ).get("AttachedPolicies", [])
            ]
            result["inline_policies"] = iam.list_user_policies(
                UserName=principal_name
            ).get("PolicyNames", [])
            result["groups"] = [
                g["GroupName"]
                for g in iam.list_groups_for_user(
                    UserName=principal_name
                ).get("Groups", [])
            ]
    except Exception as exc:
        result["lookup_error"] = str(exc)

    if actions:
        try:
            simulation = iam.simulate_principal_policy(
                PolicySourceArn=simulate_arn,
                ActionNames=actions[:20],  # API max is higher but keep responses concise
            )
            result["simulated_actions"] = [
                {
                    "action": r["EvalActionName"],
                    "decision": r["EvalDecision"],
                }
                for r in simulation.get("EvaluationResults", [])
            ]
        except Exception as exc:
            result["simulation_error"] = str(exc)

    return result


def _extract_summary_description(prompt):
    """Extract summary and description from the structured prompt text."""
    summary = ""
    description = ""
    try:
        if "Summary:\n" in prompt:
            after_summary = prompt.split("Summary:\n", 1)[1]
            summary = after_summary.split("\n\n", 1)[0].strip()
        if "Description:\n" in prompt:
            after_desc = prompt.split("Description:\n", 1)[1]
            description = after_desc.split("\n\nComment history", 1)[0].strip()
    except (IndexError, ValueError):
        pass
    return summary, description


def _devin_backend(prompt, ticket_key, api_key):
    logger.info("Creating Devin session for %s", ticket_key)
    full_prompt = f"{EFFECTIVE_SYSTEM_PROMPT}\n\n{prompt}" if EFFECTIVE_SYSTEM_PROMPT else prompt
    session = _create_devin_session(full_prompt, api_key)
    session_id = session["session_id"]
    logger.info("Devin session %s created for %s", session_id, ticket_key)

    response_text = _poll_devin_session(session_id, api_key)
    if response_text:
        return response_text

    raise TimeoutError(
        f"Devin session {session_id} did not complete within {DEVIN_MAX_WAIT}s for {ticket_key}"
    )


# -- Secrets -------------------------------------------------------------------


def _fetch_secrets():
    sm = boto3.client("secretsmanager")
    atlassian_pat = sm.get_secret_value(SecretId=ATLASSIAN_SECRET_ID)["SecretString"].strip()

    result = {"atlassian_pat": atlassian_pat}

    if AI_BACKEND == "devin":
        result["devin_api_key"] = sm.get_secret_value(SecretId=DEVIN_SECRET_ID)["SecretString"].strip()

    return result


# -- Atlassian -----------------------------------------------------------------


def _extract_ticket_key(payload):
    key = payload.get("issue", {}).get("key")
    if not key:
        raise ValueError(f"No issue.key in webhook payload: {payload}")
    return key


def _fetch_issue(ticket_key, pat):
    fields = "summary,description,priority,status,assignee,reporter,labels,components,comment,issuetype,issuelinks"
    url = f"{ATLASSIAN_BASE_URL}/rest/api/2/issue/{ticket_key}?fields={fields}"
    return _atlassian_request("GET", url, pat)


def _post_comment(ticket_key, comment_text, pat, reply_context=None):
    url = f"{ATLASSIAN_BASE_URL}/rest/api/2/issue/{ticket_key}/comment"
    parts = ["*[archbot]*"]
    if reply_context:
        author = _user_display(reply_context.get("author", "someone"))
        quote_body = _body_to_text(reply_context.get("body", ""))
        parts.append(f"{{quote}}{author} wrote:\n{quote_body}{{quote}}")
    parts.append(comment_text)
    body = {"body": "\n\n".join(parts)}
    _atlassian_request("POST", url, pat, body=body)


def _atlassian_request(method, url, pat, body=None):
    credentials = base64.b64encode(f"{ATLASSIAN_EMAIL}:{pat}".encode()).decode()
    headers = {
        "Authorization": f"Basic {credentials}",
        "Content-Type": "application/json",
        "Accept": "application/json",
    }
    data = json.dumps(body).encode() if body else None
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as exc:
        body_text = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"Atlassian {method} {url} -> {exc.code}: {body_text}") from exc


# -- Prompt building -----------------------------------------------------------

BOT_PREFIX = "*[archbot]*"


def _body_to_text(body):
    """Normalise a Jira comment/description body to a plain string.

    Jira Cloud's v2 REST API sometimes returns bodies as Atlassian Document
    Format (ADF) dicts instead of wiki-markup strings - particularly for
    comments authored via the rich-text editor. This function handles both.
    """
    if isinstance(body, str):
        return body
    if isinstance(body, dict):
        return _extract_adf_text(body) or ""
    return str(body) if body is not None else ""


def _extract_adf_text(node):
    """Recursively extract plain text from an ADF node tree.

    Handles common ADF node types from Jira Cloud's rich-text editor:
    - text: leaf node containing the actual string content
    - codeBlock: fenced code block (wrapped in triple-backtick markers)
    - mention: @-mention (extracted as display name)
    - hardBreak / rule: structural whitespace
    - Everything else: recurse into "content" children
    """
    if isinstance(node, str):
        return node
    if not isinstance(node, dict):
        return ""

    node_type = node.get("type")

    # Leaf: plain text
    if node_type == "text":
        return node.get("text") or ""

    # Leaf: @mention
    if node_type == "mention":
        return (node.get("attrs") or {}).get("text") or ""

    # Leaf: line break / horizontal rule
    if node_type in ("hardBreak", "rule"):
        return "\n"

    # Recurse into children (use "or []" because ADF nodes may have "content": null)
    parts = [_extract_adf_text(child) for child in (node.get("content") or [])]
    inner = "\n".join(p for p in parts if p)

    # Wrap code blocks so they survive as structured code in the prompt
    if node_type == "codeBlock":
        lang = (node.get("attrs") or {}).get("language") or ""
        fence = f"```{lang}" if lang else "```"
        return f"{fence}\n{inner}\n```"

    return inner


def _build_ticket_context(ticket, event_type):
    """Structured ticket metadata for the opening user turn (no comments - those become turns)."""
    fields = ticket.get("fields", {})
    key = ticket.get("key", "UNKNOWN")
    summary = fields.get("summary", "(no summary)")
    description = _body_to_text(fields.get("description")) or "(no description provided)"
    priority = _nested(fields, "priority", "name", default="Unknown")
    status = _nested(fields, "status", "name", default="Unknown")
    issue_type = _nested(fields, "issuetype", "name", default="Unknown")
    assignee = _user_detail(fields.get("assignee"))
    reporter = _user_detail(fields.get("reporter"))
    labels = ", ".join(fields.get("labels", [])) or "none"
    components = ", ".join(c.get("name", "") for c in fields.get("components", [])) or "none"
    links = fields.get("issuelinks", [])
    linked_text = "\n".join(f"- {_link_summary(link)}" for link in links[:10]) if links else "(none)"

    return f"""\
Event: {event_type}
Ticket: {key}
Type: {issue_type} | Priority: {priority} | Status: {status}
Reporter: {reporter} | Assignee: {assignee}
Labels: {labels} | Components: {components}

Summary:
{summary}

Description:
{description}

Linked issues:
{linked_text}
"""


def _extract_bot_response(body):
    """Strip the archbot marker and any reply quote from a bot comment body."""
    text = body.removeprefix(BOT_PREFIX).strip()
    # Strip leading {quote}...{quote} block added by _post_comment for reply context
    if text.startswith("{quote}") and "{quote}" in text[7:]:
        text = text[text.index("{quote}", 7) + 7:].strip()
    return text


def _build_messages(ticket, event_type, triggering_comment=None):
    """Build a multi-turn Bedrock Converse messages list from ticket history.

    The ticket metadata becomes the first user turn. Each Jira comment is then
    appended as either a user or assistant turn based on the *[archbot]* prefix.
    Consecutive same-role messages are merged - Bedrock requires strict alternation.

    If triggering_comment is provided, it is always appended as the final user
    turn. This guarantees the conversation ends with a user message even when
    the last comment in the Jira thread was filtered out (e.g. empty ADF body)
    or was a bot response.
    """
    messages = [{"role": "user", "content": [{"text": _build_ticket_context(ticket, event_type)}]}]

    comments = ticket.get("fields", {}).get("comment", {}).get("comments", [])

    # Exclude the triggering comment from history - it will be appended explicitly below
    triggering_body = _body_to_text((triggering_comment or {}).get("body", "")).strip()
    history_comments = comments
    if triggering_comment and triggering_body:
        # Trim the last matching comment from history so it isn't duplicated
        for i in range(len(comments) - 1, -1, -1):
            if _body_to_text(comments[i].get("body", "")).strip() == triggering_body:
                history_comments = comments[:i] + comments[i + 1:]
                break

    for comment in history_comments:
        body = _body_to_text(comment.get("body", "")).strip()
        if not body:
            continue
        author = _user_display(comment.get("author"))

        if body.startswith(BOT_PREFIX):
            role = "assistant"
            text = _extract_bot_response(body)
        else:
            role = "user"
            text = f"{author}:\n{body}"

        if not text:
            continue

        if messages[-1]["role"] == role:
            messages[-1]["content"][0]["text"] += f"\n\n{text}"
        else:
            messages.append({"role": role, "content": [{"text": text}]})

    # Always end with the triggering comment as a user turn (Bedrock requires last=user)
    if triggering_body and not triggering_body.startswith(BOT_PREFIX):
        author = _user_display((triggering_comment or {}).get("author"))
        final_text = f"{author}:\n{triggering_body}"
        if messages[-1]["role"] == "user":
            messages[-1]["content"][0]["text"] += f"\n\n{final_text}"
        else:
            messages.append({"role": "user", "content": [{"text": final_text}]})

    # Safety net: Bedrock requires the final message to have role=user.
    # This catches edge cases where the triggering comment body could not be
    # extracted (e.g. unsupported ADF structure) and the last history entry
    # was from the bot.
    if messages[-1]["role"] != "user":
        author = _user_display((triggering_comment or {}).get("author"))
        messages.append({"role": "user", "content": [
            {"text": f"{author} added a comment (content could not be extracted)."}
        ]})

    return messages


def _build_prompt(ticket, event_type="issue_created"):
    fields = ticket.get("fields", {})
    key = ticket.get("key", "UNKNOWN")
    summary = fields.get("summary", "(no summary)")
    description = _body_to_text(fields.get("description")) or "(no description provided)"
    priority = _nested(fields, "priority", "name", default="Unknown")
    status = _nested(fields, "status", "name", default="Unknown")
    issue_type = _nested(fields, "issuetype", "name", default="Unknown")
    assignee = _user_display(fields.get("assignee"))
    reporter = _user_display(fields.get("reporter"))
    labels = ", ".join(fields.get("labels", [])) or "none"
    components = ", ".join(c.get("name", "") for c in fields.get("components", [])) or "none"

    # Comments - up to 20 most recent, oldest first
    all_comments = fields.get("comment", {}).get("comments", [])
    comments_slice = all_comments[-20:] if len(all_comments) > 20 else all_comments
    if comments_slice:
        comments_text = "\n---\n".join(
            f"[{c.get('created', '')[:16]}] {_user_display(c.get('author'))}: {_body_to_text(c.get('body', ''))}"
            for c in comments_slice
        )
    else:
        comments_text = "(no comments yet)"

    # Linked issues - up to 10
    links = fields.get("issuelinks", [])
    if links:
        linked_text = "\n".join(f"- {_link_summary(link)}" for link in links[:10])
    else:
        linked_text = "(none)"

    return f"""\
Event: {event_type}
Ticket: {key}
Type: {issue_type} | Priority: {priority} | Status: {status}
Reporter: {reporter} | Assignee: {assignee}
Labels: {labels} | Components: {components}

Summary:
{summary}

Description:
{description}

Comment history (oldest first):
{comments_text}

Linked issues:
{linked_text}
"""


def _user_display(user):
    if not user:
        return "Unassigned"
    if isinstance(user, str):
        return user
    return user.get("displayName") or user.get("emailAddress") or "Unknown"


def _user_detail(user):
    """Return 'Display Name (email@example.com)' for richer tool-calling context."""
    if not user:
        return "Unassigned"
    if isinstance(user, str):
        return user
    name = user.get("displayName") or "Unknown"
    email = user.get("emailAddress", "")
    return f"{name} ({email})" if email else name


def _nested(obj, *keys, default=None):
    cur = obj
    for k in keys:
        if not isinstance(cur, dict):
            return default
        cur = cur.get(k)
    return cur if cur is not None else default


def _link_summary(link):
    if link.get("outwardIssue"):
        issue = link["outwardIssue"]
        rel = _nested(link, "type", "outward", default="relates to")
    elif link.get("inwardIssue"):
        issue = link["inwardIssue"]
        rel = _nested(link, "type", "inward", default="relates to")
    else:
        return "(unknown link)"
    issue_key = issue.get("key", "?")
    issue_summary = _nested(issue, "fields", "summary", default="")
    return f"{issue_key} ({rel}): {issue_summary}"


# -- Devin ---------------------------------------------------------------------


def _create_devin_session(prompt, api_key):
    return _devin_request("POST", f"{DEVIN_API_BASE}/sessions", api_key, body={"prompt": prompt})


def _poll_devin_session(session_id, api_key):
    url = f"{DEVIN_API_BASE}/sessions/{session_id}"
    elapsed = 0

    while elapsed < DEVIN_MAX_WAIT:
        session = _devin_request("GET", url, api_key)
        status = session.get("status", "")
        logger.info(
            "Devin session %s status=%s elapsed=%ds", session_id, status, elapsed
        )

        if status and status.lower() not in DEVIN_ACTIVE_STATUSES:
            return _extract_devin_response(session, session_id, api_key)

        time.sleep(DEVIN_POLL_INTERVAL)
        elapsed += DEVIN_POLL_INTERVAL

    return None


def _extract_devin_response(session, session_id, api_key):
    # Try the messages endpoint first - most reliable source for Devin's final output
    try:
        messages_url = f"{DEVIN_API_BASE}/sessions/{session_id}/messages"
        messages = _devin_request("GET", messages_url, api_key)
        if isinstance(messages, list) and messages:
            devin_msgs = [m for m in messages if m.get("role", "").lower() != "user"]
            if devin_msgs:
                last = devin_msgs[-1]
                content = last.get("content") or last.get("text") or last.get("message")
                if content:
                    return str(content)
    except Exception as exc:
        logger.warning("Could not fetch session messages for %s: %s", session_id, exc)

    # Fall back to fields directly on the session object
    for field in ("output", "structured_output", "result", "text", "final_message", "summary"):
        val = session.get(field)
        if val:
            return str(val)

    # Last resort - link to the session so a human can review
    session_url = session.get("url") or f"https://app.devin.ai/sessions/{session_id}"
    status = session.get("status", "unknown")
    return f"Devin session completed with status '{status}'. Review the session for details: {session_url}"


def _devin_request(method, url, api_key, body=None):
    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json",
        "Accept": "application/json",
    }
    data = json.dumps(body).encode() if body else None
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as exc:
        body_text = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"Devin {method} {url} -> {exc.code}: {body_text}") from exc
