"""
Lambda function to automatically tag EC2 instances based on SSM inventory data.

This function queries SSM for managed instances matching platform criteria (OS name and version),
then applies EC2 tags to those instances. These tags are used by Resource Groups to automatically
populate maintenance window targets.

Environment Variables:
    PLATFORM_NAME: OS name or glob pattern to filter (e.g., "Rocky Linux", "*Windows*")
    PLATFORM_VERSION: OS version prefix to filter (e.g., "9" matches 9.0, 9.1, 9.6, etc.)
    TAG_KEY: EC2 tag key to apply (e.g., "Patch Group")
    TAG_VALUE: EC2 tag value to apply (e.g., "rocky9-dynamic-puzlledome")
    MAX_INSTANCES: Maximum instances to tag per run (optional, default: unlimited)
        Enables controlled rollout by limiting patching to N instances at a time
        Uses consistent hashing for stable selection with minimal churn
        Adding/removing 1 instance only affects ~1 instance in selection (vs all N with random sampling)
    APPLICATION_FILTERS: JSON-encoded application filter config (optional)
        Example: {"exclude_patterns": ["*redis*"], "include_patterns": []}
"""

import boto3
import os
import json
import fnmatch
import hashlib
from typing import List, Dict, Optional

ssm = boto3.client('ssm')
ec2 = boto3.client('ec2')


def lambda_handler(event, context):
    """Main Lambda handler function."""

    # Get configuration from environment variables
    platform_name = os.environ['PLATFORM_NAME']
    platform_version = os.environ['PLATFORM_VERSION']
    tag_key = os.environ['TAG_KEY']
    tag_value = os.environ['TAG_VALUE']
    max_instances = int(os.environ.get('MAX_INSTANCES', '0'))  # 0 = unlimited

    print(f"Querying SSM for instances: PlatformName={platform_name}, PlatformVersion starts with {platform_version}")
    print(f"Will apply tag: {tag_key}={tag_value}")
    if max_instances > 0:
        print(f"Instance limit: {max_instances} (controlled rollout mode)")

    # Load application filters (optional)
    application_filters = load_application_filters()
    if application_filters:
        print(f"Application filtering enabled:")
        if application_filters.get('exclude_patterns'):
            print(f"  Exclude patterns: {application_filters['exclude_patterns']}")
        if application_filters.get('include_patterns'):
            print(f"  Include patterns: {application_filters['include_patterns']}")

    try:
        # Query SSM for managed instances matching platform criteria
        instance_ids = query_ssm_instances(platform_name, platform_version)

        if not instance_ids:
            print("WARNING: No instances found matching criteria. No tags will be applied.")
            return {
                'statusCode': 200,
                'body': json.dumps({
                    'instance_count': 0,
                    'instances': [],
                    'message': 'No matching instances found'
                })
            }

        print(f"Found {len(instance_ids)} platform-matching instances: {instance_ids}")

        # Apply application filtering if configured
        if application_filters:
            instance_ids = filter_by_applications(instance_ids, application_filters)

            if not instance_ids:
                print("WARNING: No instances passed application filtering. No tags will be applied.")
                return {
                    'statusCode': 200,
                    'body': json.dumps({
                        'instance_count': 0,
                        'instances': [],
                        'message': 'No instances passed application filtering'
                    })
                }

            print(f"After application filtering: {len(instance_ids)} instances remain")

        # Apply instance limit if configured (controlled rollout)
        # Use consistent hashing for stable selection with minimal churn
        # Compute hash for each instance, sort by hash, take top N
        # This ensures adding/removing instances only affects ~1 instance in the selection
        if max_instances > 0 and len(instance_ids) > max_instances:
            original_count = len(instance_ids)
            instance_ids = select_instances_consistent_hash(instance_ids, max_instances)
            print(f"Applied instance limit: {original_count} candidates -> {len(instance_ids)} selected")
            print(f"Selected instances (consistent hashing): {instance_ids}")

        # Get currently tagged instances to handle removals
        currently_tagged = get_currently_tagged_instances(tag_key, tag_value)

        # Determine which instances need tags added/removed
        to_add = set(instance_ids) - set(currently_tagged)
        to_remove = set(currently_tagged) - set(instance_ids)

        if to_remove:
            print(f"Removing tags from {len(to_remove)} instances that no longer match: {list(to_remove)}")
            remove_tags_from_instances(list(to_remove), tag_key)

        if to_add:
            print(f"Adding tags to {len(to_add)} new matching instances: {list(to_add)}")
            tag_instances(list(to_add), tag_key, tag_value)

        if not to_add and not to_remove:
            print(f"No changes needed - {len(instance_ids)} instances already correctly tagged")

        return {
            'statusCode': 200,
            'body': json.dumps({
                'instance_count': len(instance_ids),
                'instances': instance_ids,
                'tag_applied': f"{tag_key}={tag_value}",
                'application_filtering_enabled': application_filters is not None,
                'max_instances_limit': max_instances if max_instances > 0 else None,
                'tags_added': len(to_add),
                'tags_removed': len(to_remove)
            })
        }

    except Exception as e:
        print(f"ERROR: {str(e)}")
        raise


