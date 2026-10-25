#!/usr/bin/env bash
# ci/lib.sh -- shared helpers for the uml4termux CI scaffolding.
#
# This file is *sourced*, never executed directly:
#
#   . "$(dirname "$0")/lib.sh"
#
# It is deliberately dependency-free (no jq, no pyyaml, no python imports beyond
# the standard library) so that it works both on a GitHub runner and on a bare
# Termux/aarch64 device with no root.
#
# shellcheck shell=bash

# ---------------------------------------------------------------------------
# Exit-code contract
#
# Every check in this project's CI tooling reports exactly one of:
#
#   0   PASS  -- the check ran and succeeded
#   1   FAIL  -- the check ran and genuinely failed
#   77  SKIP  -- the check could not run because the file/asset it needs does
#                not exist yet (parallel agents may not have written it)
#
# 77 is used instead of a silent 0 so that a missing path can never be
# mistaken for a pass. A run in which *everything* was skipped exits 77, not 0.
# ---------------------------------------------------------------------------
CI_SKIP=77

# Resolve the repository root (the directory holding VERSION/Makefile) from a
# path inside the repo. Prints an absolute path.
ci_root() {
  local d
  d=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd) || return 1
  printf '%s\n' "$d"
}

# ci_have <command> -- true when <command> is on PATH and executable.
ci_have() {
  command -v "$1" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Python discovery
#
# On some Termux/bash setups `python3` only works when LD_LIBRARY_PATH is
# cleared (a stray LD_LIBRARY_PATH from a Jupyter/conda-ish environment breaks
# the dynamic loader for CPython's own lib-dynload extensions). GitHub runners
# are unaffected by `env -u`. We therefore probe, in order:
#
#   1. env -u LD_LIBRARY_PATH python3   (the Termux-safe form)
#   2. python3                          (the plain, CI form)
#   3. a few versioned/unversioned fallbacks
#
# CI_PY is an array so that the "env -u ..." form can be word-split safely.
# ---------------------------------------------------------------------------
CI_PY=()

ci_python_init() {
  local cand
  CI_PY=()
  for cand in "env -u LD_LIBRARY_PATH python3" "python3" "python3.14" "python3.13" \
              "python3.12" "python3.11" "python3.10" "python"; do
    # shellcheck disable=SC2086  # $cand is intentionally word-split
    if $cand -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 8) else 1)' \
        >/dev/null 2>&1; then
      # shellcheck disable=SC2206  # intentional word splitting into an array
      CI_PY=($cand)
      return 0
    fi
  done
  return 1
}

# ci_py <args...> -- run the discovered interpreter. Requires ci_python_init.
ci_py() {
  if [ "${#CI_PY[@]}" -eq 0 ]; then
    echo "ci/lib.sh: ci_python_init was not called" >&2
    return 1
  fi
  "${CI_PY[@]}" "$@"
}

# ci_py_desc -- human-readable form of the discovered interpreter (for tables).
ci_py_desc() {
  if [ "${#CI_PY[@]}" -eq 0 ]; then
    printf '%s\n' '<none>'
  else
    printf '%s\n' "${CI_PY[*]}"
  fi
}

# ci_py_import <module> -- true when the discovered interpreter can import it.
ci_py_import() {
  ci_py -c "import $1" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  CI_C_OK=$'\033[32m'; CI_C_ERR=$'\033[31m'; CI_C_WARN=$'\033[33m'
  CI_C_DIM=$'\033[2m'; CI_C_OFF=$'\033[0m'
else
  CI_C_OK=''; CI_C_ERR=''; CI_C_WARN=''; CI_C_DIM=''; CI_C_OFF=''
fi

ci_note() { printf '%s\n' "$*"; }
ci_dim()  { printf '%s%s%s\n' "$CI_C_DIM" "$*" "$CI_C_OFF"; }
ci_warn() { printf '%sWARN%s  %s\n' "$CI_C_WARN" "$CI_C_OFF" "$*" >&2; }
ci_err()  { printf '%sERROR%s %s\n' "$CI_C_ERR" "$CI_C_OFF" "$*" >&2; }

# ci_require_files <f1> [f2...] -- true only if every path exists.
ci_require_files() {
  local p
  for p in "$@"; do
    [ -e "$p" ] || return 1
  done
  return 0
}

# ci_first_existing <f1> [f2...] -- print the first existing path, else nothing.
ci_first_existing() {
  local p
  for p in "$@"; do
    if [ -e "$p" ]; then
      printf '%s\n' "$p"
      return 0
    fi
  done
  return 1
}
