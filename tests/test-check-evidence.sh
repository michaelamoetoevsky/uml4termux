#!/usr/bin/env bash
# tests/test-check-evidence.sh -- contract tests for ci/check-evidence.py.
#
# The interface splits two paths that are easy to confuse and that already bit
# this project in CI: positional arguments are FILES, a directory must be given
# with --dir. device-evidence.yml passed the directory as a file and the job
# died with "[Errno 21] Is a directory" while the records themselves were fine.
# Assert both paths so the failure cannot come back silently.
#
# Exit codes: 0 all assertions passed, 1 at least one failed.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT" || exit 1

passed=0
failed=0

ok() { printf 'PASS  %s\n' "$1"; passed=$((passed + 1)); }
no() { printf 'FAIL  %s\n' "$1"; failed=$((failed + 1)); }

check_python() {
  command -v python3 >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# 1. A directory passed as a positional file argument must FAIL loudly.
#    This is the exact failure the first GitHub run produced; keeping it a
#    documented, asserted behaviour stops a "fix" that would silently accept a
#    directory and validate only its name.
# ---------------------------------------------------------------------------
out=$(python3 ci/check-evidence.py --schema evidence/schema.json evidence 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'Is a directory'; then
  ok "directory-as-file is rejected with 'Is a directory' (rc=$rc)"
else
  no "directory-as-file rejection (rc=$rc): $out"
fi

# ---------------------------------------------------------------------------
# 2. --dir validates every record in the tree.
# ---------------------------------------------------------------------------
out=$(python3 ci/check-evidence.py --schema evidence/schema.json --dir evidence 2>&1)
rc=$?
if [ "$rc" -eq 0 ]; then
  ok "--dir validates all records"
else
  no "--dir validation failed (rc=$rc): $out"
fi

# ---------------------------------------------------------------------------
# 3. A malformed record is rejected (the schema gate is real).
# ---------------------------------------------------------------------------
tmp=$(mktemp -d "${TMPDIR:-/tmp}/uml-checkev.XXXXXX")
printf 'this is not json\n' >"$tmp/broken.json"
out=$(python3 ci/check-evidence.py --schema evidence/schema.json "$tmp/broken.json" 2>&1)
rc=$?
if [ "$rc" -ne 0 ]; then
  ok "malformed record rejected (rc=$rc)"
else
  no "malformed record was accepted"
fi
rm -rf "$tmp"

# ---------------------------------------------------------------------------
# 4. --list-fields works (used by the scaffolding self-test).
# ---------------------------------------------------------------------------
if python3 ci/check-evidence.py --list-fields >/dev/null 2>&1; then
  ok "--list-fields runs"
else
  no "--list-fields failed"
fi

echo ""
echo "passed: $passed  failed: $failed"
[ "$failed" -eq 0 ]
