# Tests

Root-level test suites and the module test runner.

## Running

```bash
terraform test                                          # all tests
terraform test -filter='tests/integration.tftest.hcl'   # single suite
terraform test -verbose                                 # detailed output
```

## Test Suites

**integration.tftest.hcl** — Cross-module interaction tests (networking, compute, applications, config management, archorchestrator). Uses test-specific state fragments from `tests/states/`.

**all_module_tests.tftest.hcl** — Discovers and runs every module's own test suite via `local-exec`. Modules with a `tests/*.tftest.hcl` directory are picked up automatically.

**variables.tftest.hcl** — Input validation rules (profile format, region format).

## Test State Fragments

`tests/states/` contains state fragments used exclusively by tests. The config module searches `states/` first, then `tests/states/`, so test fragments are isolated from production configurations.
