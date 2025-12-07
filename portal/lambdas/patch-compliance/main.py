"""Patch Compliance Reporter Lambda

Polls SSM patch states for each patch group and pushes compliance data
to Port.io via webhook for entity property updates.

Environment variables:
    WEBHOOK_URL:  Port webhook ingest URL
    PATCH_GROUPS: JSON list of patch group names to query
    NAMESPACE:    Platformer namespace (used to build entity identifiers)
"""

import json
import logging
import os
import urllib.request

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

ssm = boto3.client("ssm")
ec2 = boto3.client("ec2")


def resolve_instance_names(instance_ids):
    """Map EC2 instance IDs to their Name tags for entity identifier lookup."""
    if not instance_ids:
        return {}

    names = {}
    paginator = ec2.get_paginator("describe_instances")
    for page in paginator.paginate(InstanceIds=instance_ids):
        for reservation in page["Reservations"]:
            for instance in reservation["Instances"]:
                iid = instance["InstanceId"]
                for tag in instance.get("Tags", []):
                    if tag["Key"] == "Name":
                        names[iid] = tag["Value"]
                        break
    return names


def post_to_webhook(url, payload):
    """POST JSON payload to Port webhook endpoint."""
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req) as resp:
        return resp.status


def handler(event, context):
    webhook_url = os.environ["WEBHOOK_URL"]
    patch_groups = json.loads(os.environ["PATCH_GROUPS"])
    namespace = os.environ["NAMESPACE"]

    logger.info("Reporting compliance for patch groups: %s", patch_groups)

    all_states = []
    for pg in patch_groups:
        paginator = ssm.get_paginator(
            "describe_instance_patch_states_for_patch_group"
        )
        for page in paginator.paginate(PatchGroup=pg):
            all_states.extend(page.get("InstancePatchStates", []))

    if not all_states:
        logger.info("No patch states found for any patch group")
        return {"statusCode": 200, "body": "No patch states found"}

    # Resolve instance names for entity identifiers
    instance_ids = list({s["InstanceId"] for s in all_states})
    names = resolve_instance_names(instance_ids)

    reported = 0
    for state in all_states:
        iid = state["InstanceId"]
        name = names.get(iid)
        if not name:
            logger.warning("No Name tag for %s, skipping", iid)
            continue

        entity_identifier = name  # Name tag already includes namespace
        missing = state.get("MissingCount", 0)
        failed = state.get("FailedCount", 0)
        installed = state.get("InstalledCount", 0)

        compliance = "COMPLIANT" if (missing == 0 and failed == 0) else "NON_COMPLIANT"
        last_scan = state.get("OperationEndTime", "")
        if hasattr(last_scan, "isoformat"):
            last_scan = last_scan.isoformat()
        else:
            last_scan = str(last_scan)

        payload = {
            "entity_identifier": entity_identifier,
            "compliance_status": compliance,
            "installed_count": installed,
            "missing_count": missing,
            "last_scan_time": last_scan,
        }

        try:
            status = post_to_webhook(webhook_url, payload)
            logger.info("Reported %s -> %s (HTTP %d)", entity_identifier, compliance, status)
            reported += 1
        except Exception:
            logger.exception("Failed to report %s", entity_identifier)

    logger.info("Reported compliance for %d/%d instances", reported, len(all_states))
    return {"statusCode": 200, "body": f"Reported {reported} instances"}
