#!/usr/bin/env python3
"""
Port Action Handler - Executes commands on EC2 instances via AWS SSM
and streams logs back to Port in real-time.

All handlers run asynchronously in background threads. The webhook endpoint
returns 200 immediately, and logs/status are streamed to Port via the API.

Supports dispatch modes:
1. "run_command" - Direct SSM command execution on an instance (original)
2. Registry commands - Dispatched from commands.json:
   - ssm_trigger_and_collect: triggers an SSM association, polls, collects output
   - cli_exec: executes CLI commands (kubectl, helm, etc.) and streams output
   - lambda_invoke: invokes a Lambda function asynchronously (Event type)
"""
import os
import sys
import time
import json
import subprocess
import threading
import requests
import boto3
from flask import Flask, request, jsonify

app = Flask(__name__)

# Configuration from environment
PORT_CLIENT_ID = os.getenv('PORT_CLIENT_ID')
PORT_CLIENT_SECRET = os.getenv('PORT_CLIENT_SECRET')
PORT_BASE_URL = os.getenv('PORT_BASE_URL', 'https://api.us.getport.io')
AWS_REGION = os.getenv('AWS_REGION', 'us-east-2')
AWS_PROFILE = os.getenv('AWS_PROFILE', 'default')
NAMESPACE = os.getenv('NAMESPACE', 'unknown')

# Load command registry (merge per-workspace files from commands.d/)
COMMANDS = []
_commands_dir = '/app/commands.d'
if os.path.isdir(_commands_dir):
    import glob
    for cmd_file in sorted(glob.glob(os.path.join(_commands_dir, '*.json'))):
        with open(cmd_file) as f:
            data = json.load(f)
            COMMANDS.extend(data)
            print(f"Loaded {len(data)} commands from {os.path.basename(cmd_file)}", file=sys.stderr)
    print(f"Total: {len(COMMANDS)} commands from registry", file=sys.stderr)
else:
    print(f"No commands.d/ directory found at {_commands_dir}, registry actions disabled", file=sys.stderr)

# Global Port access token cache (with lock for thread safety)
_port_token = None
_port_token_expiry = 0
_token_lock = threading.Lock()


def get_port_token():
    """Get or refresh Port API access token (thread-safe)."""
    global _port_token, _port_token_expiry

    with _token_lock:
        # Return cached token if still valid
        if _port_token and time.time() < _port_token_expiry:
            return _port_token

        # Request new token
        response = requests.post(
            f"{PORT_BASE_URL}/v1/auth/access_token",
            json={
                "clientId": PORT_CLIENT_ID,
                "clientSecret": PORT_CLIENT_SECRET
            },
            timeout=10
        )
        response.raise_for_status()

        data = response.json()
        _port_token = data['accessToken']
        # Token expires in 1 hour, refresh 5 minutes early
        _port_token_expiry = time.time() + 3300

        return _port_token


def send_log_to_port(run_id, message, termination_status=None, status_label=None):
    """Send a log message to Port action run."""
    token = get_port_token()

    payload = {"message": message}
    if termination_status:
        payload["terminationStatus"] = termination_status
    if status_label:
        payload["statusLabel"] = status_label

    response = requests.post(
        f"{PORT_BASE_URL}/v1/actions/runs/{run_id}/logs",
        headers={"Authorization": f"Bearer {token}"},
        json=payload,
        timeout=10
    )

    if response.status_code not in (200, 201):
        print(f"Warning: Failed to send log to Port: {response.status_code} - {response.text}", file=sys.stderr)


def run_async(fn, *args):
    """Run a handler function in a background thread."""
    thread = threading.Thread(target=fn, args=args, daemon=True)
    thread.start()


# ============================================================
# Handler: run_command (direct SSM command execution)
# ============================================================

