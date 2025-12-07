# Comprehensive test runner
# Executes all module-level test suites in sequence
# Usage: terraform test -filter='tests/all_module_tests.tftest.hcl'
#   or simply: terraform test (includes this test with all others)

run "execute_all_module_tests" {
  # Must use 'apply' to trigger local-exec provisioners
  command = apply

  # Test the tests/ module itself (not the parent platformer module)
  module {
    source = "./tests"
  }

  variables {
    # Enable the test runner
    run_all_module_tests = true
  }

  # Verify test runners were created for all modules
  assert {
    condition     = length(null_resource.module_test_runner) == length(output.modules_tested)
    error_message = "Module test runners should be created for all modules with tests"
  }

  # Verify output reflects execution
  assert {
    condition     = output.module_tests_executed == true
    error_message = "Module tests should be marked as executed"
  }

  # Verify all expected modules were tested
  assert {
    condition     = length(output.modules_tested) > 0
    error_message = "At least one module should have been tested"
  }
}
