# Access Module
# Central IAM authority: modules declare access needs via access_requests,
# access creates IAM resources and returns ARNs/names to consuming modules.
# Also aggregates security groups and resource policies into a JSON report.
#
# Dependency graph:
#   [all modules] --> access_requests --> access --> iam_role_arns/names --> [consuming modules]
#   [all modules] --> security_groups / resource_policies --> access --> report --> portal

# ============================================================================
# Git Info (for artifact metadata)
# ============================================================================

data "external" "git_info" {
  program = ["bash", "-c", <<-EOF
    echo "{\"sha\":\"$(git rev-parse --short HEAD 2>/dev/null || echo 'unknown')\",\"timestamp\":\"$(git log -1 --format=%cI HEAD 2>/dev/null || echo '1970-01-01T00:00:00+00:00')\"}"
  EOF
  ]
  working_dir = path.root
}

# ============================================================================
# Access Request Processing
# ============================================================================

locals {
  # Filter requests by type
  role_requests = {
    for req in var.access_requests :
    "${req.module}-${req.purpose}" => req
    if req.type == "iam-role"
  }

  inline_policy_requests = {
    for req in var.access_requests :
    "${req.module}-${req.purpose}" => req
    if req.type == "inline-policy"
  }

  # Expand inline policies from role requests + standalone inline-policy requests
  all_inline_policies = merge(
    # Inline policies declared within iam-role requests
    {
      for entry in flatten([
        for key, req in local.role_requests : [
          for policy_name, policy_doc in req.inline_policies : {
            composite_key = "${key}/${policy_name}"
            role_key      = key
            policy_name   = policy_name
            policy        = policy_doc
          }
        ]
      ]) : entry.composite_key => entry
    },
    # Standalone inline-policy requests (cross-module policies)
    {
      for key, req in local.inline_policy_requests :
      "${req.role_key}/${key}" => {
        composite_key = "${req.role_key}/${key}"
        role_key      = req.role_key
        policy_name   = key
        policy        = req.policy
      }
    }
  )

  # Expand managed policy attachments from role requests
  all_managed_attachments = {
    for entry in flatten([
      for key, req in local.role_requests : [
        for arn in req.managed_policy_arns : {
          composite_key = "${key}/${regex("[^/]+$", arn)}"
          role_key      = key
          policy_arn    = arn
        }
      ]
    ]) : entry.composite_key => entry
  }

  # Roles that need instance profiles
  instance_profile_requests = {
    for key, req in local.role_requests :
    key => req
    if req.instance_profile
  }

  # Pre-computed role names and ARNs (for cross-role trust policies)
  # Constructed from config to avoid self-referential resource blocks
  role_names = {
    for key, req in local.role_requests :
    key => "${var.namespace}-${key}"
  }

  role_arns = {
    for key, name in local.role_names :
    key => "arn:aws:iam::${var.aws_account_id}:role/${name}"
  }
}

# ============================================================================
# IAM Resources (created from access_requests)
# ============================================================================

resource "aws_iam_role" "requested" {
  for_each = local.role_requests

  name = local.role_names[each.key]

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [merge(
      {
        Effect = "Allow"
        Principal = merge(
          length(each.value.trust_services) > 0 ? {
            Service = each.value.trust_services
          } : {},
          length(each.value.trust_roles) > 0 ? {
            AWS = [for rk in each.value.trust_roles : local.role_arns[rk]]
          } : {}
        )
        Action = each.value.trust_actions
      },
      each.value.trust_conditions != "{}" ? {
        Condition = jsondecode(each.value.trust_conditions)
      } : {}
    )]
  })

  tags = {
    Namespace = var.namespace
    Module    = each.value.module
  }
}

resource "aws_iam_role_policy" "requested" {
  for_each = local.all_inline_policies

  name   = each.value.policy_name
  role   = aws_iam_role.requested[each.value.role_key].id
  policy = each.value.policy
}

resource "aws_iam_role_policy_attachment" "requested" {
  for_each = local.all_managed_attachments

  role       = aws_iam_role.requested[each.value.role_key].name
  policy_arn = each.value.policy_arn
}

resource "aws_iam_instance_profile" "requested" {
  for_each = local.instance_profile_requests

  name = "${var.namespace}-${each.key}"
  role = aws_iam_role.requested[each.key].name

  tags = {
    Namespace = var.namespace
    Module    = each.value.module
  }
}

# ============================================================================
# Report Generation
# ============================================================================

