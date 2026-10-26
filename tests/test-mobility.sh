#!/usr/bin/env bash
# tests/test-mobility.sh -- unit tests for lib/mobility.sh (wake lock).
#
# The wake lock is acquired by 'uml4termux boot/docker --wake-lock' and must be
# released by 'uml4termux stop'.  These tests use a stub termux-wake-lock on
# PATH so they run anywhere and never touch the real Android lock.
#
# Exit codes: 0 all assertions passed, 1 at least one failed.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT" || exit 1

passed=0
failed=0
# NOTE: lib/common.sh defines its own ok()/warn()/err() logging helpers and
# would shadow a test helper of the same name, so these are t_ok/t_no.
t_ok() { printf 'PASS  %s\n' "$1"; passed=$((passed + 1)); }
t_no() { printf 'FAIL  %s\n' "$1"; failed=$((failed + 1)); }

STUB="$HOME/.hermes/cache/scratch/wakelock-stub"
rm -rf "$STUB"; mkdir -p "$STUB"
cat >"$STUB/termux-wake-lock" <<'EOF'
#!/usr/bin/env bash
echo "locked" >>"${WAKELOCK_STUB_LOG}"
EOF
cat >"$STUB/termux-wake-unlock" <<'EOF'
#!/usr/bin/env bash
echo "unlocked" >>"${WAKELOCK_STUB_LOG}"
EOF
chmod +x "$STUB/termux-wake-lock" "$STUB/termux-wake-unlock"
export WAKELOCK_STUB_LOG="$STUB/log"

export PATH="$STUB:$PATH"
STUB_ORIGINAL_PATH="$PATH"
export UML4TERMUX_ROOT="$ROOT"
export UML4TERMUX_RUNTIME="$STUB/runtime"
mkdir -p "$UML4TERMUX_RUNTIME"
# shellcheck source=../lib/common.sh
. "$ROOT/lib/common.sh"
# shellcheck source=../lib/mobility.sh
. "$ROOT/lib/mobility.sh"

# 1. availability is detected through the stub
if uml4termux_wakelock_available; then
  t_ok "wakelock tool detected on PATH"
else
  t_no "wakelock tool not detected"
fi

# 2. acquire calls the tool and records the state
if uml4termux_wakelock_acquire >/dev/null 2>&1; then
  t_ok "acquire succeeded"
else
  t_no "acquire failed"
fi
grep -q '^locked$' "$WAKELOCK_STUB_LOG" && t_ok "termux-wake-lock was called" \
  || t_no "termux-wake-lock was not called"
uml4termux_wakelock_held && t_ok "state file records the lock" || t_no "state file missing"

# 3. release calls the tool and clears the state
if uml4termux_wakelock_release >/dev/null 2>&1; then
  t_ok "release succeeded"
else
  t_no "release failed"
fi
grep -q '^unlocked$' "$WAKELOCK_STUB_LOG" && t_ok "termux-wake-unlock was called" \
  || t_no "termux-wake-unlock was not called"
uml4termux_wakelock_held && t_no "state file still present after release" \
  || t_ok "state file cleared"

# 4. releasing twice is harmless (stop may run without a lock)
if uml4termux_wakelock_release >/dev/null 2>&1; then
  t_ok "release is idempotent"
else
  t_no "second release failed"
fi

# 5. a missing tool is reported, not fatal.  The PATH is reduced to the stub
#    directory alone: a real Termux installation has termux-wake-lock in
#    $PREFIX/bin, and this assertion is about the tool being absent.
rm -f "$STUB/termux-wake-lock" "$STUB/termux-wake-unlock"
PATH="$STUB"
export PATH
if uml4termux_wakelock_available; then
  t_no "availability still true without the tool"
else
  t_ok "availability false without the tool"
fi
uml4termux_wakelock_acquire >/dev/null 2>&1 && t_no "acquire should report failure" \
  || t_ok "acquire reports failure without the tool (non-zero, not a crash)"
uml4termux_wakelock_release >/dev/null 2>&1 && t_ok "release without the tool is harmless" \
  || t_no "release without the tool failed"

# restore a usable PATH before the cleanup below
PATH="${STUB_ORIGINAL_PATH}"
export PATH
rm -rf "$STUB"
echo ""
echo "passed: $passed  failed: $failed"
[ "$failed" -eq 0 ]
