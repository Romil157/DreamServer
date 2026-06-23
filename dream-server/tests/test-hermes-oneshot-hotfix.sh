#!/bin/bash
# Contract + functional tests for the Hermes KeyError hotfix (#1497).
#
# Validates that:
#   1. The hotfix module + .pth file exist in the expected locations
#   2. The compose.yaml mounts both into the venv's site-packages
#   3. The compose.yaml command is the clean `gateway run` (no shell wrapper)
#   4. The hotfix module is syntactically valid Python
#   5. The bootstrap-upgrade.sh references the issue in its warm-up log
#   6. (Functional) The patch actually intercepts Agent.chat in-process

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

HOTFIX="$ROOT_DIR/extensions/services/hermes/dream_hotfix_1497.py"
PTH="$ROOT_DIR/extensions/services/hermes/dream-hotfix-1497.pth"
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

echo "=== Hermes KeyError hotfix (#1497) contract tests ==="
echo ""

# ── File existence ──────────────────────────────────────────────────────

# 1. Hotfix module exists
if [[ -f "$HOTFIX" ]]; then
    pass "dream_hotfix_1497.py exists"
else
    fail "dream_hotfix_1497.py not found at $HOTFIX"
fi

# 2. .pth file exists
if [[ -f "$PTH" ]]; then
    pass "dream-hotfix-1497.pth exists"
else
    fail "dream-hotfix-1497.pth not found at $PTH"
fi

# ── Syntax check ────────────────────────────────────────────────────────

# 3. Hotfix module is valid Python
_py_cmd=""
if python3 --version >/dev/null 2>&1; then
    _py_cmd="python3"
elif python --version >/dev/null 2>&1; then
    _py_cmd="python"
fi
if [[ -n "$_py_cmd" ]] \
   && $_py_cmd -c "import py_compile, sys; py_compile.compile(sys.argv[1], doraise=True)" "$HOTFIX" 2>/dev/null; then
    pass "dream_hotfix_1497.py is syntactically valid Python"
else
    fail "dream_hotfix_1497.py has Python syntax errors"
fi

# ── Content checks ──────────────────────────────────────────────────────

# 4. Module contains the key fix — catching KeyError for 'final_response'
if grep -qF 'final_response' "$HOTFIX" \
   && grep -qF 'KeyError' "$HOTFIX"; then
    pass "hotfix module handles KeyError for 'final_response'"
else
    fail "hotfix module does not reference KeyError/final_response"
fi

# 5. Module has idempotency guard
if grep -qF '_dream_hotfix_1497' "$HOTFIX"; then
    pass "hotfix module has idempotency guard"
else
    fail "hotfix module missing idempotency guard (_dream_hotfix_1497)"
fi

# 6. Module installs a sys.meta_path hook (in-process patching)
if grep -qF 'sys.meta_path' "$HOTFIX"; then
    pass "hotfix module uses sys.meta_path (in-process hook)"
else
    fail "hotfix module does not use sys.meta_path"
fi

# 7. .pth file imports the hotfix module
if grep -qF 'import dream_hotfix_1497' "$PTH"; then
    pass ".pth file imports dream_hotfix_1497"
else
    fail ".pth file does not import dream_hotfix_1497"
fi

# ── Compose wiring ──────────────────────────────────────────────────────

# 8. Compose mounts the hotfix module into site-packages
if grep -qF 'dream_hotfix_1497.py' "$COMPOSE" \
   && grep -qF 'site-packages/dream_hotfix_1497.py' "$COMPOSE"; then
    pass "compose.yaml mounts hotfix module into site-packages"
else
    fail "compose.yaml does not mount hotfix module into site-packages"
fi

# 9. Compose mounts the .pth file into site-packages
if grep -qF 'dream-hotfix-1497.pth' "$COMPOSE" \
   && grep -qF 'site-packages/dream-hotfix-1497.pth' "$COMPOSE"; then
    pass "compose.yaml mounts .pth file into site-packages"
else
    fail "compose.yaml does not mount .pth file into site-packages"
fi

