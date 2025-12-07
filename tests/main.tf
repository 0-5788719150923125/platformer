# Test runner infrastructure
# Conditionally executes all module-level test suites
# Triggered by setting var.run_all_module_tests = true
# Creates a separate null_resource for each module for better output visibility

resource "null_resource" "module_test_runner" {
  for_each = var.run_all_module_tests ? toset(local.modules_with_tests) : []

  triggers = {
    # Always run when enabled (timestamp ensures it's never cached)
    always_run = timestamp()
    # Re-run if this specific module changes
    module_name = each.key
  }

  provisioner "local-exec" {
    command = "${path.module}/scripts/run-single-module-test.sh ${path.module}/.. ${each.key}"
  }
}

output "module_tests_executed" {
  value       = var.run_all_module_tests
  description = "Indicates whether module test suites were executed"
}

output "modules_tested" {
  value       = var.run_all_module_tests ? keys(null_resource.module_test_runner) : []
  description = "List of modules that had tests executed"
}
