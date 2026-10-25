#!/usr/bin/env bash
# scripts/uninstall.sh — remove uml4termux from a Termux prefix.
# Idempotent. Safe to run twice.
#
# Usage: scripts/uninstall.sh [--prefix DIR] [--purge-data] [-h|--help]
#
# --prefix DIR     Installation prefix (default: $PREFIX or /usr)
# --purge-data     Also remove ~/.local/share/uml4termux (user data directory).
#                  Default: keep user data (only removes package files).
# -h, --help       This text.
#
# Exit codes: 0 = PASS (removed cleanly), 1 = FAIL.

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

usage() {
  cat <<'EOF'
scripts/uninstall.sh — remove uml4termux from a Termux prefix.

Usage: scripts/uninstall.sh [--prefix DIR] [--purge-data] [-h|--help]

  --prefix DIR     Installation prefix (default: $PREFIX or /usr)
  --purge-data     Also remove ~/.local/share/uml4termux (user data directory).
                   Default: keep user data (only removes package files).
  -h, --help       This text.

Exit codes: 0 = PASS (removed cleanly), 1 = FAIL.
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
PREFIX_ARG="${PREFIX:-}"
PURGE_DATA=0

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) PREFIX_ARG="${2:-}"; shift 2 ;;
    --purge-data) PURGE_DATA=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

# ---------------------------------------------------------------------------
# Resolve destination prefix
# ---------------------------------------------------------------------------
if [ -z "${PREFIX_ARG}" ]; then
  if [ -n "${PREFIX:-}" ]; then
    PREFIX_ARG="${PREFIX}"
  elif command -v bash >/dev/null 2>&1; then
    _bash_path="$(command -v bash)"
    _cand="$(cd "$(dirname "${_bash_path}")/.." 2>/dev/null && pwd || true)"
    case "${_cand}" in
      */com.termux/files/usr) PREFIX_ARG="${_cand}" ;;
      *) PREFIX_ARG="/usr" ;;
    esac
  else
    PREFIX_ARG="/usr"
  fi
fi
PREFIX="$(cd "${PREFIX_ARG}" 2>/dev/null && pwd || echo "${PREFIX_ARG}")"

DEST_BIN="${PREFIX}/bin"
DEST_SHARE="${PREFIX}/share/uml4termux"

info "PREFIX=${PREFIX}"
info "DEST_BIN=${DEST_BIN}"
info "DEST_SHARE=${DEST_SHARE}"

# ---------------------------------------------------------------------------
# Files to remove (mirrors install.sh FILE_SPECS)
# ---------------------------------------------------------------------------
FILES_TO_REMOVE=(
  "${DEST_BIN}/uml4termux"
  "${DEST_SHARE}/lib/common.sh"
  "${DEST_SHARE}/lib/fetch.sh"
  "${DEST_SHARE}/lib/net.sh"
  "${DEST_SHARE}/lib/guest.sh"
  "${DEST_SHARE}/lib/doctor.sh"
  "${DEST_SHARE}/scripts/build-initramfs.py"
  "${DEST_SHARE}/scripts/guest/init"
  "${DEST_SHARE}/scripts/guest/docker-init.sh"
  "${DEST_SHARE}/scripts/guest/forensic.sh"
  "${DEST_SHARE}/bin/uml4termux"
)

# ---------------------------------------------------------------------------
# Removal
# ---------------------------------------------------------------------------
REMOVE_FAILS=0
for f in "${FILES_TO_REMOVE[@]}"; do
  if [ -e "${f}" ] || [ -L "${f}" ]; then
    info "removing ${f}"
    if ! rm -f "${f}"; then
      err "failed to remove ${f}"
      REMOVE_FAILS=$((REMOVE_FAILS + 1))
    fi
  else
    skip "not present: ${f}"
  fi
done

# Remove empty directories (bottom-up)
for d in \
  "${DEST_SHARE}/scripts/guest" \
  "${DEST_SHARE}/scripts" \
  "${DEST_SHARE}/lib" \
  "${DEST_SHARE}/bin" \
  "${DEST_SHARE}"; do
  if [ -d "${d}" ] && [ -z "$(ls -A "${d}" 2>/dev/null || true)" ]; then
    info "removing empty directory ${d}"
    rmdir "${d}" 2>/dev/null || warn "could not remove ${d} (not empty?)"
  fi
done

# ---------------------------------------------------------------------------
# Optional: purge user data directory
# ---------------------------------------------------------------------------
if [ "${PURGE_DATA}" = "1" ]; then
  UML4TERMUX_HOME="${UML4TERMUX_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/uml4termux}"
  if [ -d "${UML4TERMUX_HOME}" ]; then
    info "purging user data: ${UML4TERMUX_HOME}"
    if ! rm -rf "${UML4TERMUX_HOME}"; then
      err "failed to purge ${UML4TERMUX_HOME}"
      REMOVE_FAILS=$((REMOVE_FAILS + 1))
    fi
  else
    skip "user data not present: ${UML4TERMUX_HOME}"
  fi

  UML4TERMUX_STATE_DIR="${UML4TERMUX_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/uml4termux}"
  if [ -d "${UML4TERMUX_STATE_DIR}" ]; then
    info "purging user state: ${UML4TERMUX_STATE_DIR}"
    if ! rm -rf "${UML4TERMUX_STATE_DIR}"; then
      err "failed to purge ${UML4TERMUX_STATE_DIR}"
      REMOVE_FAILS=$((REMOVE_FAILS + 1))
    fi
  fi
else
  info "keeping user data (use --purge-data to remove)"
fi

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------
info "Verifying removal..."
VERIFY_FAILS=0
for f in "${FILES_TO_REMOVE[@]}"; do
  if [ -e "${f}" ] || [ -L "${f}" ]; then
    err "still present after uninstall: ${f}"
    VERIFY_FAILS=$((VERIFY_FAILS + 1))
  fi
done

if [ "${PURGE_DATA}" = "1" ]; then
  UML4TERMUX_HOME="${UML4TERMUX_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/uml4termux}"
  UML4TERMUX_STATE_DIR="${UML4TERMUX_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/uml4termux}"
  for d in "${UML4TERMUX_HOME}" "${UML4TERMUX_STATE_DIR}"; do
    if [ -d "${d}" ]; then
      err "user data still present after --purge-data: ${d}"
      VERIFY_FAILS=$((VERIFY_FAILS + 1))
    fi
  done
fi

if [ "${REMOVE_FAILS}" -gt 0 ] || [ "${VERIFY_FAILS}" -gt 0 ]; then
  err "UNINSTALL FAIL: ${REMOVE_FAILS} removal error(s), ${VERIFY_FAILS} verification failure(s)"
  exit 1
else
  ok "UNINSTALL PASS: all package files removed"
  exit 0
fi