def handle_run_command(payload, run_id):
    """Handle the original run_command action (direct SSM command execution)."""
    try:
        entity = payload.get('payload', {}).get('entity', {})
        entity_id = entity.get('identifier', '')
        entity_props = entity.get('properties', {})

        action_inputs = payload.get('payload', {}).get('properties', {})
        command = action_inputs.get('command', 'echo "hello world"')

        send_log_to_port(run_id, f"Action triggered on entity: {entity_id}")
        send_log_to_port(run_id, f"Namespace: {NAMESPACE}")

        # Validate entity type
        entity_type = entity_props.get('type')
        if entity_type != 'ec2':
            send_log_to_port(
                run_id,
                f"Unsupported entity type: {entity_type}. Only EC2 instances are supported.",
                termination_status="FAILURE",
                status_label="Unsupported entity type"
            )
            return

        # Get instance ID from entity properties (preferred) or extract from URL (fallback)
        instance_id = entity_props.get('instanceId')

        if not instance_id:
            # Fallback: parse from AWS Console URL
            aws_url = entity_props.get('awsUrl', '')
            if 'instanceId=' in aws_url:
                instance_id = aws_url.split('instanceId=')[1].split('&')[0]

        if not instance_id:
            send_log_to_port(
                run_id,
                f"Could not extract instance ID from entity properties",
                termination_status="FAILURE",
                status_label="Invalid entity configuration"
            )
            return

        send_log_to_port(run_id, f"Target instance: {instance_id}")
        send_log_to_port(run_id, f"Command: {command}")
        send_log_to_port(run_id, "")

        execute_command_on_instance(instance_id, command, run_id)

    except Exception as e:
        error_msg = str(e)
        print(f"Error in handle_run_command: {error_msg}", file=sys.stderr)
        send_log_to_port(
            run_id,
            f"Internal error: {error_msg}",
            termination_status="FAILURE",
            status_label="Internal error"
        )


def execute_command_on_instance(instance_id, command, run_id):
    """Execute a command on an EC2 instance using AWS SSM and stream logs to Port."""
    try:
        session = boto3.Session(profile_name=AWS_PROFILE, region_name=AWS_REGION)
        ssm = session.client('ssm')

        send_log_to_port(run_id, f"Connected to AWS SSM in region {AWS_REGION}")

        response = ssm.send_command(
            InstanceIds=[instance_id],
            DocumentName='AWS-RunShellScript',
            Parameters={'commands': [command]},
            TimeoutSeconds=30
        )

        command_id = response['Command']['CommandId']
        send_log_to_port(run_id, f"Command sent (ID: {command_id})")
        send_log_to_port(run_id, "Waiting for command to complete...")

        max_attempts = 15
        for attempt in range(max_attempts):
            time.sleep(2)

            try:
                result = ssm.get_command_invocation(
                    CommandId=command_id,
                    InstanceId=instance_id
                )

                status = result['Status']

                if status == 'InProgress':
                    send_log_to_port(run_id, f"Command still running (attempt {attempt + 1}/{max_attempts})...")
                    continue

                if status == 'Success':
                    send_log_to_port(run_id, "")
                    send_log_to_port(run_id, "Command output:")
                    send_log_to_port(run_id, "-" * 50)

                    stdout = result.get('StandardOutputContent', '').strip()
                    if stdout:
                        for line in stdout.split('\n'):
                            send_log_to_port(run_id, line)
                    else:
                        send_log_to_port(run_id, "(no output)")

                    send_log_to_port(run_id, "-" * 50)
                    send_log_to_port(
                        run_id,
                        "Command completed successfully",
                        termination_status="SUCCESS",
                        status_label="Completed"
                    )
                    return

                elif status == 'Failed':
                    send_log_to_port(run_id, "")
                    send_log_to_port(run_id, "Command failed:")
                    send_log_to_port(run_id, "-" * 50)

                    stderr = result.get('StandardErrorContent', '').strip()
                    if stderr:
                        for line in stderr.split('\n'):
                            send_log_to_port(run_id, line)
                    else:
                        send_log_to_port(run_id, "(no error output)")

                    send_log_to_port(run_id, "-" * 50)
                    send_log_to_port(
                        run_id,
                        f"Command failed with status: {status}",
                        termination_status="FAILURE",
                        status_label="Command failed"
                    )
                    return

                else:
                    send_log_to_port(
                        run_id,
                        f"Command ended with unexpected status: {status}",
                        termination_status="FAILURE",
                        status_label=f"Unexpected status: {status}"
                    )
                    return

            except ssm.exceptions.InvocationDoesNotExist:
                send_log_to_port(run_id, f"Command invocation not ready yet (attempt {attempt + 1}/{max_attempts})...")
                continue

        send_log_to_port(
            run_id,
            "Timeout waiting for command to complete",
            termination_status="FAILURE",
            status_label="Command timeout"
        )

    except Exception as e:
        error_msg = str(e)
        send_log_to_port(run_id, f"Error executing command: {error_msg}")
        send_log_to_port(
            run_id,
            "Failed to execute command",
            termination_status="FAILURE",
            status_label=f"Error: {error_msg}"
        )