def query_ssm_instances(platform_name: str, platform_version: str) -> List[str]:
    """
    Query SSM for managed instances matching platform criteria.

    Args:
        platform_name: OS name or pattern (e.g., "Rocky Linux", "*Windows*")
        platform_version: OS version prefix (e.g., "9")

    Returns:
        List of instance IDs
    """
    instance_ids = []
    next_token = None

    # Determine platform type filter based on platform name pattern
    # If pattern contains "Windows" (case-insensitive), use Windows type, otherwise Linux
    platform_type = 'Windows' if 'windows' in platform_name.lower() else 'Linux'

    while True:
        # Build describe-instance-information request
        params = {
            'MaxResults': 50,  # AWS API limit
            'Filters': [
                {
                    'Key': 'PingStatus',
                    'Values': ['Online']  # Only target instances that are currently online
                },
                {
                    'Key': 'PlatformTypes',
                    'Values': [platform_type]  # Filter by detected platform type
                }
            ]
        }

        if next_token:
            params['NextToken'] = next_token

        # Query SSM
        response = ssm.describe_instance_information(**params)

        # Filter results by platform name and version (client-side filtering)
        # SSM API doesn't support direct PlatformName/PlatformVersion filtering
        for instance in response.get('InstanceInformationList', []):
            # Check platform name (supports wildcards: exact match OR glob pattern)
            inst_platform = instance.get('PlatformName', '')
            if not fnmatch.fnmatch(inst_platform, platform_name):
                continue

            # Check platform version (prefix match)
            inst_version = instance.get('PlatformVersion', '')
            if platform_version and not inst_version.startswith(platform_version):
                continue

            instance_ids.append(instance['InstanceId'])

        # Check if there are more results
        next_token = response.get('NextToken')
        if not next_token:
            break

    return instance_ids


def tag_instances(instance_ids: List[str], tag_key: str, tag_value: str):
    """
    Apply EC2 tags to instances.

    Args:
        instance_ids: List of instance IDs to tag
        tag_key: Tag key to apply
        tag_value: Tag value to apply
    """
    # EC2 CreateTags has a limit of 1000 resources per call, so we're safe with typical deployments
    # If needed, we can batch this in chunks of 1000

    response = ec2.create_tags(
        Resources=instance_ids,
        Tags=[
            {
                'Key': tag_key,
                'Value': tag_value
            }
        ]
    )

    print(f"Successfully tagged {len(instance_ids)} instances with {tag_key}={tag_value}")
    print(f"Response: {json.dumps(response, default=str)}")


