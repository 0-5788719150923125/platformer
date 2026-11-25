# Automatically discover all modules with test suites
locals {
  # Manual exclusion list - modules to skip even if they have tests
  excluded_modules = [
    "legacy",
  ]

  # Discover all modules that have a tests/ directory with .tftest.hcl files
  # Uses fileset to find any module with tests, then extracts unique module names
  all_modules_with_tests = distinct(concat(
    [
      for test_file in fileset("${path.module}/..", "*/tests/*.tftest.hcl") :
      split("/", test_file)[0]
    ],
    # Cloud adapters inside a service carry their own suites (e.g. compute/aws, compute/oci)
    [
      for test_file in fileset("${path.module}/..", "*/*/tests/*.tftest.hcl") :
      join("/", slice(split("/", test_file), 0, 2))
      if !startswith(test_file, ".")
    ],
  ))

  # Filter out excluded modules
  modules_with_tests = [
    for module in local.all_modules_with_tests :
    module if !contains(local.excluded_modules, module)
  ]
}
