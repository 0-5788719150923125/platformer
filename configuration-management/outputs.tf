# Deployed documents with their schedules
output "documents" {
  description = "Deployed SSM documents and their association schedules"
  value = {
    for name, doc in local.enabled_documents : name => {
      document_name = aws_ssm_document.document[name].name
      # Only include association if it was created (has valid targets)
      association = contains(keys(local.enabled_associations), name) ? aws_ssm_association.document_association[name].association_name : null
      schedule    = local.association_configs[name].schedule_expression
      has_targets = contains(keys(local.enabled_associations), name)
    }
  }
}

# Application associations created from applications module requests
output "application_associations" {
  description = "Application associations created from applications module requests"
  value = {
    for idx, assoc in aws_ssm_association.applications :
    idx => {
      association_id = assoc.association_id
      name           = assoc.name
    }
  }
}

# Ansible controller (CodeBuild) project info
output "ansible_controller" {
  description = "Ansible controller CodeBuild project info"
  value = local.ansible_controller_enabled ? {
    project_name = aws_codebuild_project.ansible_controller[0].name
    project_arn  = aws_codebuild_project.ansible_controller[0].arn
    schedule     = aws_scheduler_schedule.ansible_controller[0].schedule_expression
  } : null
}

# Application scripts uploaded to S3
output "application_scripts_uploaded" {
  description = "Application scripts uploaded to S3 by configuration-management"
  value       = [for obj in aws_s3_object.application_scripts : obj.key]
}

# Ansible playbook files uploaded to S3 (includes all files from playbook directories)
output "ansible_playbooks_uploaded" {
  description = "Ansible playbook files uploaded to S3 by configuration-management"
  value       = [for obj in aws_s3_object.ansible_playbook_files : obj.key]
}

# Configuration summary
output "config" {
  description = "Configuration management service settings"
  value = {
    parameter_store_prefix = var.config.parameter_store_prefix
    instance_role          = var.config.existing_instance_role_name
    enabled_documents      = keys(local.enabled_documents)
    associations           = length(aws_ssm_association.document_association)
  }
}

# Manual trigger for immediate testing
output "trigger_execution" {
  description = "Commands to manually trigger association execution immediately (bypasses schedule)"
  value = {
    for name, assoc in aws_ssm_association.document_association :
    name => "AWS_REGION=${data.aws_region.current.id} AWS_PROFILE=${var.aws_profile} aws ssm start-associations-once --association-ids '${assoc.association_id}'"
  }
}

# Check execution status
output "check_execution_status" {
  description = "Commands to view association execution history and status"
  value = {
    for name, assoc in aws_ssm_association.document_association :
    name => "AWS_REGION=${data.aws_region.current.id} AWS_PROFILE=${var.aws_profile} aws ssm describe-association-executions --association-id '${assoc.association_id}' --max-results 5"
  }
}

# Generic instance parameters (dependency inversion interface)
# Compute module creates these parameters for each instance, SSM documents update values
output "instance_parameters" {
  description = "Parameter Store definitions for EC2 instances (compute module creates resources)"
  value = contains(keys(local.enabled_documents), "windows-password-rotation") ? [
    {
      path_template    = "${var.config.parameter_store_prefix}/{instance_id}/{username}"
      description      = "Local user password (rotated by SSM)"
      default_username = var.config.parameter_username
      initial_value    = "PLACEHOLDER-WILL-BE-ROTATED-BY-SSM"
      type             = "SecureString"
    }
  ] : []
}

# Bucket requests (dependency inversion interface)
# Storage module creates S3 buckets from these definitions
# See storage-requests.tf for bucket definitions
output "bucket_requests" {
  description = "S3 bucket definitions for storage module (storage module creates resources)"
  value       = local.bucket_requests
}

# Patch Management Outputs
# All patch management orchestration happens within this module
# Root only needs to pass instances_by_class as input

# Patch management enabled flag
output "patch_management_enabled" {
  description = "Whether patch management is enabled"
  value       = local.patch_enabled
}

