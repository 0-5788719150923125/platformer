#!/bin/bash
# Runs terraform test for a single module
# Usage: run-single-module-test.sh <platformer-root> <module-name>

set -e

if [ $# -ne 2 ]; then
  echo "Usage: $0 <platformer-root> <module-name>"
  exit 1
fi

PLATFORMER_ROOT="$1"
MODULE="$2"

echo ""
echo "========================================"
echo "Testing module: $MODULE"
echo "Started at: $(date)"
echo "========================================"
echo ""

cd "$PLATFORMER_ROOT"

if [ ! -d "$MODULE/tests" ]; then
  echo "✗ No tests/ directory found in $MODULE"
  exit 1
fi

# Count test files
test_count=$(ls -1 "$MODULE/tests/"*.tftest.hcl 2>/dev/null | wc -l)
echo "Found $test_count test file(s) in $MODULE"
echo ""

# CD into module directory to run tests
cd "$MODULE"

# Initialize providers
echo "Initializing providers..."
if ! terraform init -upgrade > /dev/null 2>&1; then
  echo "✗ terraform init failed in $MODULE"
  exit 1
fi

echo ""
echo "Running tests..."
echo ""

# Run terraform test
if terraform test; then
  echo ""
  echo "========================================"
  echo "✓ $MODULE tests passed"
  echo "Finished at: $(date)"
  echo "========================================"
  echo ""
  exit 0
else
  echo ""
  echo "========================================"
  echo "✗ $MODULE tests failed"
  echo "Finished at: $(date)"
  echo "========================================"
  echo ""
  exit 1
fi