# ============================================================
# Handler: registry commands (commands.json dispatch)
# ============================================================

def handle_registry_command(payload, action_category, run_id):
    """Handle commands from the command registry (commands.json)."""
    try:
        entity = payload.get('payload', {}).get('entity', {})
        entity_id = entity.get('identifier', '')
        entity_props = entity.get('properties', {}) if isinstance(entity, dict) else {}
        entity_class = entity_props.get('class', '')
        entity_tenant = entity_props.get('tenant', '')

        action_inputs = payload.get('payload', {}).get('properties', {})
        target = action_inputs.get('target', '') or entity_class

        send_log_to_port(run_id, f"Registry action: {action_category}")
        send_log_to_port(run_id, f"Namespace: {NAMESPACE}")
        send_log_to_port(run_id, f"Entity: {entity_id} (class={entity_class}, tenant={entity_tenant})")

        # Find matching command: category + target + tenant (if present in action_config)
        matching = [
            c for c in COMMANDS
            if c['category'] == action_category
            and (c['target'] == target or c['target'] == entity_class or not target)
            and (not c.get('action_config', {}).get('tenant')
                 or c['action_config']['tenant'] == entity_tenant)
        ]

        if not matching:
            send_log_to_port(
                run_id,
                f"No command found for category={action_category}, target={target}",
                termination_status="FAILURE",
                status_label="No matching command"
            )
            return

        cmd = matching[0]
        action_type = cmd.get('action_config', {}).get('type', '')

        send_log_to_port(run_id, f"Matched command: {cmd['title']}")
        send_log_to_port(run_id, f"Action type: {action_type}")
        send_log_to_port(run_id, "")

        region = cmd.get('action_config', {}).get('region', AWS_REGION)
        session = boto3.Session(profile_name=AWS_PROFILE, region_name=region)
        ssm = session.client('ssm')

        if action_type == 'ssm_trigger_and_collect':
            association_id = cmd['action_config']['association_id']
            ssm_trigger_and_collect(ssm, association_id, run_id)
        elif action_type == 'cli_exec':
            cli_exec(cmd, run_id)
        elif action_type == 'state_taint':
            state_taint(cmd, entity, run_id)
        elif action_type == 'lambda_invoke':
            lambda_invoke(cmd, run_id)
        else:
            send_log_to_port(
                run_id,
                f"Unknown action type: {action_type}",
                termination_status="FAILURE",
                status_label=f"Unknown action type: {action_type}"
            )

    except Exception as e:
        error_msg = str(e)
        print(f"Error in handle_registry_command: {error_msg}", file=sys.stderr)
        send_log_to_port(run_id, f"Error: {error_msg}")
        send_log_to_port(
            run_id,
            f"Failed to execute action",
            termination_status="FAILURE",
            status_label=f"Error: {error_msg}"
        )


