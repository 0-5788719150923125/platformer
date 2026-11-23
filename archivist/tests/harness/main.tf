# Test harness: runs states_test.sh through the external data source so
# terraform test (and the repo-wide module test runner) picks it up.
data "external" "states_test" {
  program = ["bash", "${path.module}/../states_test.sh"]
}

output "status" {
  value = data.external.states_test.result.status
}

output "detail" {
  value = try(data.external.states_test.result.detail, "")
}
