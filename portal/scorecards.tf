# Patch Management Readiness Scorecard
# Evaluates compute instances on patch management configuration status
# Uses default levels: Basic (no config) → Bronze → Silver → Gold (fully configured)
# Filtered to EC2 instances only — EKS instances show "Basic" (no patch management expected)

resource "port_scorecard" "patch_management_readiness" {
  count = local.is_subspace ? 0 : 1

  identifier = "patchManagementReadiness-${var.namespace}"
  title      = "Patch Management Readiness"
  blueprint  = local.bp_compute_instance

  filter = {
    combinator = "and"
    conditions = [
      jsonencode({
        property = "type"
        operator = "="
        value    = "ec2"
      })
    ]
  }

  rules = [
    {
      identifier  = "hasPatchGroup"
      title       = "Has Patch Group"
      level       = "Bronze"
      description = "Instance class has an SSM Patch Group assigned"
      query = {
        combinator = "and"
        conditions = [
          jsonencode({
            property = "patchGroup"
            operator = "isNotEmpty"
          })
        ]
      }
    },
    {
      identifier  = "hasPatchBaseline"
      title       = "Has Patch Baseline"
      level       = "Silver"
      description = "Instance class has an SSM Patch Baseline configured"
      query = {
        combinator = "and"
        conditions = [
          jsonencode({
            property = "patchBaseline"
            operator = "isNotEmpty"
          })
        ]
      }
    },
    {
      identifier  = "hasMaintenanceWindow"
      title       = "Has Maintenance Window"
      level       = "Gold"
      description = "Instance class has an SSM Maintenance Window scheduled for patching"
      query = {
        combinator = "and"
        conditions = [
          jsonencode({
            property = "patchMaintenanceWindow"
            operator = "isNotEmpty"
          })
        ]
      }
    },
    {
      identifier  = "isCompliant"
      title       = "Patch Compliance"
      level       = "Gold"
      description = "Instance reports COMPLIANT patch status from SSM (updated by Lambda every 15 minutes)"
      query = {
        combinator = "and"
        conditions = [
          jsonencode({
            property = "patchComplianceStatus"
            operator = "="
            value    = "COMPLIANT"
          })
        ]
      }
    }
  ]

  depends_on = [port_blueprint.platformer_compute_instance]
}