def ssm_trigger_and_collect(ssm, association_id, run_id, max_poll=30, poll_interval=5):
    """
    Trigger an SSM association and collect execution results.

    Workflow:
    1. Record timestamp, then call start_associations_once
    2. Poll describe_association_executions until a new execution appears (CreatedTime > timestamp)
    3. Wait for execution to reach a terminal status (Success/Failed/TimedOut)
    4. Collect per-instance results via describe_association_execution_targets
    5. For RunCommand-backed executions, fetch stdout/stderr via get_command_invocation
    """
    from datetime import datetime, timezone

    # Step 1: Record time and trigger
    trigger_time = datetime.now(timezone.utc)
    send_log_to_port(run_id, f"Triggering SSM association: {association_id}")

    ssm.start_associations_once(AssociationIds=[association_id])
    send_log_to_port(run_id, "Association triggered, waiting for execution to start...")

    # Step 2: Poll for new execution
    execution_id = None
    execution_status = None
    for attempt in range(max_poll):
        time.sleep(poll_interval)

        response = ssm.describe_association_executions(
            AssociationId=association_id,
            Filters=[{
                'Key': 'CreatedTime',
                'Value': trigger_time.strftime('%Y-%m-%dT%H:%M:%SZ'),
                'Type': 'GREATER_THAN'
            }],
            MaxResults=1
        )

        executions = response.get('AssociationExecutions', [])
        if not executions:
            send_log_to_port(run_id, f"Waiting for execution to appear (attempt {attempt + 1}/{max_poll})...")
            continue

        exec_info = executions[0]
        execution_id = exec_info.get('ExecutionId')
        execution_status = exec_info.get('Status', '')
        detail = exec_info.get('DetailedStatus', '')

        send_log_to_port(run_id, f"Execution {execution_id}: {execution_status} {detail}")

        # Terminal states
        if execution_status in ('Success', 'Failed', 'TimedOut'):
            break

        send_log_to_port(run_id, f"Execution in progress (attempt {attempt + 1}/{max_poll})...")

    if not execution_id:
        send_log_to_port(
            run_id,
            "Timed out waiting for execution to appear",
            termination_status="FAILURE",
            status_label="Execution timeout"
        )
        return

    # Step 3: Collect per-instance results
    send_log_to_port(run_id, "")
    send_log_to_port(run_id, "Per-instance results:")
    send_log_to_port(run_id, "-" * 50)

    targets_response = ssm.describe_association_execution_targets(
        AssociationId=association_id,
        ExecutionId=execution_id
    )

    targets = targets_response.get('AssociationExecutionTargets', [])
    overall_success = True

    for target in targets:
        resource_id = target.get('ResourceId', 'unknown')
        target_status = target.get('Status', 'Unknown')
        detail = target.get('DetailedStatus', '')
        output_source = target.get('OutputSource', {})

        status_icon = "OK" if target_status == 'Success' else "FAIL"
        send_log_to_port(run_id, f"  [{status_icon}] {resource_id}: {target_status} {detail}")

        if target_status != 'Success':
            overall_success = False

        # Step 4: If backed by RunCommand, fetch stdout/stderr
        source_type = output_source.get('OutputSourceType', '')
        source_id = output_source.get('OutputSourceId', '')

        if source_type == 'RunCommand' and source_id:
            # OutputSourceId format: "<command_id>:<instance_id>" or just "<command_id>"
            command_id = source_id.split(':')[0] if ':' in source_id else source_id
            try:
                invocation = ssm.get_command_invocation(
                    CommandId=command_id,
                    InstanceId=resource_id
                )
                stdout = invocation.get('StandardOutputContent', '').strip()
                stderr = invocation.get('StandardErrorContent', '').strip()

                if stdout:
                    send_log_to_port(run_id, f"    stdout:")
                    for line in stdout.split('\n')[:50]:  # Cap at 50 lines
                        send_log_to_port(run_id, f"      {line}")
                if stderr:
                    send_log_to_port(run_id, f"    stderr:")
                    for line in stderr.split('\n')[:20]:
                        send_log_to_port(run_id, f"      {line}")
            except Exception as e:
                send_log_to_port(run_id, f"    (could not fetch command output: {e})")

    send_log_to_port(run_id, "-" * 50)

    if overall_success:
        send_log_to_port(
            run_id,
            f"All targets completed successfully",
            termination_status="SUCCESS",
            status_label="Completed"
        )
    else:
        send_log_to_port(
            run_id,
            f"One or more targets failed (execution: {execution_status})",
            termination_status="FAILURE",
            status_label=f"Execution {execution_status}"
        )