locals {
  # --- Access-owned IAM roles (from access_requests) ---
  owned_iam_modules = distinct([for key, req in local.role_requests : req.module])
  owned_iam_roles_by_module = {
    for mod in local.owned_iam_modules : mod => [
      for key, req in local.role_requests : {
        RoleName                 = aws_iam_role.requested[key].name
        Description              = req.description
        AssumeRolePolicyDocument = jsondecode(aws_iam_role.requested[key].assume_role_policy)
        ManagedPolicyArns        = req.managed_policy_arns
        InlinePolicies = {
          for pk, pv in local.all_inline_policies :
          pv.policy_name => jsondecode(aws_iam_role_policy.requested[pk].policy)
          if pv.role_key == key
        }
      }
      if req.module == mod
    ]
  }

  # --- V2 described IAM roles (from iam_roles variable, temporary) ---
  described_iam_modules = distinct([for r in var.iam_roles : r.module])
  described_iam_roles_by_module = {
    for mod in local.described_iam_modules : mod => [
      for r in var.iam_roles : {
        RoleName                 = r.role_name
        Description              = r.description
        AssumeRolePolicyDocument = jsondecode(r.trust_policy)
        ManagedPolicyArns        = r.managed_policy_arns
        InlinePolicies = {
          for name, policy_json in r.inline_policies :
          name => jsondecode(policy_json)
        }
      }
      if r.module == mod
    ]
  }

  # --- Merge owned + described IAM roles ---
  all_iam_modules = distinct(concat(local.owned_iam_modules, local.described_iam_modules))
  all_iam_roles_by_module = {
    for mod in local.all_iam_modules : mod => concat(
      try(local.owned_iam_roles_by_module[mod], []),
      try(local.described_iam_roles_by_module[mod], [])
    )
  }

  # --- Security groups (from variable, unchanged) ---
  sg_modules = distinct([for sg in var.security_groups : sg.module])
  security_groups_by_module = {
    for mod in local.sg_modules : mod => [
      for sg in var.security_groups : sg if sg.module == mod
    ]
  }

  # --- Resource policies (from variable, unchanged) ---
  rp_modules = distinct([for rp in var.resource_policies : rp.module])
  resource_policies_by_module = {
    for mod in local.rp_modules : mod => [
      for rp in var.resource_policies : rp if rp.module == mod
    ]
  }

  # --- Summary counts ---
  total_iam_roles         = length(local.role_requests) + length(var.iam_roles)
  total_security_groups   = length(var.security_groups)
  total_resource_policies = length(var.resource_policies)

  all_report_modules = distinct(concat(local.all_iam_modules, local.sg_modules, local.rp_modules))

  summary_by_module = {
    for mod in local.all_report_modules : mod => {
      iam_roles         = length(try(local.all_iam_roles_by_module[mod], []))
      security_groups   = length([for sg in var.security_groups : sg if sg.module == mod])
      resource_policies = length([for rp in var.resource_policies : rp if rp.module == mod])
    }
  }

  # ============================================================================
  # Assemble Report
  # ============================================================================

  report = {
    generated_at = data.external.git_info.result.timestamp
    namespace    = var.namespace
    git_sha      = data.external.git_info.result.sha

    summary = {
      iam_roles         = local.total_iam_roles
      security_groups   = local.total_security_groups
      resource_policies = local.total_resource_policies
      by_module         = local.summary_by_module
    }

    # IAM roles rendered in aws iam get-role / get-role-policy format
    iam_roles = local.all_iam_roles_by_module

    # Security groups rendered in aws ec2 describe-security-groups format
    security_groups = {
      for mod, groups in local.security_groups_by_module : mod => [
        for sg in groups : {
          GroupName   = sg.group_name
          Description = sg.description
          IpPermissions = [
            for rule in sg.ingress : {
              IpProtocol = rule.protocol
              FromPort   = rule.from_port
              ToPort     = rule.to_port
              IpRanges = [
                for cidr in rule.cidr_blocks : {
                  CidrIp      = cidr
                  Description = rule.description
                }
              ]
              UserIdGroupPairs = rule.self ? [
                { GroupId = "(self)", Description = rule.description }
                ] : (
                rule.source_security_group != "" ? [
                  { GroupId = rule.source_security_group, Description = rule.description }
                ] : []
              )
            }
          ]
          IpPermissionsEgress = [
            for rule in sg.egress : {
              IpProtocol = rule.protocol
              FromPort   = rule.from_port
              ToPort     = rule.to_port
              IpRanges = [
                for cidr in rule.cidr_blocks : {
                  CidrIp      = cidr
                  Description = rule.description
                }
              ]
            }
          ]
        }
      ]
    }

    # Resource policies in aws s3api get-bucket-policy / sqs get-queue-attributes format
    resource_policies = {
      for mod, policies in local.resource_policies_by_module : mod => [
        for rp in policies : {
          ResourceType = rp.resource_type
          ResourceName = rp.resource_name
          Policy       = jsondecode(rp.policy)
        }
      ]
    }
  }

  # Artifact paths
  report_filename    = "access-report-${var.namespace}.json"
  report_path        = "${path.module}/build/${local.report_filename}"
  report_bucket_name = "access-report-${var.namespace}"
  report_s3_key      = local.report_filename
}

# ============================================================================
# Write JSON Report to Disk
# ============================================================================

resource "local_file" "access_report_compact" {
  content  = jsonencode(local.report)
  filename = "${local.report_path}.tmp"
}

resource "null_resource" "access_report" {
  triggers = {
    compact_id = local_file.access_report_compact.id
  }

  provisioner "local-exec" {
    command = "python3 -m json.tool ${local.report_path}.tmp > ${local.report_path}"
  }
}
