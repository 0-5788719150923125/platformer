# Preflight Checks - Reusable dependency validation utilities
# Checks for CLI tools and outputs availability status

locals {
  # Convert tool checks to JSON for script input
  tool_checks_json = jsonencode(var.required_tools)
}

data "external" "check_tools" {
  # Pass JSON via stdin to avoid command-line length limits
  program = ["bash", "-c", "echo '${local.tool_checks_json}' | ${path.module}/scripts/check-tools.sh"]
}

# Automatic validation - fails immediately if any required tool is missing
# Calls validate-tools.sh which examines results and fails with descriptive error
data "external" "validate" {
  count = length(var.required_tools) > 0 ? 1 : 0
  program = [
    "${path.module}/scripts/validate-tools.sh",
    jsonencode(data.external.check_tools.result),
    local.tool_checks_json
  ]
}
