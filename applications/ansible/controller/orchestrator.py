#!/usr/bin/env python3
"""
Ansible Controller Orchestrator

Reads a manifest.json describing playbook entries, queries EC2 and SSM to build
inventories of reachable instances, and runs ansible-playbook for each entry
using the aws_ssm connection plugin.

Usage:
    python orchestrator.py --manifest manifest.json --playbooks-dir ansible-playbooks
"""

import argparse
import base64
import json
import os
import subprocess
import sys
import tempfile

import boto3
import yaml


def load_manifest(path):
    """Load and validate the manifest file."""
    with open(path) as f:
        manifest = json.load(f)
    required = ["region", "ssm_bucket", "namespace", "entries"]
    for key in required:
        if key not in manifest:
            print(f"ERROR: manifest missing required key: {key}", file=sys.stderr)
            sys.exit(1)
    return manifest


def get_ssm_online_instances(region):
    """Query SSM for all online managed instances.

    Returns a dict of {instance_id: platform_type} where platform_type
    is 'Linux' or 'Windows' (from SSM's PlatformType field).
    """
    ssm = boto3.client("ssm", region_name=region)
    online = {}
    paginator = ssm.get_paginator("describe_instance_information")
    for page in paginator.paginate(
        Filters=[{"Key": "PingStatus", "Values": ["Online"]}]
    ):
        for info in page["InstanceInformationList"]:
            online[info["InstanceId"]] = info.get("PlatformType", "Linux")
    return online


def get_ec2_instances(region, filters):
    """Query EC2 for running instances matching filters. Returns list of instance IDs."""
    ec2 = boto3.client("ec2", region_name=region)
    ec2_filters = [{"Name": "instance-state-name", "Values": ["running"]}]
    for key, values in filters.items():
        ec2_filters.append({"Name": key, "Values": values})

    instance_ids = []
    paginator = ec2.get_paginator("describe_instances")
    for page in paginator.paginate(Filters=ec2_filters):
        for reservation in page["Reservations"]:
            for instance in reservation["Instances"]:
                instance_ids.append(instance["InstanceId"])
    return instance_ids


def build_ec2_filters(targeting):
    """Convert targeting config to EC2 API filters."""
    mode = targeting.get("mode", "compute")
    filters = {}

    if mode == "compute":
        tag_key = targeting.get("tag_key", "Class")
        class_val = targeting.get("class")
        tenant = targeting.get("tenant")
        if class_val:
            filters[f"tag:{tag_key}"] = [class_val]
        if tenant:
            filters["tag:Tenant"] = [tenant]

    elif mode == "tags":
        tags = targeting.get("tags") or {}
        for tag_name, tag_values in tags.items():
            filters[f"tag:{tag_name}"] = tag_values

    # wildcard mode: no additional filters (all running instances)
    return filters


