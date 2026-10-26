#!/usr/bin/env bash
# tests/ci-checks.sh -- self-test of the CI scaffolding.
#
# This is NOT the full device-side CI (that is ci/local-ci.sh). It validates
# the *metadata* of this repository: VERSION <-> CHANGELOG, required files
# exist, .gitignore covers the right patterns, workflows parse, the helper
# scripts run without error, and the evidence schema is self-consistent.
#
# Exit codes:
#   0   all checks that could run passed
#   1   a check genuinely failed
#   77  nothing was checkable (everything that ran was SKIP)
#
# Used by: make self-test, .github/workflows/ci.yml, .github/workflows/release.yml
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT" || exit 1

# Source shared helpers (CI_SKIP, ci_python_init, logging, etc.)
. "$ROOT/ci/lib.sh"
ci_python_init

passed=0
failed=0
skipped=0

record() {
  local status=$1; shift
  local name=$1; shift
  case "$status" in
    0)  printf 'PASS  %s\n' "$name"; passed=$((passed+1)) ;;
    1)  printf 'FAIL  %s\n' "$name"; failed=$((failed+1)) ;;
    77) printf 'SKIP  %s\n' "$name"; skipped=$((skipped+1)) ;;
    *)  printf '???   %s (status=%d)\n' "$name" "$status"; failed=$((failed+1)) ;;
  esac
}

run_check() {
  local name=$1; shift
  local out rc
  out=$("$@" 2>&1); rc=$?
  if [ "$rc" -eq 0 ]; then record 0 "$name"
  elif [ "$rc" -eq "$CI_SKIP" ]; then record 77 "$name"
  else
    record 1 "$name"
    printf '%s\n' "$out" | sed 's/^/    /'
  fi
}

# ---------------------------------------------------------------------------
# 1. VERSION <-> CHANGELOG
# ---------------------------------------------------------------------------
run_check "VERSION/CHANGELOG consistency" bash -c '
  set -euo pipefail
  version=$(tr -d " \t\r\n" < VERSION)
  [ -n "$version" ] || exit 1
  bash ci/changelog-extract.sh "$version" >/dev/null
'

# ---------------------------------------------------------------------------
# 2. Required scaffolding files exist
# ---------------------------------------------------------------------------
required=(
  VERSION
  CHANGELOG.md
  CONTRIBUTING.md
  SECURITY.md
  Makefile
  .gitignore
  .gitattributes
  .editorconfig
  ci/lib.sh
  ci/list-shell-files.sh
  ci/no-boot-guard.sh
  ci/changelog-extract.sh
  ci/yamlcheck.py
  ci/check-evidence.py
  ci/make-dist.sh
  ci/local-ci.sh
  tests/ci-checks.sh
  tests/test-check-evidence.sh
  tests/test_build_initramfs.py
  evidence/schema.json
  .github/workflows/ci.yml
  .github/workflows/release.yml
  .github/workflows/device-evidence.yml
)
run_check "required files exist" bash -c '
  set -euo pipefail
  missing=0
  for f in "${required[@]}"; do
    if [ ! -f "$f" ]; then
      echo "missing: $f"
      missing=1
    fi
  done
  exit $missing
'

# ---------------------------------------------------------------------------
# 3. .gitignore covers the required patterns (exact substrings)
# ---------------------------------------------------------------------------
run_check ".gitignore patterns" bash -c '
  set -euo pipefail
  patterns=("*.log" "evidence/*.raw.log" "*.ext4" "*.cpio" "*.cpio.gz" "bin/linux*" "gvproxy" "__pycache__/" "build/" "dist/" ".uml/" "tmp/")
  for p in "${patterns[@]}"; do
    if ! grep -qF "$p" .gitignore; then
      echo "missing pattern: $p"
      exit 1
    fi
  done
'

# ---------------------------------------------------------------------------
# 4. Workflow files parse (structural mode, no PyYAML required)
# ---------------------------------------------------------------------------
run_check "workflow YAML parses (structural)" bash -c '
  set -euo pipefail
  files=$(find .github/workflows -maxdepth 1 -type f \( -name "*.yml" -o -name "*.yaml" \) | sort)
  if [ -z "$files" ]; then exit '"$CI_SKIP"'; fi
  env -u LD_LIBRARY_PATH python3 ci/yamlcheck.py --mode structural --workflow $files
'

# ---------------------------------------------------------------------------
# 5. Evidence schema is a valid JSON Schema (builtin validator)
# ---------------------------------------------------------------------------
run_check "evidence/schema.json self-consistent" bash -c '
  set -euo pipefail
  python3 ci/check-evidence.py --list-fields >/dev/null
'

# ---------------------------------------------------------------------------
# 6. Helper scripts run without error
# ---------------------------------------------------------------------------
run_check "ci/changelog-extract.sh --help" bash -c 'bash ci/changelog-extract.sh --help >/dev/null'
run_check "ci/list-shell-files.sh runs" bash -c 'bash ci/list-shell-files.sh . >/dev/null'
run_check "ci/no-boot-guard.sh runs" bash -c 'bash ci/no-boot-guard.sh . >/dev/null'
run_check "ci/no-boot-guard.sh --help" bash -c 'bash ci/no-boot-guard.sh --help >/dev/null'
run_check "ci/make-dist.sh --help" bash -c 'bash ci/make-dist.sh --help >/dev/null'

# ---------------------------------------------------------------------------
# 7. ci/yamlcheck.py runs in structural mode
# ---------------------------------------------------------------------------
run_check "ci/yamlcheck.py structural mode" bash -c 'env -u LD_LIBRARY_PATH python3 ci/yamlcheck.py --mode structural .github/workflows/ci.yml >/dev/null'

# ---------------------------------------------------------------------------
# 8. ci/check-evidence.py structural validation
# ---------------------------------------------------------------------------
run_check "ci/check-evidence.py structural" bash -c '
  set -euo pipefail
  python3 ci/check-evidence.py --schema evidence/schema.json --list-fields >/dev/null
'

# ---------------------------------------------------------------------------
# 9. make dist dry-run (no tarball written, just script help)
# ---------------------------------------------------------------------------
run_check "make dist script help" bash -c 'bash ci/make-dist.sh --help >/dev/null'

# ---------------------------------------------------------------------------
# 10. ci/local-ci.sh runs (just the help / dry-run path)
# ---------------------------------------------------------------------------
run_check "ci/local-ci.sh --help" bash -c 'bash ci/local-ci.sh --help >/dev/null'

# ---------------------------------------------------------------------------
# 11. check-evidence.py contract: --dir versus a positional directory.
#     Regression test for the device-evidence.yml invocation bug that failed
#     the first GitHub run.
# ---------------------------------------------------------------------------
run_check "evidence checker contract (dir vs --dir)" bash -c 'bash tests/test-check-evidence.sh'

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=== SUMMARY ==="
echo "passed:  $passed"
echo "failed:  $failed"
echo "skipped: $skipped"
total=$((passed + failed + skipped))
echo "total:   $total"

if [ "$failed" -gt 0 ]; then
  exit 1
fi
if [ "$passed" -eq 0 ] && [ "$skipped" -gt 0 ]; then
  exit "$CI_SKIP"
fi
exit 0