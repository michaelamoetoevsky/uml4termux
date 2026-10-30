#!/usr/bin/env bash
#
# Launcher + instance registry contract (direction G2/G3).
#
# Drives `up/status/ls/logs/down` against real (selftest) daemons, with no `sv`
# on PATH at all, and checks that the three invariants the registry enforces are
# actually refused rather than merely documented.
#
# SPDX-License-Identifier: GPL-2.0-only
#
# usage: tests/test-launcher.sh [daemon-binary]

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/bin/uml4termux"
DAEMON="${1:-}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

[ -x "$BIN" ] || { echo "SKIP: $BIN not executable"; exit 77; }
[ -n "$DAEMON" ] || DAEMON="$ROOT/bin/uml4termuxd"
[ -x "$DAEMON" ] || { echo "SKIP: no daemon binary at $DAEMON"; exit 77; }
# A wrong-arch binary cannot run here; ask the caller for a compiled one.
# main() answers usage with exit 64, so only 126/127 mean "cannot execute".
"$DAEMON" --help >/dev/null 2>&1; drc=$?
if [ "$drc" -eq 126 ] || [ "$drc" -eq 127 ]; then
  echo "SKIP: $DAEMON cannot execute here (pass a locally built daemon)"
  exit 77
fi

# --- the whole point: the launcher must not need runit ---------------------
# Rather than stripping PATH (which breaks unrelated tools), put FAILING shims
# for every runit binary in front of it: if any code path here shells out to
# runit, the shim fires and we see it instead of a silent dependency.
shim="$work/shim"
mkdir -p "$shim"
for t in sv runsv runsvdir svlogd chpst; do
  {
    printf '#!/bin/sh\n'
    printf 'echo "FAIL: the launcher called %s ($*) -- it must not depend on runit" >&2\n' "$t"
    printf 'exit 111\n'
  } > "$shim/$t"
  chmod +x "$shim/$t"
done
export PATH="$shim:$PATH"
if [ "$(command -v sv)" != "$shim/sv" ]; then
  echo "FAIL: the runit shim is not first on PATH"
  exit 1
fi
# static side of the same claim: the launcher files must not name runit at all
hits="$(grep -nE '\bsv\b|runsv|svlogd|termux-services' "$ROOT/lib/launch.sh" "$ROOT/lib/registry.sh" \
  | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)"
if [ -n "$hits" ]; then
  echo "FAIL: lib/launch.sh or lib/registry.sh references runit in code:"
  printf '%s\n' "$hits"
  exit 1
fi

export UML4TERMUX_STATE_DIR="$work/state"
export UML4TERMUX_HOME="$work/home"
export UML4TERMUX_INITRAMFS_DIR="$work/initramfs"
export UML4TERMUXD_BIN="$DAEMON"
SELFTEST_SLEEP="$(command -v sleep || echo /bin/sleep)"
export UML4TERMUXD_SELFTEST_CHILD="$SELFTEST_SLEEP"
export UML4TERMUXD_SELFTEST_SECONDS="${UML4TERMUXD_SELFTEST_SECONDS:-600}"
export NO_COLOR=1
mkdir -p "$UML4TERMUX_STATE_DIR" "$UML4TERMUX_HOME" "$UML4TERMUX_INITRAMFS_DIR"

fails=0
ok()  { echo "  PASS: $1"; }
bad() { echo "  FAIL: $1"; fails=$((fails + 1)); }
expect_rc() { # label expected actual
  if [ "$2" = "$3" ]; then ok "$1 (rc=$3)"; else bad "$1 (harap rc=$2, dapat rc=$3)"; fi
}

up()   { UML4TERMUX_RUNTIME="$1" "$BIN" up --name "$2" --selftest --no-gvproxy --runtime "$1" --image "$3" ${4:+--ssh-port "$4"} 2>&1; }
down() { "$BIN" down --name "$1" 2>&1; }

# The launcher probes liveness through `protocol`. The C front end prints the
# raw JSON while the Rust one pretty-prints it; a strict compact-form grep once
# made every LIVE instance look dead, so `up` reported failure while the daemon,
# the guest and gvproxy kept running. The suite therefore runs against BOTH
# front ends -- a launcher bug that only shows with one of them is exactly the
# kind this project has been bitten by.
# A wrong-arch binary (the tracked aarch64 one on an x86 runner) cannot execute
# here; main() answers usage with exit 64, so only 126/127 mean "cannot run".
can_run() {
  "$1" --help >/dev/null 2>&1
  local rc=$?
  [ "$rc" -ne 126 ] && [ "$rc" -ne 127 ]
}

