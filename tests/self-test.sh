#!/usr/bin/env bash
#
# tests/self-test.sh — runnable on a plain Linux/CI box (no device required).
# Checks: bash -n on all shell files, python generator produces valid cpio,
# bin/uml4termux help, doctor --no-assets, docker --dry-run.
#
# SPDX-License-Identifier: GPL-2.0-only

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export UML4TERMUX_ROOT="${ROOT}"
export UML4TERMUX_HOME="${UML4TERMUX_HOME:-/tmp/uml4termux-test-assets}"
export UML4TERMUX_STATE_DIR="/tmp/uml4termux-test-state"
export UML4TERMUX_LOG_DIR="${UML4TERMUX_STATE_DIR}/logs"
export UML4TERMUX_RUNTIME="/tmp/uml4termux-test-runtime"
export UML4TERMUX_DRY_RUN=1
export PATH="${ROOT}/bin:${PATH}"

# Use the correct python invocation (Termux needs env -u LD_LIBRARY_PATH)
if env -u LD_LIBRARY_PATH python3 -c 'import sys' >/dev/null 2>&1; then
  PY="env -u LD_LIBRARY_PATH python3"
else
  PY="python3"
fi

FAIL=0
SKIP=0

msg()  { printf '[self-test] %s\n' "$*"; }
ok()   { printf '[self-test] \033[32mOK\033[0m %s\n' "$*"; }
warn() { printf '[self-test] \033[33mSKIP\033[0m %s\n' "$*"; SKIP=$((SKIP+1)); }
err()  { printf '[self-test] \033[31mFAIL\033[0m %s\n' "$*" >&2; FAIL=$((FAIL+1)); }

run() {
  if [ "$#" -eq 0 ]; then return 1; fi
  "$@"
}

# 1. bash -n on every shell file
msg "checking shell syntax (bash -n)..."
mapfile -t shell_files < <(find "${ROOT}" -type f \( -name '*.sh' -o -name 'uml4termux' \) ! -path '*/.git/*' 2>/dev/null)
for f in "${shell_files[@]}"; do
  if bash -n "${f}"; then
    ok "bash -n ${f#${ROOT}/}"
  else
    err "bash -n ${f#${ROOT}/}"
  fi
done

# 2. python generator on temp dir -> validate cpio
msg "testing python initramfs builder..."
TMPDIR="$(mktemp -d -t uml4termux-selftest-XXXXXX)"
trap 'rm -rf '"${TMPDIR}" EXIT
OUT_CPIO="${TMPDIR}/initramfs-test.cpio.gz"
GUEST_DIR="${ROOT}/scripts/guest"
BUILDER="${ROOT}/scripts/build-initramfs.py"

if ! ${PY} -m py_compile "${BUILDER}"; then
  err "python -m py_compile ${BUILDER}"
else
  ok "python syntax ${BUILDER}"
fi

if ${PY} "${BUILDER}" --guest-dir "${GUEST_DIR}" --out "${OUT_CPIO}" \
     --mode gate --entry /forensic.sh \
     --define GUEST_IP=192.168.127.2 \
     --define GUEST_GW=192.168.127.1 \
     --define GUEST_DNS=192.168.127.1 \
     --define WEB_PORTS="8123 8124" \
     --define GUEST_LIFETIME=0 \
     --force; then
  ok "builder ran without base initramfs"
else
  err "builder failed"
fi

# Validate the produced cpio (magic 070701, entries /init and /forensic.sh, trailer)
if [ -f "${OUT_CPIO}" ]; then
  cat >"${TMPDIR}/validate_cpio.py" <<'PYEOF'
import gzip, sys, struct
path = sys.argv[1]
data = gzip.open(path, 'rb').read()
off = 0
names = set()
while off + 110 <= len(data):
    if data[off:off+6] != b'070701':
        print('BAD magic at', off, file=sys.stderr)
        sys.exit(1)
    def f(i): return int(data[off+6+i*8:off+6+(i+1)*8], 16)
    fsize = f(6); namesize = f(11)
    off += 110
    name = data[off:off+namesize-1].decode('utf-8', 'replace')
    off += namesize; off = (off+3)&~3
    off += fsize; off = (off+3)&~3
    names.add(name)
    if name == 'TRAILER!!!':
        break
print('found entries:', sorted(names))
required = {'init', 'forensic.sh'}
missing = required - names
if missing:
    print('MISSING:', missing, file=sys.stderr)
    sys.exit(1)
if 'TRAILER!!!' not in names:
    print('NO TRAILER', file=sys.stderr)
    sys.exit(1)
print('CPIO VALID')
PYEOF
  if ${PY} "${TMPDIR}/validate_cpio.py" "${OUT_CPIO}"; then
    ok "generated cpio validates (magic, init, forensic.sh, trailer)"
  else
    err "generated cpio validation failed"
  fi
fi

# 3. bin/uml4termux help
msg "testing 'uml4termux help'..."
if run uml4termux help >/dev/null; then
  ok "uml4termux help"
else
  err "uml4termux help"
fi

# 4. bin/uml4termux doctor --no-assets
msg "testing 'uml4termux doctor --no-assets'..."
if run uml4termux doctor --no-assets >/dev/null; then
  ok "uml4termux doctor --no-assets (exit=$?)"
else
  rc=$?
  if [ $rc -eq 77 ]; then
    warn "uml4termux doctor --no-assets exited 77 (expected SKIP)"
  else
    err "uml4termux doctor --no-assets exited $rc"
  fi
fi

# 5. bin/uml4termux version
msg "testing 'uml4termux version'..."
if run uml4termux version >/dev/null; then
  ok "uml4termux version"
else
  err "uml4termux version"
fi

# 6. bin/uml4termux docker --dry-run
msg "testing 'uml4termux docker --dry-run'..."
if run uml4termux docker --dry-run >/dev/null; then
  ok "uml4termux docker --dry-run"
else
  rc=$?
  if [ $rc -eq 77 ]; then
    warn "uml4termux docker --dry-run exited 77 (expected SKIP, no assets)"
  else
    err "uml4termux docker --dry-run exited $rc"
  fi
fi

# Summary
printf '\n=== self-test summary ===\n'
printf 'FAIL: %d\n' "${FAIL}"
printf 'SKIP: %d\n' "${SKIP}"
if [ "${FAIL}" -gt 0 ]; then
  printf 'RESULT: FAIL\n'
  exit 1
elif [ "${SKIP}" -gt 0 ]; then
  printf 'RESULT: SKIP (exit 77)\n'
  exit 77
else
  printf 'RESULT: PASS\n'
  exit 0
fi