def generate_inventory(entry, manifest, work_dir):
    """Build a static inventory of SSM-reachable instances.

    1. Query EC2 for instances matching targeting filters
    2. Query SSM for online managed instances (with platform type)
    3. Intersect  -  only include instances that are both running AND SSM-connected
    4. Write a static YAML inventory with 'linux' and 'windows' groups
    """
    targeting = entry["targeting"]
    region = manifest["region"]
    ssm_bucket = manifest["ssm_bucket"]

    # Get SSM-connected instances (dict of {id: platform_type})
    ssm_online = get_ssm_online_instances(region)

    if targeting.get("mode") == "cluster":
        # Cluster mode (mode: 1-master): all nodes pre-listed with per-node host_vars.
        # Build a multi-host inventory so Ansible runs every node in parallel via forks.
        # All nodes must be SSM-reachable; a missing node aborts the whole cluster run
        # to avoid a partial deployment that leaves the cluster in an inconsistent state.
        cluster_hosts = targeting.get("hosts") or []
        linux_hosts = {}
        for h in cluster_hosts:
            iid = h["instance_id"]
            if iid not in ssm_online:
                print(f"  Cluster node {iid} not connected to SSM  -  aborting cluster run")
                return None, 0
            host_vars = {
                "ansible_host": iid,
                "ansible_connection": "aws_ssm",
                "ansible_aws_ssm_bucket_name": ssm_bucket,
                "ansible_aws_ssm_region": region,
            }
            host_vars.update(h.get("vars") or {})
            linux_hosts[iid] = host_vars

        print(f"  Cluster: {len(linux_hosts)} node(s)")

        inventory = {
            "all": {
                "children": {
                    "linux": {"hosts": linux_hosts},
                    "windows": {"hosts": {}},
                }
            }
        }
        inventory_path = os.path.join(work_dir, f"{entry['name']}_inventory.yml")
        with open(inventory_path, "w") as f:
            yaml.dump(inventory, f, default_flow_style=False)
        return inventory_path, len(linux_hosts)

    elif targeting.get("mode") == "instance":
        # Direct instance targeting (ImageBuilder builds)
        # Skip EC2 discovery  -  target a specific instance by ID
        instance_id = targeting["instance_id"]
        if instance_id not in ssm_online:
            print(f"  Instance {instance_id} not connected to SSM")
            return None, 0
        ec2_instances = [instance_id]
        reachable = [instance_id]
        print(f"  Direct instance: {instance_id} ({ssm_online[instance_id]})")
    else:
        # Get EC2 instances matching targeting filters
        ec2_filters = build_ec2_filters(targeting)
        ec2_instances = get_ec2_instances(region, ec2_filters)

        # Intersect: only target instances that are both running and SSM-connected
        reachable = [iid for iid in ec2_instances if iid in ssm_online]
        skipped = [iid for iid in ec2_instances if iid not in ssm_online]

        if skipped:
            print(f"  Skipping {len(skipped)} instance(s) not connected to SSM: {', '.join(skipped)}")

    if not reachable:
        print(f"  No reachable instances found (EC2: {len(ec2_instances)}, SSM online: {len(ssm_online)})")
        return None, 0

    # Separate by platform
    linux_hosts = {}
    windows_hosts = {}
    for iid in reachable:
        host_vars = {
            "ansible_host": iid,
            "ansible_connection": "aws_ssm",
            "ansible_aws_ssm_bucket_name": ssm_bucket,
            "ansible_aws_ssm_region": region,
        }
        if ssm_online[iid] == "Windows":
            host_vars["ansible_aws_ssm_is_windows"] = True
            host_vars["ansible_shell_type"] = "powershell"
            windows_hosts[iid] = host_vars
        else:
            linux_hosts[iid] = host_vars

    linux_count = len(linux_hosts)
    windows_count = len(windows_hosts)
    print(f"  Discovered {len(reachable)} reachable instance(s) "
          f"(of {len(ec2_instances)} EC2 matches): "
          f"{linux_count} Linux, {windows_count} Windows")

    # Build inventory with platform groups
    inventory = {
        "all": {
            "children": {
                "linux": {"hosts": linux_hosts} if linux_hosts else {},
                "windows": {"hosts": windows_hosts} if windows_hosts else {},
            },
        }
    }

    inventory_name = f"{entry['name']}_inventory.yml"
    inventory_path = os.path.join(work_dir, inventory_name)
    with open(inventory_path, "w") as f:
        yaml.dump(inventory, f, default_flow_style=False)

    return inventory_path, len(reachable)


def build_extra_vars(entry):
    """Build extra vars string from entry params."""
    params = entry.get("params", {})
    if not params:
        return None
    return json.dumps(params)