# 10. Compose command is clean gateway run (no sh -c wrapper)
#     The old broken approach ran `sh -c 'python hotfix.py; exec hermes gateway run'`
#     which patched a throwaway process. The fix uses .pth for in-process patching
#     so the command should be the clean `gateway run`.
if grep -qF '- gateway' "$COMPOSE" \
   && grep -qF '- run' "$COMPOSE" \
   && ! grep -qF 'oneshot-keyerror-hotfix' "$COMPOSE"; then
    pass "compose.yaml command is clean 'gateway run' (no shell wrapper)"
else
    fail "compose.yaml command is not the expected clean 'gateway run'"
fi

# 11. No reference to the old oneshot script (fully replaced)
if ! grep -qF 'oneshot-keyerror-hotfix.py' "$COMPOSE"; then
    pass "compose.yaml has no reference to old oneshot-keyerror-hotfix.py"
else
    fail "compose.yaml still references old oneshot-keyerror-hotfix.py"
fi

# ── Bootstrap ───────────────────────────────────────────────────────────

# 12. Bootstrap upgrade references issue #1497 in warm-up failure log
if grep -qF '#1497' "$BOOTSTRAP"; then
    pass "bootstrap-upgrade.sh references issue #1497 in warm-up log"
else
    fail "bootstrap-upgrade.sh does not reference #1497"
fi

# ── Functional test ─────────────────────────────────────────────────────
# This is the critical test the old script missed: prove the patch actually
# intercepts Agent.chat IN THE SAME PROCESS that would handle chat requests.
# We create a fake run_agent.Agent with a .chat() that raises
# KeyError('final_response'), import dream_hotfix_1497, then verify
# the patched .chat() returns "" instead of raising.

echo ""
echo "--- Functional: in-process monkey-patch verification ---"

if [[ -z "$_py_cmd" ]]; then
    fail "SKIPPED functional test: no Python interpreter found"
else
    _func_result=$($_py_cmd -c "
import sys, types, os

# 1. Create a fake run_agent module with Agent.chat that raises KeyError
fake_run_agent = types.ModuleType('run_agent')

class FakeAgent:
    def chat(self, prompt, *args, **kwargs):
        # Simulates the upstream bug: result['final_response'] on a
        # response dict that has no 'final_response' key.
        raise KeyError('final_response')

fake_run_agent.Agent = FakeAgent
sys.modules['run_agent'] = fake_run_agent

# 2. Import the hotfix — this should install the meta_path hook.
#    Since run_agent is already in sys.modules, the hook won't fire
#    on import. We call apply() directly to patch.
sys.path.insert(0, os.path.dirname('$HOTFIX'))
hotfix_dir = os.path.dirname(os.path.abspath('$HOTFIX'))
sys.path.insert(0, hotfix_dir)
import dream_hotfix_1497
patched = dream_hotfix_1497.apply()

if not patched:
    print('FAIL: apply() returned False — patch was not applied')
    sys.exit(1)

# 3. Verify the patch is active on the SAME Agent class
agent = FakeAgent()
try:
    result = agent.chat('test prompt')
except KeyError:
    print('FAIL: Agent.chat still raises KeyError after patching')
    sys.exit(1)

if result != '':
    print('FAIL: expected empty string, got: ' + repr(result))
    sys.exit(1)

# 4. Verify idempotency — second apply() should be a no-op
second = dream_hotfix_1497.apply()
if second:
    print('FAIL: second apply() should return False (idempotent)')
    sys.exit(1)

# 5. Verify unrelated KeyErrors still propagate
class AgentOtherError:
    def chat(self, prompt, *args, **kwargs):
        raise KeyError('some_other_key')

fake_run_agent.Agent = AgentOtherError
third = dream_hotfix_1497.apply()
if third:
    agent2 = AgentOtherError()
    try:
        agent2.chat('test')
        print('FAIL: unrelated KeyError was swallowed')
        sys.exit(1)
    except KeyError:
        pass  # correct — unrelated KeyErrors propagate

print('OK')
" 2>/dev/null)

    if [[ "$_func_result" == "OK" ]]; then
        pass "functional: monkey-patch intercepts KeyError('final_response') in-process"
    else
        fail "functional: $_func_result"
    fi
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