# Patch management summary for visibility
output "patch_management_summary" {
  description = "Summary of patch management configuration"
  value = local.patch_enabled ? {
    baselines           = keys(local.baselines)
    maintenance_windows = keys(local.maintenance_windows)
    targets_created     = length(aws_ssm_maintenance_window_target.patch)
    tasks_created       = length(aws_ssm_maintenance_window_task.patch)
  } : null
}

# Per-class patch management configuration for portal scorecard
# Inverts baseline→classes into class→{patch_group, baseline, baseline_os, maintenance_window}
output "patch_management_by_class" {
  description = "Per-class patch management configuration for portal scorecard"
  value = local.patch_enabled ? {
    for assoc in local.patch_group_associations :
    assoc.class_name => {
      patch_group = assoc.patch_group
      baseline    = assoc.baseline_name
      baseline_os = local.baselines[assoc.baseline_name].operating_system
      maintenance_window = try(
        [for wname, w in local.maintenance_windows : wname
        if w.baseline == assoc.baseline_name][0],
        null
      )
    }
  } : {}
}

# Patch baselines with class mappings
output "baselines" {
  description = "Patch baselines with their class mappings"
  value = local.patch_enabled ? {
    for name, baseline in local.baselines : name => {
      operating_system = baseline.operating_system
      classes          = baseline.classes
      baseline_id      = aws_ssm_patch_baseline.baseline[name].id
    }
  } : {}
}

# Patch group mappings (class name => namespaced patch group name)
# Used by compute module to tag instances with correct Patch Group
output "patch_groups_by_class" {
  description = "Map of class names to their namespaced patch group names for instance tagging"
  value = local.patch_enabled ? {
    for assoc in local.patch_group_associations :
    assoc.class_name => assoc.patch_group
  } : {}
}

# Hybrid Activation Outputs
# Credentials for registering non-AWS machines with SSM

# Hybrid activation credentials
output "hybrid_activations" {
  description = "Hybrid activation credentials for registering non-AWS machines"
  value = {
    for key, activation in aws_ssm_activation.activation : key => {
      activation_id   = activation.id
      activation_code = activation.activation_code
      iam_role        = activation.iam_role
      region          = data.aws_region.current.id
      # Pre-formatted registration command for convenience
      registration_command = "sudo /tmp/ssm/ssm-setup-cli -register -activation-code '${activation.activation_code}' -activation-id '${activation.id}' -region '${data.aws_region.current.id}'"
    }
  }
}

