# Hybrid Patch Targeting
# Maintenance windows can target SSM-managed (hybrid-activated) instances via a
# Resource Group querying AWS::SSM::ManagedInstance. The dynamic-targeting Lambda
# only handles EC2 instances (its tagging path uses ec2:CreateTags), so hybrid
# hosts on Oracle Cloud, Azure, on-prem, etc. get this dedicated path.
#
# Registration applies the SSM resource tag inline:
#   ssm-setup-cli -register ... -tags 'Key=<tag_key>,Value=<tag_value>'

locals {
  hybrid_targeting_windows = {
    for window_name, window in local.maintenance_windows :
    window_name => window
    if window.hybrid_targeting != null
  }
}

resource "aws_resourcegroups_group" "hybrid_patch" {
  for_each = local.hybrid_targeting_windows

  name        = "ssm-hybrid-patch-${each.key}-${var.namespace}"
  description = "Hybrid managed instances for ${each.value.baseline} baseline - tag ${each.value.hybrid_targeting.tag_key} ${each.value.hybrid_targeting.tag_value}"

  resource_query {
    query = jsonencode({
      ResourceTypeFilters = ["AWS::SSM::ManagedInstance"]
      TagFilters = [
        {
          Key    = each.value.hybrid_targeting.tag_key
          Values = [each.value.hybrid_targeting.tag_value]
        }
      ]
    })
  }

  tags = {
    Name      = "ssm-hybrid-patch-${each.key}-${var.namespace}"
    Namespace = var.namespace
    Baseline  = each.value.baseline
  }
}

# Hybrid Patch Groups
# AWS-RunPatchBaseline picks its baseline from the instance's "PatchGroup" (or
# "Patch Group") tag. Without a registered patch group it silently falls back
# to the AWS default baseline for the OS, ignoring the window's baseline. So
# register the window's tag_value as a patch group on its baseline whenever the
# hybrid targeting tag is a patch group tag.
resource "aws_ssm_patch_group" "hybrid" {
  for_each = {
    for window_name, window in local.hybrid_targeting_windows :
    window_name => window
    if contains(["PatchGroup", "Patch Group"], window.hybrid_targeting.tag_key)
  }

  baseline_id = aws_ssm_patch_baseline.baseline[each.value.baseline].id
  patch_group = each.value.hybrid_targeting.tag_value
}