def get_currently_tagged_instances(tag_key: str, tag_value: str) -> List[str]:
    """
    Query EC2 for instances that currently have the specified tag.

    Args:
        tag_key: Tag key to search for
        tag_value: Tag value to match

    Returns:
        List of instance IDs with the tag
    """
    instance_ids = []
    next_token = None

    while True:
        params = {
            'Filters': [
                {
                    'Name': f'tag:{tag_key}',
                    'Values': [tag_value]
                }
            ],
            'MaxResults': 1000
        }

        if next_token:
            params['NextToken'] = next_token

        response = ec2.describe_instances(**params)

        for reservation in response.get('Reservations', []):
            for instance in reservation.get('Instances', []):
                instance_ids.append(instance['InstanceId'])

        next_token = response.get('NextToken')
        if not next_token:
            break

    print(f"Found {len(instance_ids)} instances currently tagged with {tag_key}={tag_value}")
    return instance_ids


def remove_tags_from_instances(instance_ids: List[str], tag_key: str):
    """
    Remove EC2 tags from instances.

    Args:
        instance_ids: List of instance IDs to untag
        tag_key: Tag key to remove
    """
    if not instance_ids:
        return

    # EC2 DeleteTags has a limit of 1000 resources per call
    response = ec2.delete_tags(
        Resources=instance_ids,
        Tags=[
            {
                'Key': tag_key
            }
        ]
    )

    print(f"Successfully removed tag '{tag_key}' from {len(instance_ids)} instances")
    print(f"Response: {json.dumps(response, default=str)}")


def load_application_filters() -> Optional[Dict]:
    """
    Load and parse application filters from environment variable.

    Returns:
        Dict with 'exclude_patterns' and 'include_patterns' lists, or None if not configured
    """
    filters_json = os.environ.get('APPLICATION_FILTERS', '')
    if not filters_json:
        return None

    try:
        filters = json.loads(filters_json)
        # Validate structure and ensure at least one pattern is specified
        exclude_patterns = filters.get('exclude_patterns', [])
        include_patterns = filters.get('include_patterns', [])

        if not exclude_patterns and not include_patterns:
            print("WARNING: APPLICATION_FILTERS specified but no patterns defined, skipping application filtering")
            return None

        return {
            'exclude_patterns': exclude_patterns,
            'include_patterns': include_patterns
        }
    except json.JSONDecodeError as e:
        print(f"WARNING: Invalid APPLICATION_FILTERS JSON: {e}. Skipping application filtering.")
        return None


def filter_by_applications(instance_ids: List[str], filters: Dict) -> List[str]:
    """
    Filter instances based on installed applications from SSM inventory.

    IMPORTANT: Instances with no application inventory (0 apps or error) are EXCLUDED
    for safety. This ensures we only patch instances with known, validated inventory.

    Args:
        instance_ids: List of candidate instance IDs
        filters: Dict with 'exclude_patterns' and 'include_patterns' lists

    Returns:
        Filtered list of instance IDs
    """
    exclude_patterns = filters.get('exclude_patterns', [])
    include_patterns = filters.get('include_patterns', [])

    filtered_ids = []

    for instance_id in instance_ids:
        try:
            # Query SSM inventory for this instance's applications
            applications = get_instance_applications(instance_id)

            # CRITICAL: Exclude instances with no application inventory
            if not applications or len(applications) == 0:
                print(f"FILTERED OUT: {instance_id} - No application inventory data (safety exclusion)")
                continue

            print(f"Instance {instance_id}: Found {len(applications)} applications")

            # Apply filtering logic
            if should_include_instance(instance_id, applications, include_patterns, exclude_patterns):
                filtered_ids.append(instance_id)

        except Exception as e:
            # CRITICAL: Exclude instances on any error (fail-safe)
            print(f"FILTERED OUT: {instance_id} - Error querying inventory: {e}")
            continue

    print(f"Application filtering: {len(instance_ids)} candidates -> {len(filtered_ids)} matched")
    return filtered_ids


