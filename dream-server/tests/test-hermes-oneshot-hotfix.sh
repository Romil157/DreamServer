#!/bin/bash
# Contract tests for the Hermes oneshot KeyError hotfix (#1497).
#
# Validates that:
#   1. The hotfix script exists in the expected location
#   2. The compose.yaml mounts it into the container
#   3. The compose.yaml command invokes it before the gateway
#   4. The hotfix script is syntactically valid Python
#   5. The bootstrap-upgrade.sh references the issue in its warm-up log

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

HOTFIX="$ROOT_DIR/extensions/services/hermes/oneshot-keyerror-hotfix.py"
COMPOSE="$ROOT_DIR/extensions/services/hermes/compose.yaml"
BOOTSTRAP="$ROOT_DIR/scripts/bootstrap-upgrade.sh"

PASS=0
FAIL=0

pass() {
    echo "  ✓ $1"
    PASS=$((PASS + 1))
}

fail() {
    echo "  ✗ $1"
    FAIL=$((FAIL + 1))
}

echo "=== Hermes oneshot KeyError hotfix (#1497) contract tests ==="
echo ""

# 1. Hotfix script exists
if [[ -f "$HOTFIX" ]]; then
    pass "oneshot-keyerror-hotfix.py exists"
else
    fail "oneshot-keyerror-hotfix.py not found at $HOTFIX"
fi

# 2. Hotfix script is valid Python
_py_cmd=""
if python3 --version >/dev/null 2>&1; then
    _py_cmd="python3"
elif python --version >/dev/null 2>&1; then
    _py_cmd="python"
fi
if [[ -n "$_py_cmd" ]] \
   && $_py_cmd -c "import py_compile, sys; py_compile.compile(sys.argv[1], doraise=True)" "$HOTFIX" 2>/dev/null; then
    pass "oneshot-keyerror-hotfix.py is syntactically valid Python"
else
    fail "oneshot-keyerror-hotfix.py has Python syntax errors"
fi

# 3. Hotfix script contains the key fix — catching KeyError for 'final_response'
if grep -qF 'final_response' "$HOTFIX" \
   && grep -qF 'KeyError' "$HOTFIX"; then
    pass "hotfix script handles KeyError for 'final_response'"
else
    fail "hotfix script does not reference KeyError/final_response"
fi

# 4. Hotfix script is idempotent (double-patch guard)
if grep -qF '_dream_hotfix_1497' "$HOTFIX"; then
    pass "hotfix script has idempotency guard"
else
    fail "hotfix script missing idempotency guard (_dream_hotfix_1497)"
fi

# 5. Compose mounts the hotfix script
if grep -qF 'oneshot-keyerror-hotfix.py' "$COMPOSE"; then
    pass "compose.yaml mounts oneshot-keyerror-hotfix.py"
else
    fail "compose.yaml does not mount oneshot-keyerror-hotfix.py"
fi

# 6. Compose mounts at the expected container path
if grep -qF '/opt/hermes/docker/oneshot-keyerror-hotfix.py' "$COMPOSE"; then
    pass "compose.yaml mounts at /opt/hermes/docker/oneshot-keyerror-hotfix.py"
else
    fail "compose.yaml mount path is wrong (expected /opt/hermes/docker/...)"
fi

# 7. Compose command invokes the hotfix before gateway
if grep -qF 'oneshot-keyerror-hotfix.py' "$COMPOSE" \
   && grep -qF 'exec /opt/hermes/.venv/bin/hermes gateway run' "$COMPOSE"; then
    pass "compose.yaml command applies hotfix then execs into gateway"
else
    fail "compose.yaml command does not invoke hotfix before gateway"
fi

# 8. Bootstrap upgrade references issue #1497 in warm-up failure log
if grep -qF '#1497' "$BOOTSTRAP"; then
    pass "bootstrap-upgrade.sh references issue #1497 in warm-up log"
else
    fail "bootstrap-upgrade.sh does not reference #1497"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
