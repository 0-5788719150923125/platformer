"""Shared AI backend for archbot.

Reusable Bedrock Converse loop, KB retrieval, tool execution, and prompt
composition logic consumed by both the Atlassian Lambda and the Discord bot.
"""

import json
import logging
import os

import boto3

logger = logging.getLogger(__name__)

# ── Environment helpers ──────────────────────────────────────────────────────


def load_env():
    """Load common environment variables into a config dict."""
    return {
        "ai_backend": os.environ.get("AI_BACKEND", "bedrock"),
        "bedrock_model_id": os.environ.get("BEDROCK_MODEL_ID", "us.anthropic.claude-haiku-4-5-20251001-v1:0"),
        "bedrock_max_tokens": int(os.environ.get("BEDROCK_MAX_TOKENS", "512")),
        "bedrock_temperature": float(os.environ.get("BEDROCK_TEMPERATURE", "0.3")),
        "debug": os.environ.get("DEBUG_MODE", "false").lower() == "true",
        "deny_list": json.loads(os.environ.get("DENY_LIST", "[]")),
        "response_rate": float(os.environ.get("RESPONSE_RATE", "0.25")),
        "knowledge_base_id": os.environ.get("KNOWLEDGE_BASE_ID", ""),
        "kb_max_results": int(os.environ.get("KB_MAX_RESULTS", "5")),
    }


def load_system_prompt():
    """Load system prompt from SSM parameter or environment variable."""
    ssm_param = os.environ.get("SYSTEM_PROMPT_PARAM")
    if ssm_param:
        ssm = boto3.client("ssm", region_name=os.environ.get("AWS_REGION", "us-east-2"))
        return ssm.get_parameter(Name=ssm_param)["Parameter"]["Value"]
    return os.environ.get("SYSTEM_PROMPT", "")


# ── System prompt composition ────────────────────────────────────────────────


def compose_system_prompt(base, deny_list):
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


# ── Constants ────────────────────────────────────────────────────────────────

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


# ── Message sanitization ─────────────────────────────────────────────────────


def sanitize_messages(messages, context_id):
    """Remove messages with empty content and re-merge any consecutive same-role
    messages that result from the removal. Logs every skipped message so the
    root cause can be traced in CloudWatch without crashing the invocation.
    """
    clean = []
    for i, msg in enumerate(messages):
        role = msg.get("role", "unknown")
        content = msg.get("content") or []

        # Filter out content blocks that have no usable text.
        valid = [
            block for block in content
            if "text" not in block or (block.get("text") or "").strip()
        ]

        if not valid:
            logger.warning(
                "Dropping messages[%d] with empty content (role=%s) for %s",
                i, role, context_id,
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
        context_id, len(messages), len(clean),
    )
    return clean


# ── Bedrock Converse loop ────────────────────────────────────────────────────


def bedrock_converse(messages, context_id, system_text="", model_id=None,
                     max_tokens=None, temperature=None, tools=None):
    """Run the Bedrock Converse API with optional tool-calling loop.

    Returns the final text response from the model.
    """
    env = load_env()
    model_id = model_id or env["bedrock_model_id"]
    max_tokens = max_tokens or env["bedrock_max_tokens"]
    temperature = temperature if temperature is not None else env["bedrock_temperature"]
    tools = tools if tools is not None else TOOL_DEFINITIONS

    client = boto3.client("bedrock-runtime")
    kwargs = {}
    if tools:
        kwargs["toolConfig"] = {"tools": tools, "toolChoice": {"auto": {}}}
    if system_text:
        kwargs["system"] = [{"text": system_text}]

    current_messages = sanitize_messages(list(messages), context_id)
    output_message = None

    logger.info(
        "Converse payload for %s: %d messages: %s",
        context_id,
        len(current_messages),
        [(i, m["role"], len(m.get("content", [])),
          len((m.get("content") or [{}])[0].get("text", "") or ""))
         for i, m in enumerate(current_messages)],
    )

    for iteration in range(MAX_TOOL_ITERATIONS):
        response = client.converse(
            modelId=model_id,
            messages=current_messages,
            inferenceConfig={"maxTokens": max_tokens, "temperature": temperature},
            **kwargs,
        )
        stop_reason = response["stopReason"]
        output_message = response["output"]["message"]

        if stop_reason == "end_turn":
            text = output_message["content"][0]["text"]
            logger.info(
                "Bedrock response for %s: %d chars, %d turns, %d tool iterations (model=%s)",
                context_id, len(text), len(current_messages), iteration, model_id,
            )
            return text

        if stop_reason != "tool_use":
            logger.warning("Unexpected stopReason for %s: %s", context_id, stop_reason)
            break

        # Execute all tool calls returned in this turn.
        current_messages.append({"role": "assistant", "content": output_message["content"]})
        tool_results = []
        for block in output_message["content"]:
            if "toolUse" not in block:
                continue
            tool_use = block["toolUse"]
            tool_name = tool_use["name"]
            tool_input = tool_use.get("input", {})
            logger.info("Tool call [%s]: %s(%s)", context_id, tool_name, tool_input)
            result = execute_tool(tool_name, tool_input)
            tool_results.append({
                "toolResult": {
                    "toolUseId": tool_use["toolUseId"],
                    "content": [{"text": json.dumps(result, indent=2)}],
                }
            })
        if tool_results:
            current_messages.append({"role": "user", "content": tool_results})

    # Fell out of the loop - extract any text from the last response
    logger.warning("Tool loop exhausted for %s after %d iterations", context_id, MAX_TOOL_ITERATIONS)
    if output_message:
        for block in output_message.get("content", []):
            if "text" in block:
                return block["text"]
    return "I was unable to complete the analysis within the allowed number of steps."


# ── Knowledge Base retrieval ─────────────────────────────────────────────────


def retrieve_kb_context(query_summary, query_detail, knowledge_base_id=None, max_results=None):
    """Retrieve relevant document chunks from Bedrock Knowledge Base.

    Returns a formatted string of retrieved chunks, or empty string on failure.
    """
    env = load_env()
    knowledge_base_id = knowledge_base_id or env["knowledge_base_id"]
    max_results = max_results or env["kb_max_results"]

    if not knowledge_base_id:
        return ""

    description_excerpt = (query_detail or "")[:500]
    query = f"{query_summary}\n{description_excerpt}".strip()
    if not query:
        return ""

    try:
        client = boto3.client("bedrock-agent-runtime")
        response = client.retrieve(
            knowledgeBaseId=knowledge_base_id,
            retrievalQuery={"text": query},
            retrievalConfiguration={
                "vectorSearchConfiguration": {
                    "numberOfResults": max_results
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
            len(chunks), knowledge_base_id, query[:80],
        )
        return f"Relevant knowledge base context:\n{context}"

    except Exception as exc:
        logger.warning("KB retrieval failed (non-fatal): %s", exc)
        return ""


# ── Tool execution ───────────────────────────────────────────────────────────


def execute_tool(tool_name, tool_input):
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
    """Return the caller's own AWS identity and attached IAM policies."""
    sts = boto3.client("sts")
    iam = boto3.client("iam")

    identity = sts.get_caller_identity()
    arn = identity["Arn"]
    result = {
        "account_id": identity["Account"],
        "arn": arn,
        "user_id": identity["UserId"],
    }

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
    """Look up IAM policies for a principal and optionally simulate specific actions."""
    iam = boto3.client("iam")

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
            iam.get_user(UserName=principal_name)
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
                ActionNames=actions[:20],
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
