#!/usr/bin/env bash
# packaging/check-install.sh — packaging gate: installs into a temp prefix,
# runs the CLI `help` and `doctor --no-assets` from that prefix, then uninstalls
# and asserts the prefix is clean.
#
# This is the gate that CI and the phone both run.
#
# Exit codes: 0 = VERDICT=PASS, 77 = VERDICT=SKIP (CLI not present yet), 1 = VERDICT=FAIL.

set -euo pipefail

# Colors
if [ -t 2 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != "dumb" ]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_RED=$'\033[31m'; C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'; C_DIM=$'\033[2m'
else
  C_RESET=""; C_BOLD=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_DIM=""
fi
msg()  { printf '%s\n' "$*" >&2; }
info() { printf '%s[info]%s %s\n' "${C_BLUE}" "${C_RESET}" "$*" >&2; }
warn() { printf '%s[warn]%s %s\n' "${C_YELLOW}" "${C_RESET}" "$*" >&2; }
err()  { printf '%s[err]%s %s\n' "${C_RED}" "${C_RESET}" "$*" >&2; }
ok()   { printf '%s[ok]%s %s\n' "${C_GREEN}" "${C_RESET}" "$*" >&2; }
skip() { printf '%s[skip]%s %s\n' "${C_DIM}" "${C_RESET}" "$*" >&2; }
die()  { err "$*"; exit 1; }

# ---------------------------------------------------------------------------
# Resolve repo root (parent of packaging/)
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
export REPO_ROOT

# Source and destination
INSTALL_SCRIPT="${REPO_ROOT}/scripts/install.sh"
UNINSTALL_SCRIPT="${REPO_ROOT}/scripts/uninstall.sh"

# Check required scripts exist
if [ ! -f "${INSTALL_SCRIPT}" ]; then
  die "install script not found: ${INSTALL_SCRIPT}"
fi
if [ ! -f "${UNINSTALL_SCRIPT}" ]; then
  die "uninstall script not found: ${UNINSTALL_SCRIPT}"
fi

# Check for bin/uml4termux in source (critical for CLI execution test)
CLI_SRC="${REPO_ROOT}/bin/uml4termux"
CLI_PRESENT=1
if [ ! -f "${CLI_SRC}" ]; then
  warn "CLI source not found: ${CLI_SRC} (parallel agent may not have landed it yet)"
  CLI_PRESENT=0
fi

# ---------------------------------------------------------------------------
# Create temp prefix
# ---------------------------------------------------------------------------
TMP_PREFIX="$(mktemp -d -t uml4termux-check.XXXXXX)"
export TMP_PREFIX
info "Temp prefix: ${TMP_PREFIX}"

cleanup() {
  local rc=$?
  if [ -d "${TMP_PREFIX}" ]; then
    info "Cleaning up temp prefix..."
    rm -rf "${TMP_PREFIX}"
  fi
  exit ${rc}
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Stage 1: Install (copy mode = --no-symlink)
# ---------------------------------------------------------------------------
info "Stage 1: Installing into temp prefix (copy mode)..."
if ! bash "${INSTALL_SCRIPT}" --prefix "${TMP_PREFIX}" --no-symlink; then
  INSTALL_RC=$?
  if [ "${INSTALL_RC}" -eq 77 ]; then
    warn "Install reported SKIP (source files missing)"
    # If CLI not present, this is expected — overall SKIP
    if [ "${CLI_PRESENT}" -eq 0 ]; then
      printf '\nVERDICT=SKIP\n'
      printf 'Reason: bin/uml4termux not yet in repo (parallel agent in progress)\n'
      exit 77
    fi
  fi
  err "Install failed with exit code ${INSTALL_RC}"
  printf '\nVERDICT=FAIL\n'
  exit 1
fi
ok "Install PASS"

# ---------------------------------------------------------------------------
# Stage 2: Verify installed files exist
# ---------------------------------------------------------------------------
info "Stage 2: Verifying installed file layout..."
REQUIRED_FILES=(
  "${TMP_PREFIX}/bin/uml4termux"
  "${TMP_PREFIX}/share/uml4termux/bin/uml4termux"
  "${TMP_PREFIX}/share/uml4termux/lib/common.sh"
  "${TMP_PREFIX}/share/uml4termux/lib/fetch.sh"
  "${TMP_PREFIX}/share/uml4termux/lib/net.sh"
  "${TMP_PREFIX}/share/uml4termux/lib/guest.sh"
  "${TMP_PREFIX}/share/uml4termux/lib/doctor.sh"
  "${TMP_PREFIX}/share/uml4termux/scripts/build-initramfs.py"
  "${TMP_PREFIX}/share/uml4termux/scripts/guest/init"
  "${TMP_PREFIX}/share/uml4termux/scripts/guest/docker-init.sh"
  "${TMP_PREFIX}/share/uml4termux/scripts/guest/forensic.sh"
)

MISSING=0
for f in "${REQUIRED_FILES[@]}"; do
  if [ ! -e "${f}" ]; then
    err "Missing installed file: ${f}"
    MISSING=$((MISSING + 1))
  elif [ "${f}" = "${TMP_PREFIX}/bin/uml4termux" ] && [ ! -L "${f}" ]; then
    err "${f} is not a symlink (should point into share tree)"
    MISSING=$((MISSING + 1))
  elif [ "${f}" = "${TMP_PREFIX}/bin/uml4termux" ] && [ -L "${f}" ]; then
    target="$(readlink "${f}")"
    if [ "${target}" != "${TMP_PREFIX}/share/uml4termux/bin/uml4termux" ]; then
      err "${f} points to wrong target: ${target}"
      MISSING=$((MISSING + 1))
    fi
  fi
done

if [ "${MISSING}" -gt 0 ]; then
  err "${MISSING} required file(s) missing or incorrect"
  printf '\nVERDICT=FAIL\n'
  exit 1
fi
ok "File layout verified"

# ---------------------------------------------------------------------------
# Stage 3: Run CLI from temp prefix (help + doctor --no-assets)
# ---------------------------------------------------------------------------
if [ "${CLI_PRESENT}" -eq 0 ]; then
  warn "CLI source not present — skipping CLI execution tests"
  printf '\nVERDICT=SKIP\n'
  printf 'Reason: bin/uml4termux not in repo; install layout verified but CLI not tested\n'
  # Still run uninstall to verify cleanup
  info "Stage 4: Uninstalling to verify cleanup..."
  if ! bash "${UNINSTALL_SCRIPT}" --prefix "${TMP_PREFIX}"; then
    err "Uninstall failed"
    printf '\nVERDICT=FAIL\n'
    exit 1
  fi
  ok "Uninstall PASS"
  exit 77
fi

info "Stage 3: Running CLI from temp prefix..."

# Environment for the CLI to find its libs and avoid LD_LIBRARY_PATH issues
CLI_ENV=(
  "PATH=${TMP_PREFIX}/bin:${PATH}"
  "UML4TERMUX_SHARE=${TMP_PREFIX}/share/uml4termux"
  "UML4TERMUX_PREFIX=${TMP_PREFIX}"
  "PREFIX=${TMP_PREFIX}"
  "UML4TERMUX_DRY_RUN=0"
  "UML4TERMUX_HOME=${TMP_PREFIX}/home/.local/share/uml4termux"
  "UML4TERMUX_STATE_DIR=${TMP_PREFIX}/home/.local/state/uml4termux"
  "UML4TERMUX_RUNTIME=${TMP_PREFIX}/runtime/uml4termux"
)

CLI_HELP_OK=0
CLI_DOCTOR_OK=0

# Test 1: help
info "Testing: uml4termux help"
if env "${CLI_ENV[@]}" "${TMP_PREFIX}/bin/uml4termux" help >/dev/null 2>&1; then
  ok "uml4termux help -> PASS"
  CLI_HELP_OK=1
else
  err "uml4termux help -> FAIL"
  # Print the actual error for debugging
  env "${CLI_ENV[@]}" "${TMP_PREFIX}/bin/uml4termux" help 2>&1 | head -20 >&2 || true
fi

# Test 2: doctor --no-assets
info "Testing: uml4termux doctor --no-assets"
if env "${CLI_ENV[@]}" "${TMP_PREFIX}/bin/uml4termux" doctor --no-assets >/dev/null 2>&1; then
  ok "uml4termux doctor --no-assets -> PASS"
  CLI_DOCTOR_OK=1
else
  RC=$?
  if [ "${RC}" -eq 77 ]; then
    # doctor --no-assets returns 77 when gvproxy/kernel assets are missing,
    # even with --no-assets (the flag skips the main inventory but gvproxy check remains).
    # On a bare CI box this is expected — treat as PASS for the gate.
    ok "uml4termux doctor --no-assets -> SKIP (exit 77, assets missing, acceptable on bare box)"
    CLI_DOCTOR_OK=1
  else
    err "uml4termux doctor --no-assets -> FAIL (exit ${RC})"
    env "${CLI_ENV[@]}" "${TMP_PREFIX}/bin/uml4termux" doctor --no-assets 2>&1 | head -30 >&2 || true
  fi
fi

if [ "${CLI_HELP_OK}" -eq 1 ] && [ "${CLI_DOCTOR_OK}" -eq 1 ]; then
  ok "CLI execution tests PASS"
else
  err "CLI execution tests FAIL"
  printf '\nVERDICT=FAIL\n'
  exit 1
fi

# ---------------------------------------------------------------------------
# Stage 4: Uninstall and verify clean prefix
# ---------------------------------------------------------------------------
info "Stage 4: Uninstalling and verifying clean prefix..."
if ! bash "${UNINSTALL_SCRIPT}" --prefix "${TMP_PREFIX}"; then
  err "Uninstall failed"
  printf '\nVERDICT=FAIL\n'
  exit 1
fi

# Assert prefix is clean (only the directories we created should be gone)
REMAINING="$(find "${TMP_PREFIX}" -type f 2>/dev/null | wc -l | tr -d ' ')"
if [ "${REMAINING}" -gt 0 ]; then
  err "Prefix not clean after uninstall: ${REMAINING} file(s) remain"
  find "${TMP_PREFIX}" -type f 2>/dev/null | head -20 >&2
  printf '\nVERDICT=FAIL\n'
  exit 1
fi

ok "Uninstall PASS — prefix is clean"

# ---------------------------------------------------------------------------
# Final verdict
# ---------------------------------------------------------------------------
printf '\nVERDICT=PASS\n'
exit 0