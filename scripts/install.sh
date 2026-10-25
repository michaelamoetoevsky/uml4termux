#!/usr/bin/env bash
# scripts/install.sh — install uml4termux into a Termux prefix.
# Idempotent. Safe to run twice. Does NOT touch ~/.local/share/uml4termux.
#
# Usage: scripts/install.sh [--prefix DIR] [--no-symlink] [--dry-run] [-h|--help]
#
# --prefix DIR     Installation prefix (default: $PREFIX or /usr)
# --no-symlink     Install real copies into $PREFIX/share/uml4termux/ and make
#                  $PREFIX/bin/uml4termux a symlink into that tree.
#                  Default: symlink everything back into the source repo (dev mode).
# --dry-run        Print what would be done without writing anything.
# -h, --help       This text.
#
# Exit codes: 0 = PASS (all expected files installed and verified),
#             77 = SKIP (some source files missing — CLI not landed yet?),
#             1 = FAIL (verification failure or prefix not writable).

set -euo pipefail

# Colors for output
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
scripts/install.sh — install uml4termux into a Termux prefix.

Usage: scripts/install.sh [--prefix DIR] [--no-symlink] [--dry-run] [-h|--help]

  --prefix DIR     Installation prefix (default: $PREFIX or /usr)
  --no-symlink     Install real copies into $PREFIX/share/uml4termux/ and make
                   $PREFIX/bin/uml4termux a symlink into that tree.
                   Default: symlink everything back into the source repo (dev mode).
  --dry-run        Print what would be done without writing anything.
  -h, --help       This text.

Exit codes: 0 = PASS (all expected files installed and verified),
            77 = SKIP (some source files missing),
            1 = FAIL (verification failure or prefix not writable).
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
PREFIX_ARG="${PREFIX:-}"
NO_SYMLINK=0
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) PREFIX_ARG="${2:-}"; shift 2 ;;
    --no-symlink) NO_SYMLINK=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

# ---------------------------------------------------------------------------
# Resolve source root (directory containing this script's parent)
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
export SRC_ROOT

# Resolve destination prefix
if [ -z "${PREFIX_ARG}" ]; then
  if [ -n "${PREFIX:-}" ]; then
    PREFIX_ARG="${PREFIX}"
  elif command -v bash >/dev/null 2>&1; then
    # Try to derive from bash location (Termux style)
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
export PREFIX

DEST_BIN="${PREFIX}/bin"
DEST_SHARE="${PREFIX}/share/uml4termux"

info "SRC_ROOT=${SRC_ROOT}"
info "PREFIX=${PREFIX}"
info "DEST_BIN=${DEST_BIN}"
info "DEST_SHARE=${DEST_SHARE}"
[ "${DRY_RUN}" = "1" ] && info "DRY-RUN mode: no changes will be written"

