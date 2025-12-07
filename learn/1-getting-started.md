# Getting Started with Platformer

**User Story**: *As a compliance officer, I need to implement Administrator password rotation for Windows servers in AWS.*

This walkthrough will guide you through the deployment of your first service using Platformer. We'll start with a basic deployment, then add password rotation as a practical example.

---

## Prerequisites

- Git installed and configured with access to the infra-terraform repository
- Terraform 1.5+ installed
- AWS credentials configured (profile management is handled automatically)

---

## Step 1: Clone and Checkout the Branch

```bash
git clone https://github.com/acme-org/infra-terraform.git
cd infra-terraform
git checkout PROJ-5062-test-terraform-framework-in-limited-prod-password-rotation-patch-management
```

---

## Step 2: Navigate to the Platformer Directory

```bash
cd platformer
```

This is the root of our new infrastructure framework. Unlike the old `environment/*` structure with hundreds of directories, everything is managed from this single location.

---

## Step 3: Initialize Terraform

```bash
terraform init
```

This downloads required providers and initializes the backend. You should see output confirming successful initialization.

---

## Step 4: Run Your First Plan

```bash
terraform plan
```

**Important**: By default, this deploys ZERO infrastructure. The framework generates a unique, developer-specific namespace for safe local testing, but doesn't create any actual resources until you provide configuration.

You'll see output similar to:

```
Terraform will perform the following actions:

  # random_pet.namespace will be created
  + resource "random_pet" "namespace" {
      + id        = (known after apply)
      + length    = 2
      + separator = "-"
    }

Plan: 1 to add, 0 to change, 0 to destroy.

Changes to Outputs:
  + namespace = (known after apply)
```

This is intentional. Configuration is provided via composable state fragments.

---

## Step 5: Add Configuration via State Fragments

State fragments are YAML files that live in `platformer/states/*`, which define the set of services to enable and how to configure them. Let's enable password rotation.

Create a local `terraform.tfvars` file, and put this within:

```hcl
# terraform.tfvars
states = [
  "compute-windows-poc",               # Enable compute module (creates Windows POC instances)
  "configuration-management-scoped"    # Enable password rotation with tag-based targeting
]
```

### What these fragments do:

- **states/compute-windows-poc.yaml**: Enables the compute module with Windows POC instance classes
- **states/configuration-management-scoped.yaml**: Enables password rotation targeting only instances deployed by this Terraform project

### Region and Account Targeting

For local development, region and account are controlled by variables (see `variables.tf`):

```hcl
# Default values (us-east-2, dev account)
aws_region  = "us-east-2"         # Default
aws_profile = "example-platform-dev"  # Default (uses profile from ~/.aws/config)
```

You can override these in `terraform.tfvars` if needed:

```hcl
# terraform.tfvars
aws_region  = "us-west-2"          # Deploy to a different region
aws_profile = "example-account-prod"   # Deploy to a different account (uses profile name)

states = [
  "compute-windows-poc",
  "configuration-management-scoped"
]
```

**Note**: Profile names come from your `~/.aws/config` file. The AWS account ID is automatically derived from whichever profile you specify.

---

## Step 6: Plan with Configuration

```bash
terraform plan
```

Now you'll see actual infrastructure being planned:

```
Terraform will perform the following actions:

  # module.compute[0].aws_instance.tenant["demo-windows-poc"] will be created
  + resource "aws_instance" "tenant" {
      + ami           = "ami-0a1b2c3d4e5f6g7h8"
      + instance_type = "t3.medium"
      + tags          = {
          + "Class"     = "windows-poc"
          + "Tenant"  = "demo"
          + "Name"      = "demo-windows-poc-happy-goldfish"
          + "Namespace" = "happy-goldfish"
        }
    }

  # module.compute[0].aws_ssm_parameter.instance["demo-windows-poc-param-0"] will be created
  + resource "aws_ssm_parameter" "instance" {
      + name  = "/ec2/demo-windows-poc-happy-goldfish/administrator/password"
      + type  = "SecureString"
      + value = (sensitive value)
    }

  # module.configuration_management[0].aws_ssm_document.document["windows-password-rotation"] will be created
  + resource "aws_ssm_document" "document" {
      + document_format = "YAML"
      + document_type   = "Command"
      + name            = "Windows-Password-Rotation-happy-goldfish"
    }

  # module.configuration_management[0].aws_ssm_association.document_association["windows-password-rotation"] will be created
  + resource "aws_ssm_association" "document_association" {
      + association_name      = "windows-password-rotation-happy-goldfish"
      + compliance_severity   = "HIGH"
      + max_concurrency       = "10%"
      + max_errors           = "10%"
      + schedule_expression  = "rate(30 minutes)"
      + targets {
          + key    = "tag:Class"
          + values = ["windows-poc"]
        }
      + targets {
          + key    = "tag:Namespace"
          + values = ["happy-goldfish"]
        }
    }

Plan: 12 to add, 0 to change, 0 to destroy.
```

