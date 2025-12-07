# Automatically discover all modules with test suites
locals {
  # Manual exclusion list - modules to skip even if they have tests
  excluded_modules = [
    "legacy",
  ]

  # Discover all modules that have a tests/ directory with .tftest.hcl files
  # Uses fileset to find any module with tests, then extracts unique module names
  all_modules_with_tests = distinct([
    for test_file in fileset("${path.module}/..", "*/tests/*.tftest.hcl") :
    split("/", test_file)[0]
  ])

  # Filter out excluded modules
  modules_with_tests = [
    for module in local.all_modules_with_tests :
    module if !contains(local.excluded_modules, module)
  ]
}