def get_instance_applications(instance_id: str) -> List[str]:
    """
    Query SSM inventory for installed applications on an instance.

    Args:
        instance_id: EC2 instance ID

    Returns:
        List of application names (lowercase for case-insensitive matching)
    """
    applications = []
    next_token = None

    while True:
        # Query SSM inventory for AWS:Application type
        params = {
            'InstanceId': instance_id,
            'TypeName': 'AWS:Application',
            'MaxResults': 50
        }

        if next_token:
            params['NextToken'] = next_token

        try:
            response = ssm.list_inventory_entries(**params)

            # Extract application names from inventory entries
            for entry in response.get('Entries', []):
                app_name = entry.get('Name', '')
                if app_name:
                    applications.append(app_name.lower())  # Lowercase for case-insensitive matching

            next_token = response.get('NextToken')
            if not next_token:
                break

        except ssm.exceptions.InvalidInstanceId:
            # Instance exists in SSM but has no inventory data yet
            print(f"WARNING: Instance {instance_id} has no inventory data")
            break
        except Exception as e:
            print(f"ERROR querying inventory for {instance_id}: {e}")
            raise

    return applications


def should_include_instance(
    instance_id: str,
    applications: List[str],
    include_patterns: List[str],
    exclude_patterns: List[str]
) -> bool:
    """
    Determine if instance should be included based on application filters.

    Logic:
    1. If exclude_patterns specified and any match -> EXCLUDE (exclude takes precedence)
    2. If include_patterns specified and none match -> EXCLUDE (whitelist mode)
    3. Otherwise -> INCLUDE

    Args:
        instance_id: Instance ID (for logging)
        applications: List of installed application names (lowercase)
        include_patterns: Whitelist patterns (if specified, only instances WITH these apps are included)
        exclude_patterns: Blacklist patterns (if any match, instance is excluded)

    Returns:
        True if instance should be included, False otherwise
    """
    # Convert patterns to lowercase for case-insensitive matching
    exclude_patterns_lower = [p.lower() for p in exclude_patterns]
    include_patterns_lower = [p.lower() for p in include_patterns]

    # Check exclude patterns first (takes precedence)
    for app in applications:
        for pattern in exclude_patterns_lower:
            if fnmatch.fnmatch(app, pattern):
                print(f"FILTERED OUT: {instance_id} - Application '{app}' matches exclude pattern '{pattern}'")
                return False

    # If include patterns specified, check if any application matches
    if include_patterns_lower:
        for app in applications:
            for pattern in include_patterns_lower:
                if fnmatch.fnmatch(app, pattern):
                    print(f"INCLUDED: {instance_id} - Application '{app}' matches include pattern '{pattern}'")
                    return True
        # No applications matched include patterns
        print(f"FILTERED OUT: {instance_id} - No applications match include patterns {include_patterns_lower}")
        return False

    # No filters matched, include by default
    print(f"INCLUDED: {instance_id} - Passed all filters")
    return True


def select_instances_consistent_hash(instance_ids: List[str], max_instances: int) -> List[str]:
    """
    Select instances using consistent hashing for minimal churn.

    Consistent hashing ensures that adding/removing instances only affects
    ~1 instance in the selection, rather than reshuffling the entire list.

    This is the same technique used by AWS ELB, Memcached clusters, and Kubernetes
    for stable resource allocation with minimal disruption.

    Algorithm:
    1. Compute deterministic hash for each instance ID
    2. Sort by hash value (creates stable ordering independent of input order)
    3. Select first N instances from sorted list

    Args:
        instance_ids: List of candidate instance IDs
        max_instances: Maximum number to select

    Returns:
        List of selected instance IDs (sorted alphabetically for readable logs)
    """
    # Compute stable hash for each instance
    # MD5 is sufficient here (not cryptographic use case, just need uniform distribution)
    instance_scores = [
        (hashlib.md5(inst_id.encode()).hexdigest(), inst_id)
        for inst_id in instance_ids
    ]

    # Sort by hash value (deterministic ordering)
    instance_scores.sort(key=lambda x: x[0])

    # Take first N instances by hash order
    selected_ids = [inst_id for _, inst_id in instance_scores[:max_instances]]

    # Sort selected IDs alphabetically for readable output (doesn't affect selection)
    selected_ids.sort()

    return selected_ids