run_suite() { # <label> <daemon-binary>
  local label="$1" daemon="$2"
  # Each suite must use the binary it was given: without this export the
  # launcher falls back to an installed uml4termuxd and both suites would
  # silently test the same front end.
  export UML4TERMUXD_BIN="$daemon"
  echo "### front end: ${label} ###"

out="$(up "$work/rt-a" a "$work/img-a" 2222)"; rc=$?
expect_rc "up A" 0 "$rc"
printf '%s\n' "$out" | grep -q "is up" && ok "pesan up" || bad "pesan up tidak muncul: $out"

# Guard against silent fallback: the running daemon MUST be the binary this
# suite was handed. A missing export once made both suites test the installed
# uml4termuxd while every assertion still passed.
dpid="$(sed -n 's/^PID=//p' "$UML4TERMUX_STATE_DIR/instances/a.env" 2>/dev/null)"
if [ -n "$dpid" ] && tr '\0' ' ' < "/proc/$dpid/cmdline" 2>/dev/null | grep -qF "$daemon"; then
  ok "daemon yang berjalan = biner ${label}"
else
  bad "daemon yang berjalan BUKAN biner ${label} (cmdline pid ${dpid:-?} tidak memuat $daemon)"
fi

st="$("$BIN" status --name a --json)"
printf '%s' "$st" | grep -q '"live":"yes"' && ok "status A live" || bad "status A: $st"
printf '%s' "$st" | grep -q '"phase":"running"' && ok "status A fase running" || bad "status A: $st"

"$BIN" logs --name a -l 4 >/dev/null 2>&1 && ok "logs A terbaca" || bad "logs A gagal"

echo "== invarian 3: satu runtime per instance =="
out="$(up "$work/rt-a" b "$work/img-b" 12222)"; rc=$?
expect_rc "up B pada runtime A ditolak" 1 "$rc"
printf '%s' "$out" | grep -q "runtime .* is owned by live instance 'a'" \
  && ok "pesan invarian runtime" || bad "pesan invarian runtime: $out"

echo "== invarian 1: satu guest per image =="
out="$(up "$work/rt-b" b "$work/img-a" 12222)"; rc=$?
expect_rc "up B pada image A ditolak" 1 "$rc"
printf '%s' "$out" | grep -q "used by live instance 'a'" \
  && ok "pesan invarian image" || bad "pesan invarian image: $out"

echo "== invarian 2: satu gvproxy per port ssh =="
out="$(up "$work/rt-b" b "$work/img-b" 2222)"; rc=$?
expect_rc "up B pada port 2222 ditolak" 1 "$rc"
printf '%s' "$out" | grep -q "port 2222 is held by live instance 'a'" \
  && ok "pesan invarian port" || bad "pesan invarian port: $out"

echo "== instance B: image + port + runtime sendiri -> boleh =="
out="$(up "$work/rt-b" b "$work/img-b" 12222)"; rc=$?
expect_rc "up B" 0 "$rc"

ls_out="$("$BIN" ls)"
printf '%s' "$ls_out" | grep -c 'yes' | grep -q '^2$' && ok "ls melaporkan 2 instance live" || bad "ls: $ls_out"

echo "== up ulang pada instance yang sudah hidup =="
out="$(up "$work/rt-a" a "$work/img-a" 2222)"; rc=$?
expect_rc "up A dua kali" 0 "$rc"
printf '%s' "$out" | grep -q 'already up' && ok "up idempoten" || bad "up ulang: $out"

echo "== down + registry dibersihkan =="
out="$(down a)"; expect_rc "down A" 0 "$?"
out="$(down b)"; expect_rc "down B" 0 "$?"
"$BIN" ls >"$work/ls2" 2>&1
if grep -q 'no instances registered' "$work/ls2"; then ok "registry kosong setelah down"; else bad "ls setelah down: $(cat "$work/ls2")"; fi
"$BIN" status --name a >/dev/null 2>&1; expect_rc "status instance yang sudah turun" 1 "$?"

echo "== dry-run tidak menjalankan apa pun =="
out="$(UML4TERMUX_RUNTIME="$work/rt-c" "$BIN" --dry-run up --name c --selftest --no-gvproxy --image "$work/img-c")"; rc=$?
expect_rc "up --dry-run" 0 "$rc"
printf '%s' "$out" | grep -q ' daemon --selftest' && ok "dry-run mencetak perintah" || bad "dry-run: $out"
[ -S "$work/rt-c/daemon.sock" ] && bad "dry-run meninggalkan daemon hidup" || ok "dry-run tidak menyalakan daemon"

}

# The C suite uses the binary the caller provided (bin/uml4termuxd locally, the
# freshly compiled one in CI) and is skipped when that binary cannot run here.
if [ -x "$DAEMON" ] && can_run "$DAEMON"; then
  run_suite c "$DAEMON"
else
  echo "SKIP: C front end cannot execute here ($DAEMON)"
fi
if [ -x "$ROOT/rust/target/release/uml4termux-rs" ] && can_run "$ROOT/rust/target/release/uml4termux-rs"; then
  run_suite rust "$ROOT/rust/target/release/uml4termux-rs"
else
  echo "SKIP: rust front end not built"
fi

echo
if [ "$fails" -eq 0 ]; then
  echo "launcher + registry: OK"
else
  echo "launcher + registry: $fails kegagalan"
  exit 1
fi
