## Demo Commands

These are the actual commands used to deploy and manage infrastructure with this framework. The local development workflow shows how developers test changes in a single account, while the production deployment workflow demonstrates the GitOps pattern for multi-account rollouts.

---

### Local Development Workflow:

```bash
# Clone the repository
git clone https://github.com/acme-org/infra-terraform
git checkout PROJ-5062-test-terraform-framework-in-limited-prod-password-rotation-patch-management
cd infra-terraform/platformer

# Configure which state fragments to load
# Edit terraform.tfvars:
#   states = ["configuration-management-scoped", "compute-windows-poc"]

# Initialize Terraform
terraform init

# Preview changes
terraform plan

# Deploy infrastructure
terraform apply

# Run test suite (unit + integration)
terraform test
```

---

### Production Deployment Workflow:

**1. Edit top.yaml to add state fragments to targets:**

```yaml
# top.yaml
targets:
  '*-platform-dev':
    - regions-east
    - configuration-management-scoped
    - compute-windows-poc

  '*-platform-prod':
    - regions-most
    - configuration-management-monthly
    - patch-management-catchall
```

**2. Commit changes to git:**

```bash
git add top.yaml
git commit -m "PROJ-5062: Add configuration-management to prod accounts"
git push
```

**3. Review pipelines in GitHub for your branch/PR**
- Matrix generation runs terraform plan across all matched accounts

---

### Additional Information:

See [README.md](../README.md) for complete documentation including:
- Configuration via state fragments
- Testing strategies
- CI/CD multi-account deployments
- Service module details
