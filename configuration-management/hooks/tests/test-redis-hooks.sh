#!/bin/bash
# Unit tests for Redis hooks
# Simple test framework - no external dependencies required

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS_DIR="$SCRIPT_DIR/../linux"

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Test helper functions
test_start() {
  echo ""
  echo "TEST: $1"
  TESTS_RUN=$((TESTS_RUN + 1))
}

test_pass() {
  echo -e "${GREEN}✓ PASS${NC}: $1"
  TESTS_PASSED=$((TESTS_PASSED + 1))
}

test_fail() {
  echo -e "${RED}✗ FAIL${NC}: $1"
  TESTS_FAILED=$((TESTS_FAILED + 1))
}

echo "==========================================="
echo "Redis Patch Hooks Unit Tests"
echo "==========================================="

# Test 1: Pre-patch hook skips when Redis not installed
test_start "Pre-patch hook skips when Redis not installed"
if output=$(bash "$HOOKS_DIR/pre/10-redis-failover.sh" 2>&1); then
  if echo "$output" | grep -q "Redis not installed"; then
    test_pass "Hook correctly skips when Redis not installed"
  else
    test_fail "Expected 'Redis not installed' message, got: $output"
  fi
else
  test_fail "Hook failed with exit code $?"
fi

# Test 2: Pre-patch hook script has correct permissions
test_start "Pre-patch hook script is executable"
if [ -x "$HOOKS_DIR/pre/10-redis-failover.sh" ]; then
  test_pass "Pre-patch hook is executable"
else
  test_fail "Pre-patch hook is not executable"
fi

# Test 3: Pre-patch hook script has correct shebang
test_start "Pre-patch hook has correct shebang"
if head -1 "$HOOKS_DIR/pre/10-redis-failover.sh" | grep -q "^#!/bin/bash"; then
  test_pass "Pre-patch hook has correct shebang"
else
  test_fail "Pre-patch hook missing bash shebang"
fi

# Test 4: Pre-patch hook has proper error handling
test_start "Pre-patch hook uses 'set -e' for error handling"
if grep -q "^set -e" "$HOOKS_DIR/pre/10-redis-failover.sh"; then
  test_pass "Pre-patch hook has proper error handling"
else
  test_fail "Pre-patch hook missing 'set -e'"
fi

# Test 5: Post-patch hook skips when Redis not installed
test_start "Post-patch hook skips when Redis not installed"
if output=$(bash "$HOOKS_DIR/post/10-redis-validation.sh" 2>&1); then
  if echo "$output" | grep -q "Redis not installed"; then
    test_pass "Hook correctly skips when Redis not installed"
  else
    test_fail "Expected 'Redis not installed' message, got: $output"
  fi
else
  test_fail "Hook failed with exit code $?"
fi

# Test 6: Post-patch hook script has correct permissions
test_start "Post-patch hook script is executable"
if [ -x "$HOOKS_DIR/post/10-redis-validation.sh" ]; then
  test_pass "Post-patch hook is executable"
else
  test_fail "Post-patch hook is not executable"
fi

# Test 7: Post-patch hook script has correct shebang
test_start "Post-patch hook has correct shebang"
if head -1 "$HOOKS_DIR/post/10-redis-validation.sh" | grep -q "^#!/bin/bash"; then
  test_pass "Post-patch hook has correct shebang"
else
  test_fail "Post-patch hook missing bash shebang"
fi

# Test 8: Post-patch hook has proper error handling
test_start "Post-patch hook uses 'set -e' for error handling"
if grep -q "^set -e" "$HOOKS_DIR/post/10-redis-validation.sh"; then
  test_pass "Post-patch hook has proper error handling"
else
  test_fail "Post-patch hook missing 'set -e'"
fi

# Test 9: Pre-patch summary script executes successfully
test_start "Pre-patch summary script executes"
if output=$(bash "$HOOKS_DIR/pre/99-summary.sh" 2>&1); then
  if echo "$output" | grep -q "ready for patching"; then
    test_pass "Pre-patch summary executes successfully"
  else
    test_fail "Expected 'ready for patching' message"
  fi
else
  test_fail "Summary script failed with exit code $?"
fi

# Test 10: Post-patch summary script executes
test_start "Post-patch summary script executes"
if output=$(bash "$HOOKS_DIR/post/99-summary.sh" 2>&1); then
  if echo "$output" | grep -q "ready for production traffic"; then
    test_pass "Post-patch summary executes successfully"
  else
    test_fail "Expected 'ready for production traffic' message"
  fi
else
  test_fail "Summary script failed with exit code $?"
fi

# Test 11: Hook scripts are properly numbered for execution order
test_start "Hook scripts use numeric prefixes for ordering"
pre_count=$(ls "$HOOKS_DIR/pre/" | grep -c "^[0-9]")
post_count=$(ls "$HOOKS_DIR/post/" | grep -c "^[0-9]")
if [ "$pre_count" -gt 0 ] && [ "$post_count" -gt 0 ]; then
  test_pass "Hook scripts properly numbered ($pre_count pre, $post_count post)"
else
  test_fail "Hook scripts not properly numbered"
fi

# Test 12: All hook scripts exit 0 on success (no Redis installed)
test_start "All hooks exit with code 0 when Redis not present"
EXIT_CODE=0
for script in "$HOOKS_DIR/pre"/*.sh "$HOOKS_DIR/post"/*.sh; do
  if ! bash "$script" > /dev/null 2>&1; then
    EXIT_CODE=$?
    test_fail "Script $(basename $script) failed with exit code $EXIT_CODE"
    break
  fi
done
if [ $EXIT_CODE -eq 0 ]; then
  test_pass "All hooks exit successfully when Redis not present"
fi

# Test 13: Pre-patch hook detects standalone vs clustered Redis
test_start "Pre-patch hook correctly identifies deployment topology"
# This test validates the logic exists, even though we can't test actual Redis behavior
if grep -q "connected_slaves" "$HOOKS_DIR/pre/10-redis-failover.sh" && \
   grep -q "Standalone master" "$HOOKS_DIR/pre/10-redis-failover.sh" && \
   grep -q "Sentinel available" "$HOOKS_DIR/pre/10-redis-failover.sh"; then
  test_pass "Pre-patch hook has logic to detect standalone vs clustered Redis"
else
  test_fail "Pre-patch hook missing topology detection logic"
fi

# Print summary
echo ""
echo "==========================================="
echo "Test Summary"
echo "==========================================="
echo "Tests run:    $TESTS_RUN"
echo -e "Tests passed: ${GREEN}$TESTS_PASSED${NC}"
if [ $TESTS_FAILED -gt 0 ]; then
  echo -e "Tests failed: ${RED}$TESTS_FAILED${NC}"
  exit 1
else
  echo -e "Tests failed: $TESTS_FAILED"
  echo ""
  echo -e "${GREEN}All tests passed!${NC}"
  exit 0
fi