# ============================================================
# Handler: cli_exec (kubectl, helm, etc.)
# ============================================================

def cli_exec(cmd, run_id):
    """
    Execute CLI commands from the registry and stream output to Port.

    Runs each non-comment command string via shell subprocess, streaming
    stdout and stderr line-by-line to Port logs. Used for kubectl, helm,
    and other CLI tools installed in the container.
    """
    commands = cmd.get('commands', [])
    # Filter out comment lines (for terminal display only)
    executable = [c for c in commands if c.strip() and not c.strip().startswith('#')]

    if not executable:
        send_log_to_port(
            run_id,
            "No executable commands found in registry entry",
            termination_status="FAILURE",
            status_label="No commands"
        )
        return

    # Build environment with AWS profile for credential helpers
    env = os.environ.copy()
    env['AWS_PROFILE'] = AWS_PROFILE
    env['AWS_REGION'] = AWS_REGION

    overall_success = True
    for command_str in executable:
        send_log_to_port(run_id, f"$ {command_str}")

        try:
            # Execute command and capture output
            result = subprocess.run(
                command_str,
                shell=True,
                capture_output=True,
                text=True,
                env=env,
                timeout=30
            )

            # Log stdout
            if result.stdout:
                for line in result.stdout.rstrip('\n').split('\n'):
                    if line:
                        send_log_to_port(run_id, line)

            # Handle errors or warnings
            if result.returncode != 0:
                overall_success = False
                send_log_to_port(run_id, f"Command exited with code {result.returncode}")
                if result.stderr:
                    for line in result.stderr.rstrip('\n').split('\n')[:30]:
                        if line:
                            send_log_to_port(run_id, f"  stderr: {line}")
            elif result.stderr:
                # Some tools write informational output to stderr (e.g., kubectl warnings)
                for line in result.stderr.rstrip('\n').split('\n')[:10]:
                    if line:
                        send_log_to_port(run_id, f"  {line}")

        except Exception as e:
            overall_success = False
            send_log_to_port(run_id, f"Failed to execute command: {e}")

        send_log_to_port(run_id, "")

    if overall_success:
        send_log_to_port(
            run_id,
            "All commands completed successfully",
            termination_status="SUCCESS",
            status_label="Completed"
        )
    else:
        send_log_to_port(
            run_id,
            "One or more commands failed",
            termination_status="FAILURE",
            status_label="Command failed"
        )


# ============================================================
# Handler: state_taint (Terraform state JSON mutation)
# ============================================================

# Lock protects concurrent writes to the state file
_state_lock = threading.Lock()

# Terraform state root directory (mounted via compose volume)
# Contains terraform.tfstate (default workspace) and
# terraform.tfstate.d/<workspace>/terraform.tfstate (named workspaces)
TERRAFORM_STATE_ROOT = os.getenv('TERRAFORM_STATE_ROOT', '/app/tfstate')


def _resolve_state_path(workspace):
    """
    Resolve the Terraform state file path for a given workspace.

    Default workspace: <root>/terraform.tfstate
    Named workspace:   <root>/terraform.tfstate.d/<workspace>/terraform.tfstate
    """
    if workspace == 'default' or not workspace:
        return os.path.join(TERRAFORM_STATE_ROOT, 'terraform.tfstate')
    return os.path.join(TERRAFORM_STATE_ROOT, 'terraform.tfstate.d', workspace, 'terraform.tfstate')


def _parse_resource_address(address):
    """
    Parse a Terraform resource address into its components.

    Example: module.compute[0].aws_instance.tenant["bravo-amazon-linux-0"]
    Returns: { module: "module.compute[0]", type: "aws_instance",
               name: "tenant", index_key: "bravo-amazon-linux-0" }
    """
    import re
    pattern = r'^(module\.\w+\[\d+\])\.(\w+)\.(\w+)\["([^"]+)"\]$'
    match = re.match(pattern, address)
    if not match:
        return None
    return {
        'module': match.group(1),
        'type': match.group(2),
        'name': match.group(3),
        'index_key': match.group(4),
    }