Notice:
- Instances are created with both `Class` and `Namespace` tags
- SSM parameters are pre-created for storing rotated passwords
- SSM associations target instances using **both** `Class` AND `Namespace` tags for proper isolation
- Multi-tag targeting ensures that multiple developers in the same account don't affect each other's instances
- The namespace (`happy-goldfish`) ensures your test environment is isolated

---

## Step 7: Apply the Configuration

```bash
terraform apply
```

Review the plan, type `yes` to confirm. After a few minutes, you'll see:

```
Apply complete! Resources: 12 added, 0 changed, 0 destroyed.

Outputs:

compute = {
  "instances_by_class" = {
    "windows-poc" = [
      {
        "id" = "i-0a1b2c3d4e5f6g7h8"
        "name" = "demo-windows-poc-happy-goldfish"
        "password_parameter" = "/ec2/demo-windows-poc-happy-goldfish/administrator/password"
      }
    ]
  }
}

configuration_management = {
  "documents" = {
    "windows-password-rotation" = {
      "association" = "windows-password-rotation-happy-goldfish"
      "document_name" = "Windows-Password-Rotation-happy-goldfish"
      "has_targets" = true
      "schedule" = "rate(30 minutes)"
    }
  }
}

namespace = "happy-goldfish"
```

---

## Step 8: Verify Password Rotation

Terraform outputs provide the commands you need to verify the deployment. Use those commands to test, troubleshoot, and verify that deployment is correct.

**Note**: AWS CLI commands in the outputs will need the `AWS_PROFILE` environment variable (e.g., `AWS_PROFILE=example-platform-dev`), but Terraform commands do not - the provider automatically uses the profile specified in your `terraform.tfvars`.

---

## What Just Happened?

1. **Zero to production in minutes**: You went from no infrastructure to fully automated password rotation against several new EC2 instances
2. **Composable configuration**: State fragments are reusable building blocks
3. **Safe defaults**: Scoped targeting ensures you only manage instances you deploy
4. **Self-documenting**: Terraform outputs tell you exactly how to interact with your infrastructure

---

## Key Concepts

### State Fragments
YAML files that configure services. They merge left-to-right, allowing you to compose complex configurations from simple building blocks.

### Namespace Isolation
Every local deployment gets a unique namespace (e.g., `happy-goldfish`). This ensures developers can test safely without conflicts.

### Tag-Based Targeting
Unlike wildcard targeting (`InstanceIds = ["*"]`), the scoped approach uses **multi-tag targeting** with both `tag:Class` AND `tag:Namespace`. This ensures:
- **Class isolation**: Only target instances of specific classes (e.g., `windows-poc`)
- **Namespace isolation**: Only target instances from your specific deployment (e.g., `happy-goldfish`)
- **Multi-developer safety**: Multiple developers can deploy in the same account without cross-contamination
- **Clean teardown**: `terraform destroy` only affects your instances, not others'

This prevents accidental management of unrelated instances, even when multiple deployments exist in the same account.

### Conditional Module Loading
Modules like `compute` and `configuration-management` only activate when their state fragments are included. This keeps plans clean and focused.

---

## Next Steps

- **Explore other state fragments**: Look in `platformer/states/` for patch management, storage, and other services
- **Customize configuration**: Copy and modify fragments to meet your specific requirements
- **Read the outputs carefully**: Terraform provides AWS-CLI commands and parameter paths specific to your deployment

In the next document, we'll explore how to take a local proof-of-concept and deploy it to production using GitHub Actions.
