"""CodeBuild Event Reporter Lambda

Transforms CodeBuild EventBridge state change events into Port event bus format.

Environment variables:
    WEBHOOK_URL: Port webhook ingest URL
    NAMESPACE: Platformer namespace
    AWS_REGION_VAR: AWS region for console URLs
    SSO_START_URL: AWS SSO start URL
    ACCOUNT_ID: AWS account ID
"""

import json
import logging
import os
import urllib.parse
import urllib.request
from datetime import datetime

logger = logging.getLogger()
logger.setLevel(logging.INFO)


def build_console_url(project_name, build_id, region, sso_start_url, account_id):
    """Build SSO-wrapped AWS Console URL for CodeBuild project history."""
    console_url = (
        f"https://{region}.console.aws.amazon.com/codesuite/codebuild/"
        f"{account_id}/projects/{project_name}/history?region={region}"
    )
    sso_prefix = f"{sso_start_url}/#/console?account_id={account_id}&destination="
    return f"{sso_prefix}{urllib.parse.quote(console_url, safe='')}"


def map_build_status(status):
    """Map CodeBuild status to event bus status enum."""
    mapping = {
        "IN_PROGRESS": "IN_PROGRESS",
        "SUCCEEDED": "SUCCEEDED",
        "FAILED": "FAILED",
        "STOPPED": "STOPPED",
        "TIMED_OUT": "TIMED_OUT",
    }
    return mapping.get(status, status)


def handler(event, context):
    webhook_url = os.environ["WEBHOOK_URL"]
    namespace = os.environ["NAMESPACE"]
    region = os.environ["AWS_REGION_VAR"]
    sso_start_url = os.environ["SSO_START_URL"]
    account_id = os.environ["ACCOUNT_ID"]

    logger.info("Received CodeBuild event: %s", json.dumps(event))

    detail = event.get("detail", {})
    project_name = detail.get("project-name")
    build_id = detail.get("build-id")
    build_status = detail.get("build-status")

    # Extract build number from build_id (format: project-name:uuid)
    build_number = build_id.split(":")[-1][:8] if build_id else "unknown"

    # Calculate duration for completed builds
    duration = None
    start_time = detail.get("additional-information", {}).get("build-start-time")
    end_time = detail.get("additional-information", {}).get("build-end-time")
    if start_time and end_time:
        try:
            start = datetime.fromisoformat(start_time.replace("Z", "+00:00"))
            end = datetime.fromisoformat(end_time.replace("Z", "+00:00"))
            duration = int((end - start).total_seconds())
        except Exception as e:
            logger.warning("Failed to calculate duration: %s", e)

    # Build event payload for Port webhook
    event_id = f"codebuild-{project_name}-{build_number}-{namespace}"

    # Generate message based on status
    status_messages = {
        "IN_PROGRESS": f"Build started: {project_name}",
        "SUCCEEDED": f"Build succeeded: {project_name}",
        "FAILED": f"Build failed: {project_name}",
        "STOPPED": f"Build stopped: {project_name}",
        "TIMED_OUT": f"Build timed out: {project_name}",
    }
    message = status_messages.get(build_status, f"Build {build_status.lower()}: {project_name}")

    payload = {
        "event_id": event_id,
        "event_type": "codebuild",
        "source": "configuration-management",
        "status": map_build_status(build_status),
        "message": message,
        "timestamp": event.get("time", datetime.utcnow().isoformat() + "Z"),
        "resource_id": build_id,
        "resource_name": project_name,
        "aws_url": build_console_url(project_name, build_id, region, sso_start_url, account_id),
        "duration": duration,
        "details": json.dumps({
            "initiator": detail.get("additional-information", {}).get("initiator"),
            "build_number": build_number,
            "source_version": detail.get("additional-information", {}).get("source-version"),
        }, indent=2),
        "error_message": detail.get("additional-information", {}).get("build-error-message"),
        "triggered_by": "schedule",
        "namespace": namespace,
    }

    # POST to webhook
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        webhook_url,
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )

    try:
        with urllib.request.urlopen(req) as resp:
            logger.info("Posted event to webhook: %s (HTTP %d)", event_id, resp.status)
            return {"statusCode": 200, "body": f"Posted event: {event_id}"}
    except Exception as e:
        logger.exception("Failed to post to webhook")
        raise
