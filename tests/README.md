# Tests

Root-level test suites and the module test runner.

## Running

```bash
terraform test                                          # all tests
terraform test -filter='tests/integration.tftest.hcl'   # single suite
terraform test -verbose                                 # detailed output
```

## Test Suites

**integration.tftest.hcl** - Cross-module interaction tests (networking, compute, applications, config management, iorchestrator). Uses test-specific fragments from `tests/fragments/`.

**all_module_tests.tftest.hcl** - Discovers and runs every module's own test suite via `local-exec`. Modules with a `tests/*.tftest.hcl` directory are picked up automatically.

**fragment_paths.tftest.hcl** - Root wiring for `fragment_paths`: a relative user path resolves against the repo root, wins over `tests/fragments/`, and reaches the catalog. Module-level cases live in `config/tests`, `workspaces/tests` and `archivist/tests`.

**variables.tftest.hcl** - Input validation rules (profile format, region format).

## Test Fragments

`tests/fragments/` contains fragments used exclusively by tests. The config module searches any user `fragment_paths` first, then `fragments/`, then `tests/fragments/`, so test fragments are isolated from production configurations. Tests set `workspace_overrides = false` and leave `fragment_paths` empty, so local configs never leak in.
