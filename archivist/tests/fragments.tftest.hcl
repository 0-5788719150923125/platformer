# Archivist Tests - external fragments (user fragment_paths)
# The real assertions live in fragments_test.sh, which builds an archive in a
# throwaway git repo. This wraps it so terraform test reports the result.

run "external_fragments_are_archived" {
  command = plan

  module {
    source = "./tests/harness"
  }

  assert {
    condition     = output.status == "pass"
    error_message = "fragments_test.sh: ${output.detail}"
  }
}