def _taint_resource_in_state(parts, address, state_path, run_id):
    """
    Find and taint a resource instance in the Terraform state file.

    Reads the state JSON, locates the matching resource by module/type/name/index_key,
    sets status="tainted", increments serial, and writes back atomically under lock.
    """
    with _state_lock:
        # Read state
        if not os.path.exists(state_path):
            send_log_to_port(
                run_id,
                f"State file not found: {state_path}",
                termination_status="FAILURE",
                status_label="State file missing"
            )
            return False

        with open(state_path, 'r') as f:
            state = json.load(f)

        # Navigate: resources live inside module children
        # State v4 structure: { resources: [...] } at top level,
        # or nested under modules for module-based resources
        target_module = parts['module']  # e.g. "module.compute[0]"
        target_type = parts['type']
        target_name = parts['name']
        target_key = parts['index_key']

        found = False
        for resource in state.get('resources', []):
            # Match module, type, and name
            res_module = resource.get('module', '')
            if res_module != target_module:
                continue
            if resource.get('type') != target_type:
                continue
            if resource.get('name') != target_name:
                continue

            # Find the specific instance by index_key
            for instance in resource.get('instances', []):
                if instance.get('index_key') == target_key:
                    instance['status'] = 'tainted'
                    found = True
                    send_log_to_port(run_id, f"Marked instance as tainted: {address}")
                    break

            if found:
                break

        if not found:
            send_log_to_port(
                run_id,
                f"Resource not found in state: {address}",
                termination_status="FAILURE",
                status_label="Resource not found"
            )
            return False

        # Increment serial
        state['serial'] = state.get('serial', 0) + 1

        # Write back
        with open(state_path, 'w') as f:
            json.dump(state, f, indent=2)

        send_log_to_port(run_id, f"State file updated (serial={state['serial']})")
        return True


def state_taint(cmd, entity, run_id):
    """
    Taint a Terraform resource by modifying the state file directly.

    Resolves the instance key from the entity title, builds the full resource
    address from the template in action_config, then mutates the state JSON.
    """
    try:
        action_config = cmd.get('action_config', {})
        template = action_config.get('resource_address_template', '')
        workspace = action_config.get('workspace', os.getenv('TERRAFORM_WORKSPACE', 'default'))

        # Resolve state file path from workspace
        state_path = _resolve_state_path(workspace)
        send_log_to_port(run_id, f"Workspace: {workspace}")
        send_log_to_port(run_id, f"State file: {state_path}")

        # Resolve instance key from entity title
        instance_key = entity.get('title', '')
        if not instance_key:
            send_log_to_port(
                run_id,
                "Cannot resolve instance key: entity has no title",
                termination_status="FAILURE",
                status_label="Missing entity title"
            )
            return

        address = template.replace('{{INSTANCE_KEY}}', instance_key)
        send_log_to_port(run_id, f"Target resource: {address}")

        # Parse the address into components
        parts = _parse_resource_address(address)
        if not parts:
            send_log_to_port(
                run_id,
                f"Failed to parse resource address: {address}",
                termination_status="FAILURE",
                status_label="Invalid address"
            )
            return

        send_log_to_port(run_id, f"Module: {parts['module']}")
        send_log_to_port(run_id, f"Resource: {parts['type']}.{parts['name']}")
        send_log_to_port(run_id, f"Instance key: {parts['index_key']}")
        send_log_to_port(run_id, "")

        # Perform the taint
        success = _taint_resource_in_state(parts, address, state_path, run_id)

        if success:
            send_log_to_port(run_id, "")
            send_log_to_port(run_id, "Instance marked for replacement.")
            send_log_to_port(run_id, "Run 'terraform apply' to destroy and recreate it.")
            send_log_to_port(
                run_id,
                "Taint applied successfully",
                termination_status="SUCCESS",
                status_label="Tainted"
            )

    except Exception as e:
        error_msg = str(e)
        print(f"Error in state_taint: {error_msg}", file=sys.stderr)
        send_log_to_port(run_id, f"Error: {error_msg}")
        send_log_to_port(
            run_id,
            f"Failed to taint resource",
            termination_status="FAILURE",
            status_label=f"Error: {error_msg}"
        )


