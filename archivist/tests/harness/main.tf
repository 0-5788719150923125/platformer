# Test harness: runs fragments_test.sh through the external data source so
# terraform test (and the repo-wide module test runner) picks it up.
data "external" "fragments_test" {
  program = ["bash", "${path.module}/../fragments_test.sh"]
}

output "status" {
  value = data.external.fragments_test.result.status
}

output "detail" {
  value = try(data.external.fragments_test.result.detail, "")
}