def run_playbook(entry, manifest, playbooks_dir, work_dir):
    """Run a single playbook entry. Returns (success: bool, hosts_found: bool)."""
    name = entry["name"]
    playbook_file = entry["playbook_file"]
    timeout = entry.get("timeout_seconds", 600)
    severity = entry.get("compliance_severity", "HIGH")

    playbook_path = os.path.join(playbooks_dir, playbook_file)
    if not os.path.exists(playbook_path):
        print(f"ERROR: Playbook not found: {playbook_path}", file=sys.stderr)
        return False, False

    print(f"\n{'='*60}")
    print(f"Running playbook: {name}")
    print(f"  File: {playbook_file}")
    print(f"  Timeout: {timeout}s")
    print(f"  Severity: {severity}")

    # Generate static inventory (pre-filtered to SSM-connected instances)
    inventory_path, host_count = generate_inventory(entry, manifest, work_dir)

    if inventory_path is None:
        print(f"\nPlaybook {name}: SKIPPED (no reachable hosts)")
        print(f"{'='*60}")
        return True, False

    print(f"  Inventory: {inventory_path}")
    print(f"{'='*60}\n")

    # Build ansible-playbook command
    cmd = [
        "ansible-playbook",
        "-i", inventory_path,
        playbook_path,
    ]

    extra_vars = build_extra_vars(entry)
    if extra_vars:
        cmd.extend(["-e", extra_vars])

    # Set environment for the callback plugin
    env = os.environ.copy()
    env["COMPLIANCE_SEVERITY"] = severity
    env["CODEBUILD_BUILD_ID"] = os.environ.get("CODEBUILD_BUILD_ID", "local")
    env["PLAYBOOK_NAME"] = name
    env["SSM_BUCKET"] = manifest["ssm_bucket"]
    env["AWS_REGION"] = manifest["region"]

    # Resolve callback plugin path from script location to avoid CWD ambiguity
    script_dir = os.path.dirname(os.path.abspath(__file__))
    env["ANSIBLE_CALLBACK_PLUGINS"] = os.path.join(script_dir, "callback_plugins")
    env["ANSIBLE_CALLBACKS_ENABLED"] = "ssm_compliance"

    try:
        result = subprocess.run(
            cmd,
            env=env,
            timeout=timeout,
            capture_output=False,
        )

        if result.returncode == 0:
            print(f"\nPlaybook {name}: SUCCESS")
            return True, True
        else:
            print(f"\nPlaybook {name}: FAILED (exit code {result.returncode})")
            return False, True

    except subprocess.TimeoutExpired:
        print(f"\nPlaybook {name}: TIMEOUT after {timeout}s", file=sys.stderr)
        return False, True


def main():
    parser = argparse.ArgumentParser(description="Ansible Controller Orchestrator")
    parser.add_argument("--manifest", required=True, help="Path to manifest.json")
    parser.add_argument("--playbooks-dir", required=True, help="Path to playbooks directory")
    args = parser.parse_args()

    manifest = load_manifest(args.manifest)

    # ImageBuilder direct-instance mode: run a single playbook against a specific instance
    imagebuilder_instance = os.environ.get("IMAGEBUILDER_INSTANCE_ID")
    if imagebuilder_instance:
        playbook = os.environ.get("IMAGEBUILDER_PLAYBOOK")
        if not playbook:
            print("ERROR: IMAGEBUILDER_PLAYBOOK required with IMAGEBUILDER_INSTANCE_ID", file=sys.stderr)
            sys.exit(1)
        params_raw = os.environ.get("IMAGEBUILDER_PARAMS", "")
        params = json.loads(base64.b64decode(params_raw)) if params_raw else {}
        entries = [{
            "name": f"imagebuilder-{playbook.split('/')[0]}",
            "playbook_file": playbook,
            "targeting": {
                "mode": "instance",
                "instance_id": imagebuilder_instance,
            },
            "params": params,
            "timeout_seconds": 1800,
        }]
        print(f"ImageBuilder mode: targeting instance {imagebuilder_instance}")
        print(f"  Playbook: {playbook}")
    else:
        entries = manifest.get("entries", [])

    if not entries:
        print("No playbook entries in manifest. Nothing to do.")
        sys.exit(0)

    print(f"Ansible Controller Orchestrator")
    print(f"  Region: {manifest['region']}")
    print(f"  Namespace: {manifest['namespace']}")
    print(f"  Entries: {len(entries)}")
    print(f"  S3 Bucket: {manifest['ssm_bucket']}")

    work_dir = tempfile.mkdtemp(prefix="ansible-controller-")
    results = []

    for entry in entries:
        success, hosts_found = run_playbook(
            entry, manifest, args.playbooks_dir, work_dir
        )
        results.append({
            "name": entry["name"],
            "success": success,
            "hosts_found": hosts_found,
        })

    # Summary
    print(f"\n{'='*60}")
    print("SUMMARY")
    print(f"{'='*60}")
    failed = []
    for r in results:
        status = "OK" if r["success"] else "FAILED"
        hosts = "hosts found" if r["hosts_found"] else "no hosts"
        print(f"  {r['name']}: {status} ({hosts})")
        if not r["success"]:
            failed.append(r["name"])

    if failed:
        print(f"\n{len(failed)} playbook(s) failed: {', '.join(failed)}")
        sys.exit(1)
    else:
        print(f"\nAll {len(results)} playbook(s) succeeded.")
        sys.exit(0)


if __name__ == "__main__":
    main()
