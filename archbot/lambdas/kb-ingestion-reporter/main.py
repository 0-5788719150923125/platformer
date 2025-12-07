"""KB Ingestion Reporter Lambda

Starts a Bedrock Knowledge Base ingestion job, polls until completion,
and reports lifecycle events to a Port.io event bus webhook.

Environment variables:
    WEBHOOK_URL: Port webhook ingest URL (empty string to skip reporting)
    NAMESPACE: Platformer namespace
    AWS_REGION_VAR: AWS region for API calls
"""

import json
import logging
import os
import time
import urllib.request
from datetime import datetime, timezone

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

POLL_INTERVAL = 10  # seconds between get_ingestion_job calls
TERMINAL_STATUSES = {"COMPLETE", "FAILED", "STOPPED"}


def post_event(webhook_url, payload):
    """POST event payload to Port webhook. No-op if webhook_url is empty."""
    if not webhook_url:
        logger.info("No webhook URL configured - skipping event post")
        return

    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        webhook_url,
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )

    try:
        with urllib.request.urlopen(req) as resp:
            logger.info(
                "Posted event to webhook: %s (HTTP %d)",
                payload["event_id"],
                resp.status,
            )
    except Exception:
        logger.exception("Failed to post event to webhook (non-fatal)")


def build_event_payload(
    event_id, status, message, namespace, kb_id, job_id=None,
    duration=None, stats=None, error_message=None,
):
    """Build Port event bus payload matching the portal webhook JQ mapping."""
    payload = {
        "event_id": event_id,
        "event_type": "kb-ingestion",
        "source": "archbot",
        "status": status,
        "message": message,
        "timestamp": datetime.utcnow().isoformat() + "Z",
        "resource_id": job_id or "pending",
        "resource_name": kb_id,
        "aws_url": None,
        "duration": duration,
        "details": json.dumps(stats, indent=2) if stats else None,
        "error_message": error_message,
        "triggered_by": "terraform-apply",
        "namespace": namespace,
    }
    return payload


def handler(event, context):
    webhook_url = os.environ.get("WEBHOOK_URL", "")
    namespace = os.environ.get("NAMESPACE", "unknown")
    region = os.environ.get("AWS_REGION_VAR", os.environ.get("AWS_REGION", "us-east-1"))

    kb_id = event["knowledge_base_id"]
    ds_id = event["data_source_id"]

    logger.info("Starting KB ingestion: kb=%s ds=%s", kb_id, ds_id)

    client = boto3.client("bedrock-agent", region_name=region)

    # -- Start ingestion job --
    start_time = time.monotonic()
    resp = client.start_ingestion_job(
        knowledgeBaseId=kb_id,
        dataSourceId=ds_id,
    )
    job_id = resp["ingestionJob"]["ingestionJobId"]
    logger.info("Ingestion job started: %s", job_id)

    # Event IDs include job_id so every run produces unique entities
    event_id = f"kb-ingestion-{kb_id[:8]}-{job_id[:8]}-{namespace}"

    # -- Post STARTED event (after job start so we have the job_id) --
    post_event(webhook_url, build_event_payload(
        event_id=f"{event_id}-started",
        status="STARTED",
        message=f"KB ingestion started: {kb_id}",
        namespace=namespace,
        kb_id=kb_id,
        job_id=job_id,
    ))

    # -- Poll until terminal --
    while True:
        time.sleep(POLL_INTERVAL)

        status_resp = client.get_ingestion_job(
            knowledgeBaseId=kb_id,
            dataSourceId=ds_id,
            ingestionJobId=job_id,
        )
        job = status_resp["ingestionJob"]
        status = job["status"]
        logger.info("Ingestion job %s status: %s", job_id, status)

        if status in TERMINAL_STATUSES:
            break

    duration = int(time.monotonic() - start_time)

    # -- Extract stats --
    statistics = job.get("statistics", {})
    stats = {
        "documents_scanned": statistics.get("numberOfDocumentsScanned", 0),
        "documents_indexed": statistics.get("numberOfNewDocumentsIndexed", 0)
                           + statistics.get("numberOfModifiedDocumentsIndexed", 0),
        "documents_failed": statistics.get("numberOfDocumentsFailed", 0),
        "documents_deleted": statistics.get("numberOfDocumentsDeleted", 0),
        "ingestion_job_id": job_id,
    }

    if status == "COMPLETE":
        post_event(webhook_url, build_event_payload(
            event_id=event_id,
            status="SUCCEEDED",
            message=f"KB ingestion complete: {stats['documents_indexed']} indexed, {stats['documents_failed']} failed",
            namespace=namespace,
            kb_id=kb_id,
            job_id=job_id,
            duration=duration,
            stats=stats,
        ))
        logger.info("Ingestion succeeded in %ds: %s", duration, json.dumps(stats))
        return {"statusCode": 200, "body": json.dumps(stats)}

    # FAILED or STOPPED
    failure_reasons = job.get("failureReasons", [])
    error_msg = "; ".join(failure_reasons) if failure_reasons else f"Ingestion ended with status: {status}"

    post_event(webhook_url, build_event_payload(
        event_id=event_id,
        status="FAILED",
        message=f"KB ingestion failed: {error_msg[:100]}",
        namespace=namespace,
        kb_id=kb_id,
        job_id=job_id,
        duration=duration,
        stats=stats,
        error_message=error_msg,
    ))
    logger.error("Ingestion failed in %ds: %s", duration, error_msg)
    raise RuntimeError(f"KB ingestion failed: {error_msg}")
