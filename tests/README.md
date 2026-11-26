# Tests

Root-level test suites and the module test runner.

## Running

```bash
terraform test                                          # all tests
terraform test -filter='tests/integration.tftest.hcl'   # single suite
terraform test -verbose                                 # detailed output
```

## Test Suites

**integration.tftest.hcl** - Cross-module interaction tests (networking, compute, applications, config management, iorchestrator). Uses test-specific state fragments from `tests/states/`.

**all_module_tests.tftest.hcl** - Discovers and runs every module's own test suite via `local-exec`. Modules with a `tests/*.tftest.hcl` directory are picked up automatically.

**states_paths.tftest.hcl** - Root wiring for `states_paths`: a relative user path resolves against the repo root, wins over `tests/states/`, and reaches the catalog. Module-level cases live in `config/tests`, `workspaces/tests` and `archivist/tests`.

**variables.tftest.hcl** - Input validation rules (profile format, region format).

## Test State Fragments

`tests/states/` contains state fragments used exclusively by tests. The config module searches any user `states_paths` first, then `states/`, then `tests/states/`, so test fragments are isolated from production configurations. Tests set `workspace_overrides = false` and leave `states_paths` empty, so local configs never leak in.