# ---------------------------------------------------------------------------
# Define the file set to install
# Each entry: "src_glob|dest_subdir|mode|is_executable"
# dest_subdir is relative to DEST_SHARE (or "bin" for DEST_BIN)
# ---------------------------------------------------------------------------
# Note: order matters for summary output; critical file first.
FILE_SPECS=(
  "bin/uml4termux|bin|0755|1"
  "lib/*.sh|lib|0644|0"
  "scripts/build-initramfs.py|scripts|0755|1"
  "scripts/guest/init|scripts/guest|0755|1"
  "scripts/guest/docker-init.sh|scripts/guest|0755|1"
  "scripts/guest/forensic.sh|scripts/guest|0755|1"
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
run() {
  if [ "${DRY_RUN}" = "1" ]; then
    printf '+ %s\n' "$*"
  else
    "$@"
  fi
}

install_one() {
  local src_path="$1" dest_path="$2" mode="$3" is_exec="$4"
  local dest_dir
  dest_dir="$(dirname "${dest_path}")"

  if [ "${DRY_RUN}" = "1" ]; then
    printf 'DRY-RUN: install -Dm%s %s %s\n' "${mode}" "${src_path}" "${dest_path}"
    return 0
  fi

  run mkdir -p "${dest_dir}"
  if [ "${NO_SYMLINK}" = "1" ]; then
    # Copy mode: real files
    run cp -f "${src_path}" "${dest_path}"
    run chmod "${mode}" "${dest_path}"
  else
    # Symlink mode: link back to source
    run ln -sfn "${src_path}" "${dest_path}"
  fi
}

verify_one() {
  local dest_path="$1" is_exec="$2" src_rel="$3"
  local status="PASS" details=""

  # Existence (follow symlinks)
  if [ ! -e "${dest_path}" ]; then
    status="FAIL"
    details="missing after install"
  elif [ "${is_exec}" = "1" ] && [ ! -x "${dest_path}" ]; then
    status="FAIL"
    details="not executable (mode $(stat -c '%a' "${dest_path}" 2>/dev/null || echo '?'))"
  elif [ "${NO_SYMLINK}" = "1" ] && [ -L "${dest_path}" ]; then
    # In copy mode, dest should not be a symlink (except the bin entry symlink we create intentionally)
    if [ "$(basename "${dest_path}")" = "uml4termux" ] && [ "$(dirname "${dest_path}")" = "${DEST_BIN}" ]; then
      # This is the expected bin symlink into share tree — OK
      :
    else
      status="FAIL"
      details="unexpected symlink in copy mode"
    fi
  fi

  # Syntax checks (only for real files, not symlinks to source in dev mode)
  if [ "${status}" = "PASS" ] && [ "${NO_SYMLINK}" = "1" ] && [ -f "${dest_path}" ]; then
    case "${dest_path}" in
      *.sh)
        if ! bash -n "${dest_path}" 2>/dev/null; then
          status="FAIL"
          details="bash -n failed (syntax error)"
        fi
        ;;
      *.py)
        # Use env -u LD_LIBRARY_PATH python3 compile check (no file write)
        if ! env -u LD_LIBRARY_PATH python3 -c 'import sys; compile(open(sys.argv[1], "rb").read(), sys.argv[1], "exec")' "${dest_path}" 2>/dev/null; then
          status="FAIL"
          details="python compile failed (syntax error)"
        fi
        ;;
    esac
  fi

  printf '%s  %s\n' "${status}" "${dest_path}"
  if [ -n "${details}" ]; then
    printf '       %s\n' "${details}"
  fi

  case "${status}" in
    PASS) return 0 ;;
    FAIL) return 1 ;;
    *) return 2 ;;
  esac
}

# ---------------------------------------------------------------------------
# Main install loop
# ---------------------------------------------------------------------------
info "Installing files..."
INSTALL_FAILS=0
SKIP_COUNT=0
INSTALLED_FILES=()  # array of "dest_path|is_exec|src_rel"

for spec in "${FILE_SPECS[@]}"; do
  IFS='|' read -r src_glob dest_subdir mode is_exec <<<"${spec}"

  # Expand glob in source tree
  # shellcheck disable=SC2086
  for src_file in ${SRC_ROOT}/${src_glob}; do
    if [ ! -e "${src_file}" ]; then
      # Source file missing — this is a SKIP, not a FAIL
      skip "source missing: ${src_glob} (has the parallel agent landed it?)"
      SKIP_COUNT=$((SKIP_COUNT + 1))
      continue
    fi

    rel_src="${src_file#${SRC_ROOT}/}"
    if [ "${dest_subdir}" = "bin" ]; then
      dest_file="${DEST_BIN}/$(basename "${src_file}")"
    else
      dest_file="${DEST_SHARE}/${dest_subdir}/$(basename "${src_file}")"
    fi

    install_one "${src_file}" "${dest_file}" "${mode}" "${is_exec}"
    INSTALLED_FILES+=("${dest_file}|${is_exec}|${rel_src}")
  done
done