# ============================================================
# Handler: lambda_invoke (async Lambda invocation)
# ============================================================

def lambda_invoke(cmd, run_id):
    """Invoke a Lambda function asynchronously and report invocation status."""
    action_config = cmd.get('action_config', {})
    function_name = action_config.get('function_name', '')
    region = action_config.get('region', AWS_REGION)

    # Build payload from action_config (exclude handler metadata keys)
    meta_keys = {'type', 'function_name', 'region', 'blueprint_type'}
    payload = {k: v for k, v in action_config.items() if k not in meta_keys}

    send_log_to_port(run_id, f"Invoking Lambda: {function_name}")
    send_log_to_port(run_id, f"Region: {region}")
    send_log_to_port(run_id, f"Payload: {json.dumps(payload, indent=2)}")

    session = boto3.Session(profile_name=AWS_PROFILE, region_name=region)
    lambda_client = session.client('lambda')

    # Invoke asynchronously (Event) - Lambda handles its own lifecycle reporting
    response = lambda_client.invoke(
        FunctionName=function_name,
        InvocationType='Event',
        Payload=json.dumps(payload).encode()
    )

    status_code = response.get('StatusCode', 0)
    if status_code == 202:
        send_log_to_port(run_id, "Lambda invoked successfully (async)")
        send_log_to_port(run_id, "Check the Event Bus widget for ingestion progress.")
        send_log_to_port(run_id, "Lambda accepted",
                         termination_status="SUCCESS", status_label="Invoked")
    else:
        send_log_to_port(run_id, f"Unexpected status code: {status_code}",
                         termination_status="FAILURE", status_label="Invocation failed")


# ============================================================
# Flask routes
# ============================================================

@app.route('/health', methods=['GET'])
def health():
    """Health check endpoint."""
    return jsonify({
        "status": "healthy",
        "namespace": NAMESPACE,
        "registry_commands": len(COMMANDS)
    })


@app.route('/webhook', methods=['POST'])
def webhook():
    """
    Webhook endpoint that receives action invocations from Port agent.

    Returns 200 immediately and processes the action asynchronously
    in a background thread. Logs and status are streamed to Port
    via the API as the action progresses.
    """
    try:
        payload = request.get_json()
        print(f"Received webhook: {json.dumps(payload, indent=2)}", file=sys.stderr)

        # Extract run ID
        run_id = payload.get('context', {}).get('runId')
        if not run_id:
            print("Error: No run ID in payload", file=sys.stderr)
            return jsonify({"error": "No run ID provided"}), 400

        # Determine action - check both top-level and context
        action = payload.get('action', payload.get('context', {}).get('action'))

        if action == 'run_command':
            run_async(handle_run_command, payload, run_id)
        else:
            run_async(handle_registry_command, payload, action, run_id)

        # Return immediately — all work happens in background thread
        return jsonify({"ok": True, "run_id": run_id}), 200

    except Exception as e:
        error_msg = str(e)
        print(f"Error processing webhook: {error_msg}", file=sys.stderr)
        return jsonify({"error": error_msg}), 500


if __name__ == '__main__':
    # Validate configuration
    if not PORT_CLIENT_ID or not PORT_CLIENT_SECRET:
        print("Error: PORT_CLIENT_ID and PORT_CLIENT_SECRET must be set", file=sys.stderr)
        sys.exit(1)

    print(f"Starting action handler for namespace: {NAMESPACE}", file=sys.stderr)
    print(f"Port API: {PORT_BASE_URL}", file=sys.stderr)
    print(f"AWS Region: {AWS_REGION}", file=sys.stderr)
    print(f"Command registry: {len(COMMANDS)} commands loaded", file=sys.stderr)

    # Run Flask app
    app.run(host='0.0.0.0', port=8080, debug=False)
