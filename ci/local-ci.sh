#!/usr/bin/env bash
# ci/local-ci.sh -- run every CI check that is possible on *this device*.
#
# This is the single entry point a developer (or the device-side evidence
# script) calls to prove the repository is healthy before pushing.
#
# It uses ONLY tools present on a bare Termux/aarch64 device:
#   bash, python3 (via env -u LD_LIBRARY_PATH), tar, gzip, sha256sum, git
#   ShellCheck is OPTIONAL; when absent we degrade to bash -n with a notice
#
# Exit codes:
#   0  every check that ran passed
#   1  at least one check failed
#   77 every check was SKIP (nothing to check -- repo is empty/partial)
#
# The PASS/FAIL/SKIP table printed at the end is the contract.
#
# Usage: ci/local-ci.sh [--verbose] [--json]
set -uo pipefail

# Allow --help/-h to show usage and exit 0
case "${1:-}" in
  -h|--help)
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
esac

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT" || exit 1

# Source shared helpers
. "$ROOT/ci/lib.sh"
ci_python_init

VERBOSE=0
JSON_OUT=0
for arg in "$@"; do
  case "$arg" in
    -v|--verbose) VERBOSE=1 ;;
    --json) JSON_OUT=1 ;;
    -h|--help)
      sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "local-ci.sh: unknown option: $arg" >&2; exit 2 ;;
  esac
done

# ---------------------------------------------------------------------------
# Result aggregation
# ---------------------------------------------------------------------------
declare -a RESULTS_NAME=()
declare -a RESULTS_STATUS=()   # 0 pass, 1 fail, 77 skip
declare -a RESULTS_NOTE=()

add_result() {
  local status=$1; shift
  local name=$1; shift
  local note=${1:-}
  RESULTS_NAME+=("$name")
  RESULTS_STATUS+=("$status")
  RESULTS_NOTE+=("$note")
}

# ---------------------------------------------------------------------------
# 1. Shell syntax + lint
# ---------------------------------------------------------------------------
files=$(bash "$ROOT/ci/list-shell-files.sh" "$ROOT")
if [ -z "$files" ]; then
  add_result "$CI_SKIP" "shell: bash -n" "no shell files found"
else
  # bash -n
  fail=0
  for f in $files; do
    if ! bash -n "$f" 2>/dev/null; then
      add_result 1 "shell: bash -n" "$f"
      fail=1
    fi
  done
  if [ "$fail" -eq 0 ]; then
    count=$(printf '%s\n' $files | wc -l | tr -d ' ')
    add_result 0 "shell: bash -n" "$count file(s)"
  fi

  # ShellCheck
  if ci_have shellcheck; then
    fail=0
    mapfile -t arr < <(printf '%s\n' $files)
    # ShellCheck disable=SC2086  # $SHELLCHECK_EXCLUDE is intentionally word-split
    if shellcheck \
         --shell=bash \
         --severity="${SHELLCHECK_SEVERITY:-warning}" \
         --exclude="${SHELLCHECK_EXCLUDE:-SC1090,SC1091,SC2016,SC2034,SC2154,SC2317,SC2329}" \
         --color=auto \
         "${arr[@]}" 2>&1; then
      add_result 0 "shell: shellcheck" "${#arr[@]} file(s)"
    else
      add_result 1 "shell: shellcheck" "one or more files failed"
    fi
  else
    add_result "$CI_SKIP" "shell: shellcheck" "shellcheck not installed (bash -n only)"
  fi
fi

# ---------------------------------------------------------------------------
# 2. Python compile
# ---------------------------------------------------------------------------
py_files=$(find "$ROOT" -maxdepth 3 -type f -name '*.py' 2>/dev/null \
           | grep -vE '__pycache__|build|dist|tmp|\.uml' | sort)
if [ -z "$py_files" ]; then
  add_result "$CI_SKIP" "python: py_compile" "no Python files found"
else
  fail=0
  for f in $py_files; do
    if ! ci_py -m py_compile "$f" 2>/dev/null; then
      add_result 1 "python: py_compile" "$f"
      fail=1
    fi
  done
  if [ "$fail" -eq 0 ]; then
    count=$(printf '%s\n' $py_files | wc -l | tr -d ' ')
    add_result 0 "python: py_compile" "$count file(s)"
  fi
fi

# ---------------------------------------------------------------------------
# 3. Generator unit test (if generator exists)
# ---------------------------------------------------------------------------
gen="$ROOT/scripts/build-initramfs.py"
if [ -f "$gen" ]; then
  if ci_py "$ROOT/tests/test_build_initramfs.py" \
       --generator "$gen" --guest-dir "$ROOT/scripts/guest"; then
    add_result 0 "generator: unit test" "scripts/build-initramfs.py -> cpio re-parse"
  else
    rc=$?
    if [ "$rc" -eq "$CI_SKIP" ]; then
      add_result "$CI_SKIP" "generator: unit test" "generator did not produce a valid cpio.gz"
    else
      add_result 1 "generator: unit test" "exit $rc"
    fi
  fi
