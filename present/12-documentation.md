## Documentation

Comprehensive documentation exists for every layer of the framework. Module READMEs explain service-specific behavior, state fragment guides show configuration patterns, and tutorials provide step-by-step walkthroughs. The framework also generates self-documenting outputs with ready-to-run AWS CLI commands.

---

### Main Documentation:

**[README.md](../README.md)** - Architecture overview, getting started, and design principles

**[SCHEMA.md](../SCHEMA.md)** - Auto-generated module schema documentation with variables, outputs, and state fragment structures

---

### Service Module Documentation:

- **[clairevoyance](../clairevoyance/README.md)** - Medical AI platform with SageMaker Studio, inference endpoints, and container registry
- **[compute](../compute/README.md)** - EC2 and EKS compute provisioning with class-based expansion and multi-tenant support *[auto-enables]*
- **[config](../config/README.md)** - Configuration resolver - loads and merges state fragments from states/ directory
- **[configuration-management](../configuration-management/README.md)** - SSM automation for patch management, password rotation, and hybrid activations
- **[tenants](../tenants/README.md)** - Tenant registry for validation and metadata management
- **[hashing](../hashing/README.md)** - Deterministic namespace generation using Pokemon names or random pet names
- **[legacy](../legacy/README.md)** - Legacy service management for Atlantis and other transitional workloads
- **[networking](../networking/README.md)** - VPC provisioning with deterministic CIDR allocation, multi-AZ subnets, and NAT/IGW routing
- **[storage](../storage/README.md)** - S3 bucket provisioning with dependency inversion and automatic access logging *[auto-enables]*

---

### Additional Documentation:

- **[states](../states/README.md)** - Creating and using state fragments
- **[tests](../tests/README.md)** - Test automation and testing strategies
- **[learn/](../learn/)** - Step-by-step tutorials and training materials covering getting started, going live, and module composition patterns
- **[next/](../next/)** - Exploration of potential next steps including integration testing strategies, tenant registry concepts, container services, and architectural considerations

---

### Self-Documenting Outputs:

Terraform outputs provide ready-to-run commands with deployment-specific data:

```bash
$ terraform output -json configuration_management | jq '.check_execution_status'
{
  "windows-password-rotation": "AWS_REGION=us-east-2 AWS_PROFILE=example-platform-dev aws ssm describe-association-executions --association-id 'a1b2c3d4-5678-90ab-cdef-EXAMPLE11111' --max-results 5"
}

$ terraform output -json storage | jq '.buckets'
{
  "ssm-association-logs": {
    "name": "ssm-logs-ssm-association-logs-happy-goldfish",
    "arn": "arn:aws:s3:::ssm-logs-ssm-association-logs-happy-goldfish",
    "description": "SSM Association execution logs"
  }
}
```

No need to manually construct AWS CLI commands - outputs contain accurate commands with IDs, regions, and resource names from your actual deployment.
