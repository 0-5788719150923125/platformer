# Audit

Centralized access control reporting using dependency inversion. Modules declare the IAM roles, security groups, and resource policies they provision, and the audit module aggregates them into a single JSON report rendered in AWS-native format.

## Concept

Access policies are scattered across modules (compute, build, storage, archorchestrator, archpacs, configuration-management, archbot), each creating IAM roles, security group rules, and bucket/queue policies for different purposes. The audit module gives centralized visibility into all of these without moving the resources themselves.

Each module emits `audit_iam_roles`, `audit_security_groups`, and/or `audit_resource_policies` outputs describing the policies it creates. The root `main.tf` concatenates these and passes the combined lists to the audit module, which groups by module and writes a JSON report to `audit/build/`.

This is always-on, like archivist and auto-docs. No state fragment is needed to enable it.

## Dependency Graph

```
compute ---------------+
build -----------------+
storage ---------------+ iam_roles / security_groups / resource_policies
configuration-mgmt ----+---------------------------------------------------> audit --> artifact_requests --> portal
archorchestrator ------+
archpacs --------------+
archbot ---------------+
```

No module depends on audit. It is a pure consumer at the end of the dependency chain.

## Key Features

- **AWS-Native Format** - IAM roles render like `aws iam get-role` + `get-role-policy`; security groups like `aws ec2 describe-security-groups`
- **Full Policy Documents** - Actual deployed `AssumeRolePolicyDocument`, inline policy JSON, and bucket/queue policies
- **Dependency Inversion** - Modules declare policies as data; audit collects them
- **Structured Report** - JSON grouped by module with per-module counts
- **Artifact Registry** - Emits `artifact_requests` so the report appears in the portal catalog
- **Zero Infrastructure** - Produces a local file only; no AWS resources created

## Report Structure

The generated JSON report at `audit/build/access-report-<namespace>.json`:

```json
{
  "generated_at": "2026-02-26T14:30:00-05:00",
  "namespace": "fapogore",
  "git_sha": "f25e6b8c",
  "summary": {
    "iam_roles": 12,
    "security_groups": 8,
    "resource_policies": 3,
    "by_module": {
      "compute": { "iam_roles": 1, "security_groups": 3, "resource_policies": 0 },
      "archorchestrator": { "iam_roles": 4, "security_groups": 4, "resource_policies": 0 }
    }
  },
  "iam_roles": {
    "compute": [
      {
        "RoleName": "fapogore-compute-instance",
        "Description": "EC2 instance role for compute classes with applications",
        "AssumeRolePolicyDocument": {
          "Version": "2012-10-17",
          "Statement": [{
            "Effect": "Allow",
            "Principal": { "Service": "ec2.amazonaws.com" },
            "Action": "sts:AssumeRole"
          }]
        },
        "ManagedPolicyArns": ["arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"],
        "InlinePolicies": {}
      }
    ]
  },
  "security_groups": {
    "compute": [
      {
        "GroupName": "fapogore-rocky-linux-xxxxx",
        "Description": "Security group for rocky-linux instances",
        "IpPermissions": [
          {
            "IpProtocol": "tcp",
            "FromPort": 8080,
            "ToPort": 8080,
            "IpRanges": [{ "CidrIp": "0.0.0.0/0", "Description": "Port 8080 from configured CIDRs" }],
            "UserIdGroupPairs": []
          }
        ],
        "IpPermissionsEgress": [
          {
            "IpProtocol": "-1",
            "FromPort": 0,
            "ToPort": 0,
            "IpRanges": [{ "CidrIp": "0.0.0.0/0", "Description": "Allow all outbound traffic" }]
          }
        ]
      }
    ]
  },
  "resource_policies": {
    "storage": [
      {
        "ResourceType": "s3-bucket-policy",
        "ResourceName": "access-logs-fapogore",
        "Policy": {
          "Version": "2012-10-17",
          "Statement": [...]
        }
      }
    ]
  }
}
```

## Input Schemas

### IAM Roles

```hcl
{
  module              = string            # Source module name
  role_name           = string            # IAM role name (as deployed)
  description         = optional(string)  # Human-readable description
  trust_policy        = string            # JSON-encoded AssumeRolePolicyDocument
  managed_policy_arns = list(string)      # Attached managed policy ARNs
  inline_policies     = map(string)       # policy_name => JSON-encoded policy document
}
```

### Security Groups

```hcl
{
  module      = string            # Source module name
  group_name  = string            # Security group name (as deployed)
  description = optional(string)
  ingress = list(object({
    description           = optional(string)
    protocol              = string         # "tcp", "udp", "-1"
    from_port             = number
    to_port               = number
    cidr_blocks           = list(string)
    source_security_group = optional(string)  # SG ID reference
    self                  = optional(bool)    # Self-referencing rule
  }))
  egress = list(object({
    description = optional(string)
    protocol    = string
    from_port   = number
    to_port     = number
    cidr_blocks = list(string)
  }))
}
```

### Resource Policies

```hcl
{
  module        = string  # Source module name
  resource_type = string  # "s3-bucket-policy", "sqs-queue-policy"
  resource_name = string  # Bucket name, queue name, etc.
  policy        = string  # JSON-encoded policy document
}
```

## What Each Module Reports

| Module | IAM Roles | Security Groups | Resource Policies |
|--------|-----------|-----------------|-------------------|
| **compute** | EC2 instance role | Per-class SGs, ALB SGs, NLB rules | - |
| **build** | Packer build role | - | - |
| **storage** | - | RDS Aurora SG, RDS instance SGs, ElastiCache SG | S3 bucket policies (access logs, hooks) |
| **archorchestrator** | ECS execution, task, bootstrap, app roles | ALB SGs, ECS SGs (per deployment) | - |
| **archpacs** | - | Maestro SSH trust SGs | - |
| **configuration-management** | Maintenance window, hybrid instance, Ansible controller roles | - | - |
| **archbot** | API Gateway, Lambda, Bedrock KB roles | - | SQS queue policy |

## Adding Audit Outputs to a New Module

1. Add one or more outputs following the schemas above:
   - `audit_iam_roles` for IAM roles with full policy documents
   - `audit_security_groups` for security groups with ingress/egress rules
   - `audit_resource_policies` for S3 bucket or SQS queue policies
2. Add the module's outputs to the appropriate `concat()` in `main.tf` inside the `module "audit"` block.

## Output Location

Reports are written to `audit/build/` (git-ignored via `audit/.gitignore`):

```
platformer/audit/build/
  access-report-<namespace>.json
```
