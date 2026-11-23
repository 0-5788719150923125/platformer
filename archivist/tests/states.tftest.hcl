# Archivist Tests - external state fragments (user states_paths)
# The real assertions live in states_test.sh, which builds an archive in a
# throwaway git repo. This wraps it so terraform test reports the result.

run "external_states_are_archived" {
  command = plan

  module {
    source = "./tests/harness"
  }

  assert {
    condition     = output.status == "pass"
    error_message = "states_test.sh: ${output.detail}"
  }
}