# ---------------------------------------------------------------------------
# In copy mode, ensure $PREFIX/bin/uml4termux is a symlink into the share tree
# so the CLI's self-location logic finds libs at ../lib
# ---------------------------------------------------------------------------
if [ "${NO_SYMLINK}" = "1" ] && [ "${DRY_RUN}" = "0" ]; then
  run mkdir -p "${DEST_BIN}" "${DEST_SHARE}/bin"
  # Install the CLI into share/bin (the canonical location for self-location)
  if [ -e "${DEST_BIN}/uml4termux" ] && [ ! -e "${DEST_SHARE}/bin/uml4termux" ]; then
    run cp -f "${DEST_BIN}/uml4termux" "${DEST_SHARE}/bin/uml4termux"
    run chmod 0755 "${DEST_SHARE}/bin/uml4termux"
    INSTALLED_FILES+=("${DEST_SHARE}/bin/uml4termux|1|bin/uml4termux (share copy)")
  fi
  # Make bin/uml4termux a symlink into share tree
  run ln -sfn "${DEST_SHARE}/bin/uml4termux" "${DEST_BIN}/uml4termux"
  INSTALLED_FILES+=("${DEST_BIN}/uml4termux|1|bin/uml4termux (symlink to share)")
elif [ "${NO_SYMLINK}" = "1" ] && [ "${DRY_RUN}" = "1" ]; then
  printf 'DRY-RUN: cp %s/bin/uml4termux %s/bin/uml4termux\n' "${DEST_BIN}" "${DEST_SHARE}"
  printf 'DRY-RUN: ln -sfn %s/bin/uml4termux %s/uml4termux\n' "${DEST_SHARE}" "${DEST_BIN}"
fi

# ---------------------------------------------------------------------------
# Prune stale files under DEST_SHARE (only known subdirs) — keeps install idempotent
# Only runs in copy mode; in symlink mode the symlinks just update.
# ---------------------------------------------------------------------------
if [ "${NO_SYMLINK}" = "1" ] && [ "${DRY_RUN}" = "0" ]; then
  # Known files under share (by basename)
  declare -A KNOWN_BASENAMES=()
  for spec in "${FILE_SPECS[@]}"; do
    IFS='|' read -r src_glob dest_subdir mode is_exec <<<"${spec}"
    # shellcheck disable=SC2086
    for src_file in ${SRC_ROOT}/${src_glob}; do
      [ -e "${src_file}" ] && KNOWN_BASENAMES["$(basename "${src_file}")"]=1
    done
  done
  # Also the bin in share
  KNOWN_BASENAMES["uml4termux"]=1

  for subdir in lib scripts scripts/guest; do
    dir="${DEST_SHARE}/${subdir}"
    [ -d "${dir}" ] || continue
    for f in "${dir}"/*; do
      [ -e "${f}" ] || continue
      [ -f "${f}" ] || continue  # only prune regular files, not directories
      bn="$(basename "${f}")"
      if [ -z "${KNOWN_BASENAMES[${bn}]:-}" ]; then
        info "pruning stale file: ${f}"
        run rm -f "${f}"
      fi
    done
  done
fi

# ---------------------------------------------------------------------------
# Verification pass
# ---------------------------------------------------------------------------
if [ "${DRY_RUN}" = "0" ]; then
  info "Verifying installed files..."
  VERIFY_FAILS=0
  for entry in "${INSTALLED_FILES[@]}"; do
    IFS='|' read -r dest_path is_exec src_rel <<<"${entry}"
    if ! verify_one "${dest_path}" "${is_exec}" "${src_rel}"; then
      VERIFY_FAILS=$((VERIFY_FAILS + 1))
    fi
  done

  # Summary
  echo
  if [ "${VERIFY_FAILS}" -gt 0 ]; then
    err "INSTALL FAIL: ${VERIFY_FAILS} file(s) failed verification"
    exit 1
  elif [ "${SKIP_COUNT}" -gt 0 ]; then
    warn "INSTALL SKIP: ${SKIP_COUNT} source file(s) missing (expected files not yet in repo)"
    exit 77
  else
    ok "INSTALL PASS: all files installed and verified"
    exit 0
  fi
else
  # Dry run always exits 0 (it's just a plan)
  echo
  info "DRY-RUN complete (no changes made)"
  exit 0
fi