else
  add_result "$CI_SKIP" "generator: unit test" "scripts/build-initramfs.py not present yet"
fi

# ---------------------------------------------------------------------------
# 4. Workflow YAML parse (yamlcheck.py in auto mode)
# ---------------------------------------------------------------------------
wf_files=$(find "$ROOT/.github/workflows" -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) 2>/dev/null | sort)
if [ -z "$wf_files" ]; then
  add_result "$CI_SKIP" "workflows: yamlcheck" "no .github/workflows/*.yml files"
else
  if env -u LD_LIBRARY_PATH python3 "$ROOT/ci/yamlcheck.py" --mode auto --workflow $wf_files; then
    add_result 0 "workflows: yamlcheck" "$(printf '%s\n' $wf_files | wc -l | tr -d ' ') file(s)"
  else
    rc=$?
    if [ "$rc" -eq "$CI_SKIP" ]; then
      add_result "$CI_SKIP" "workflows: yamlcheck" "no files to validate"
    else
      add_result 1 "workflows: yamlcheck" "exit $rc"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 5. make dist (tarball + SHA256SUMS)
# ---------------------------------------------------------------------------
if [ -f "$ROOT/VERSION" ]; then
  if bash "$ROOT/ci/make-dist.sh" --outdir "$ROOT/dist"; then
    tarball=$(ls -1 "$ROOT/dist"/uml4termux-*.tar.gz 2>/dev/null | head -1)
    if [ -n "$tarball" ] && [ -f "$ROOT/dist/SHA256SUMS" ]; then
      add_result 0 "dist: make-dist.sh" "$(basename "$tarball") + SHA256SUMS"
    else
      add_result 1 "dist: make-dist.sh" "tarball or SHA256SUMS missing"
    fi
  else
    rc=$?
    if [ "$rc" -eq "$CI_SKIP" ]; then
      add_result "$CI_SKIP" "dist: make-dist.sh" "VERSION file missing or empty"
    else
      add_result 1 "dist: make-dist.sh" "exit $rc"
    fi
  fi
else
  add_result "$CI_SKIP" "dist: make-dist.sh" "VERSION file missing"
fi

# ---------------------------------------------------------------------------
# 6. Evidence schema check
# ---------------------------------------------------------------------------
ev_files=$(find "$ROOT/evidence" -maxdepth 1 -type f -name '*.json' 2>/dev/null \
           | grep -v schema.json | sort)
if [ -z "$ev_files" ]; then
  add_result "$CI_SKIP" "evidence: schema check" "no evidence/*.json records (see evidence/README.md)"
else
  if ci_py "$ROOT/ci/check-evidence.py" --schema "$ROOT/evidence/schema.json" $ev_files; then
    add_result 0 "evidence: schema check" "$(printf '%s\n' $ev_files | wc -l | tr -d ' ') record(s)"
  else
    rc=$?
    if [ "$rc" -eq "$CI_SKIP" ]; then
      add_result "$CI_SKIP" "evidence: schema check" "no records to validate"
    else
      add_result 1 "evidence: schema check" "exit $rc"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 7. Metadata consistency (VERSION <-> CHANGELOG, .gitignore patterns, etc.)
# ---------------------------------------------------------------------------
# Re-use tests/ci-checks.sh logic but inline for independence.
run_meta() {
  local name=$1; shift
  if bash -c "$*"; then
    add_result 0 "$name" "ok"
  else
    rc=$?
    if [ "$rc" -eq "$CI_SKIP" ]; then
      add_result "$CI_SKIP" "$name" "skipped by check"
    else
      add_result 1 "$name" "exit $rc"
    fi
  fi
}

run_meta "meta: VERSION/CHANGELOG" '
  set -euo pipefail
  version=$(tr -d " \t\r\n" < '"$ROOT/VERSION"')
  [ -n "$version" ] || exit 1
  bash '"$ROOT/ci/changelog-extract.sh"' "$version" >/dev/null
'

run_meta "meta: required files" '
  set -euo pipefail
  req=(VERSION CHANGELOG.md CONTRIBUTING.md SECURITY.md Makefile .gitignore .gitattributes .editorconfig
       ci/lib.sh ci/list-shell-files.sh ci/no-boot-guard.sh ci/changelog-extract.sh ci/yamlcheck.py
       ci/check-evidence.py ci/make-dist.sh ci/local-ci.sh tests/ci-checks.sh tests/test_build_initramfs.py
       evidence/schema.json .github/workflows/ci.yml .github/workflows/release.yml .github/workflows/device-evidence.yml)
  for f in "${req[@]}"; do [ -f "$f" ] || exit 1; done