# Command Registry
# Standardized operational commands for terminal output and portal self-service actions
# Each entry is a complete workflow: commands list shows the full debugging sequence
output "commands" {
  description = "Standardized operational commands for CLI display and portal actions"
  value = concat(
    # Document associations: trigger + wait + collect as a single workflow
    # Expand per class so the portal action condition can filter by entity class
    flatten([
      for name, assoc in aws_ssm_association.document_association : [
        for class_name in keys(var.instances_by_class) : {
          title       = "Run ${local.documents[name].formatted_name}"
          description = "Trigger the ${name} SSM association and collect execution results"
          commands = [
            "# Step 1: Trigger association",
            "AWS_REGION=${data.aws_region.current.id} AWS_PROFILE=${var.aws_profile} aws ssm start-associations-once --association-ids '${assoc.association_id}'",
            "# Step 2: Check execution status (repeat until Status is Success/Failed)",
            "AWS_REGION=${data.aws_region.current.id} AWS_PROFILE=${var.aws_profile} aws ssm describe-association-executions --association-id '${assoc.association_id}' --max-results 1",
            "# Step 3: Get per-instance output (use ExecutionId from step 2)",
            "AWS_REGION=${data.aws_region.current.id} AWS_PROFILE=${var.aws_profile} aws ssm describe-association-execution-targets --association-id '${assoc.association_id}' --execution-id '<ExecutionId>'",
          ]
          service     = "configuration-management"
          category    = "doc-${name}"
          target_type = "class"
          target      = class_name
          execution   = "local"
          action_config = {
            type           = "ssm_trigger_and_collect"
            association_id = assoc.association_id
            region         = data.aws_region.current.id
          }
        }
      ]
    ]),
    # Application associations: trigger + collect per SSM app deployment
    [
      for idx, assoc in aws_ssm_association.applications : {
        title       = "Run App: ${local.ssm_application_requests[idx].script}"
        description = "Trigger and collect results for ${local.ssm_application_requests[idx].class} application deployment"
        commands = [
          "# Step 1: Trigger association",
          "AWS_REGION=${data.aws_region.current.id} AWS_PROFILE=${var.aws_profile} aws ssm start-associations-once --association-ids '${assoc.association_id}'",
          "# Step 2: Check execution status (repeat until Status is Success/Failed)",
          "AWS_REGION=${data.aws_region.current.id} AWS_PROFILE=${var.aws_profile} aws ssm describe-association-executions --association-id '${assoc.association_id}' --max-results 1",
          "# Step 3: Get per-instance output (use ExecutionId from step 2)",
          "AWS_REGION=${data.aws_region.current.id} AWS_PROFILE=${var.aws_profile} aws ssm describe-association-execution-targets --association-id '${assoc.association_id}' --execution-id '<ExecutionId>'",
        ]
        service     = "configuration-management"
        category    = "app-${replace(local.ssm_application_requests[idx].script, "/", "-")}"
        target_type = "class"
        target      = local.ssm_application_requests[idx].class
        execution   = "local"
        action_config = {
          type           = "ssm_trigger_and_collect"
          association_id = assoc.association_id
          tenant         = local.ssm_application_requests[idx].tenant
          region         = data.aws_region.current.id
        }
      }
    ],
    # Ansible controller: trigger CodeBuild project
    local.ansible_controller_enabled ? [
      {
        title       = "Run Ansible Controller"
        description = "Trigger the Ansible controller CodeBuild project to run all playbooks"
        commands = [
          "# Step 1: Start CodeBuild build",
          "AWS_REGION=${data.aws_region.current.id} AWS_PROFILE=${var.aws_profile} aws codebuild start-build --project-name '${aws_codebuild_project.ansible_controller[0].name}'",
          "# Step 2: Check build status (use build ID from step 1)",
          "AWS_REGION=${data.aws_region.current.id} AWS_PROFILE=${var.aws_profile} aws codebuild batch-get-builds --ids '<build-id>'",
          "# Step 3: View build logs",
          "AWS_REGION=${data.aws_region.current.id} AWS_PROFILE=${var.aws_profile} aws logs tail '/aws/codebuild/${aws_codebuild_project.ansible_controller[0].name}' --follow",
        ]
        service     = "configuration-management"
        category    = "ansible-controller"
        target_type = "global"
        target      = "all"
        execution   = "local"
        action_config = {
          type         = "codebuild_trigger"
          project_name = aws_codebuild_project.ansible_controller[0].name
          region       = data.aws_region.current.id
        }
      }
    ] : []
  )
}

# Docker testing commands
output "docker_test_commands" {
  description = "Single command to test hybrid activation in Docker (run from terraform/ directory)"
  value = {
    for key, activation in aws_ssm_activation.activation : key => {
      # Single command - starts container, installs agent, registers, stays alive
      run = "docker compose run agent /scripts/ssm-entrypoint.sh '${activation.activation_code}' '${activation.id}' '${data.aws_region.current.id}'"

      # Verification and management commands
      verify_in_aws = "AWS_REGION=${data.aws_region.current.id} AWS_PROFILE=${var.aws_profile} aws ssm describe-instance-information --filters 'Key=ActivationIds,Values=${activation.id}'"
      shell_access  = "docker exec -it hybrid-activation-test bash"
      cleanup       = "docker compose down"
    }
  }
}

output "access_requests" {
  description = "IAM access requests for the access module (access creates resources, returns ARNs)"
  value       = local.access_requests
}

# Event Bus Requests (dependency inversion interface)
# Portal module creates webhooks from these definitions
output "event_bus_requests" {
  description = "Event bus webhook subscription requests (portal creates webhooks)"
  value = var.ansible_applications_configured ? [
    {
      purpose     = "codebuild-lifecycle"
      description = "CodeBuild lifecycle events (Ansible controller)"
      event_type  = "codebuild"
      source      = "configuration-management"
    }
  ] : []
}