'

run_meta "meta: .gitignore patterns" '
  set -euo pipefail
  pat=("*.log" "evidence/*.raw.log" "*.ext4" "*.cpio" "*.cpio.gz" "bin/linux*" "gvproxy" "__pycache__/" "build/" "dist/" ".uml/" "tmp/")
  for p in "${pat[@]}"; do grep -qF "$p" '"$ROOT/.gitignore"' || exit 1; done
'

run_meta "meta: workflow YAML structural" '
  set -euo pipefail
  files=$(find '"$ROOT/.github/workflows"' -maxdepth 1 -type f \( -name "*.yml" -o -name "*.yaml" \) | sort)
  [ -n "$files" ] || exit '"$CI_SKIP"'
  env -u LD_LIBRARY_PATH python3 '"$ROOT/ci/yamlcheck.py"' --mode structural --workflow $files
'

run_meta "meta: evidence/schema.json valid" '
  set -euo pipefail
  python3 '"$ROOT/ci/check-evidence.py"' --list-fields >/dev/null
'

# ---------------------------------------------------------------------------
# 7b. Rust: unit tests + daemon parity (skipped when the toolchain is absent)
# ---------------------------------------------------------------------------
run_meta "rust: cargo test+clippy" '
  set -euo pipefail
  command -v cargo >/dev/null 2>&1 || exit 77
  cd '"$ROOT/rust"'
  cargo test --release --quiet
  cargo clippy --all-targets --release --quiet -- -D warnings 2>/dev/null || \
    cargo clippy --all-targets --release -- -D warnings >/dev/null
'

run_meta "rust: daemon parity (C vs Rust)" '
  set -euo pipefail
  [ -x '"$ROOT"'/rust/target/release/uml4termux-rs ] || exit 77
  bash '"$ROOT"'/ci/verify-daemon-parity.sh >/dev/null
'

# ---------------------------------------------------------------------------
# 8. Print summary table and exit
# ---------------------------------------------------------------------------
print_table() {
  local fmt="%-8s  %-36s  %s\n"
  printf "$fmt" "STATUS" "CHECK" "NOTE"
  printf "$fmt" "------" "------------------------------" "----"
  local i=0
  local pass=0 fail=0 skip=0
  while [ "$i" -lt "${#RESULTS_NAME[@]}" ]; do
    local status=${RESULTS_STATUS[$i]}
    local label
    case "$status" in
      0) label="PASS"; pass=$((pass+1)) ;;
      1) label="FAIL"; fail=$((fail+1)) ;;
      77) label="SKIP"; skip=$((skip+1)) ;;
      *) label="???"; fail=$((fail+1)) ;;
    esac
    printf "$fmt" "$label" "${RESULTS_NAME[$i]}" "${RESULTS_NOTE[$i]}"
    i=$((i + 1))
  done
  printf "$fmt" "------" "------------------------------" "----"
  printf "$fmt" "TOTAL" "pass=$pass fail=$fail skip=$skip" ""
  # Counts are published through a global so the caller can use them for the
  # exit code without having to pipe the table (which would swallow it).
  PASS_COUNT=$pass
  FAIL_COUNT=$fail
  SKIP_COUNT=$skip
}

if [ "$JSON_OUT" -eq 1 ]; then
  # Minimal JSON for CI consumers
  printf '{"results":['
  first=1
  for i in "${!RESULTS_NAME[@]}"; do
    if [ "$first" -eq 1 ]; then first=0; else printf ','; fi
    status=${RESULTS_STATUS[$i]}
    case "$status" in 0) s="pass";; 1) s="fail";; 77) s="skip";; *) s="unknown";; esac
    printf '{"check":"%s","status":"%s","note":"%s"}' "${RESULTS_NAME[$i]}" "$s" "${RESULTS_NOTE[$i]}"
  done
  printf ']}\n'
  # Count for the exit code
  PASS_COUNT=0; FAIL_COUNT=0; SKIP_COUNT=0
  for st in "${RESULTS_STATUS[@]}"; do
    case "$st" in
      0) PASS_COUNT=$((PASS_COUNT+1)) ;;
      1) FAIL_COUNT=$((FAIL_COUNT+1)) ;;
      77) SKIP_COUNT=$((SKIP_COUNT+1)) ;;
    esac
  done
else
  print_table
fi

# Exit code logic
if [ "${FAIL_COUNT:-0}" -gt 0 ]; then
  exit 1
fi
if [ "${PASS_COUNT:-0}" -eq 0 ] && [ "${SKIP_COUNT:-0}" -gt 0 ]; then
  exit "$CI_SKIP"
fi
exit 0