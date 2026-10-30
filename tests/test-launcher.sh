#!/usr/bin/env bash
#
# Launcher + instance registry contract (direction G2/G3).
#
# Drives `up/status/ls/logs/down` against real (selftest) daemons with FAILING
# runit shims first on PATH, and checks that the three invariants the registry
# enforces are refusals, not warnings.
#
# Runs once per front end (C and Rust), because the launcher's liveness probe
# reads the protocol reply and the Rust CLI pretty-prints that JSON while the C
# front end does not -- a difference that once made every live instance look
# dead, so `up` reported failure while the daemon and guest kept running.
#
# SPDX-License-Identifier: GPL-2.0-only
#
# usage: tests/test-launcher.sh [c-daemon] [rust-binary]

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/bin/uml4termux"
C_BIN="${1:-$ROOT/bin/uml4termuxd}"
RS_BIN="${2:-$ROOT/rust/target/release/uml4termux-rs}"
DEBUG="${UML4TERMUX_DEBUG_PROBE:-0}"

fails=0
ok()  { printf '  PASS: %s\n' "$1"; }
bad() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }
check() { # label expected actual
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (harap '$2', dapat '$3')"; fi
}

# main() answers usage with exit 64; only 126/127 mean "cannot run here"
# (the tracked aarch64 binary on an x86 runner).
can_run() { "$1" --help >/dev/null 2>&1; local rc=$?; [ "$rc" -ne 126 ] && [ "$rc" -ne 127 ]; }

[ -x "$BIN" ] || { echo "SKIP: $BIN not executable"; exit 77; }

work="$(mktemp -d)"
RUNS=""   # "name pid" for every instance this harness started

# Deleting a temp dir under a live daemon orphans it beyond reach, so stop
# everything we started before cleaning up.
cleanup() {
  local pair
  for pair in $RUNS; do kill -TERM "${pair#* }" 2>/dev/null; done
  sleep 0.3
  for pair in $RUNS; do kill -KILL "${pair#* }" 2>/dev/null; done
  rm -rf "$work"
}
trap cleanup EXIT

# --- no runit, verified two ways -------------------------------------------
shim="$work/shim"; mkdir -p "$shim"
for t in sv runsv runsvdir svlogd chpst; do
  printf '#!/bin/sh\necho "SHIM_FIRED %s $*" >&2\nexit 111\n' "$t" > "$shim/$t"
  chmod +x "$shim/$t"
done
export PATH="$shim:$PATH"
[ "$(command -v sv)" = "$shim/sv" ] || { echo "FAIL: shim not first on PATH"; exit 1; }
hits="$(grep -nE '\bsv\b|runsv|svlogd|termux-services' "$ROOT/lib/launch.sh" "$ROOT/lib/registry.sh" \
        | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)"
if [ -n "$hits" ]; then
  echo "FAIL: launcher code references runit:"; printf '%s\n' "$hits"; exit 1
fi

SELFTEST_SLEEP="$(command -v sleep || echo /bin/sleep)"

# --- one suite per front end ------------------------------------------------
run_suite() { # <label> <daemon binary>
  local label="$1" daemon="$2"

  export UML4TERMUXD_BIN="$daemon"
  export UML4TERMUX_STATE_DIR="$work/state-$label"
  export UML4TERMUX_HOME="$work/home-$label"
  export UML4TERMUX_INITRAMFS_DIR="$work/initramfs-$label"
  export UML4TERMUXD_SELFTEST_CHILD="$SELFTEST_SLEEP"
  export UML4TERMUXD_SELFTEST_SECONDS=600
  export NO_COLOR=1
  mkdir -p "$UML4TERMUX_STATE_DIR" "$UML4TERMUX_HOME" "$UML4TERMUX_INITRAMFS_DIR"

  local rt_a="$work/rt-a-$label" rt_b="$work/rt-b-$label"
  local img_a="$work/img-a-$label" img_b="$work/img-b-$label"
  local rcd="$UML4TERMUX_STATE_DIR/instances"

  echo "### front end: ${label} ###"

  # The launcher must resolve the binary this suite was handed (a missing export
  # once made both suites test an installed uml4termuxd).
  check "$label: biner daemon terdeteksi" "$daemon" \
    "$(UML4TERMUXD_BIN="$daemon" UML4TERMUX_HOME="$UML4TERMUX_HOME" \
       bash -c ". '$ROOT/lib/common.sh'; uml4termux_daemon_bin" 2>/dev/null)"

  do_up() { # <runtime> <name> <image> [ssh-port]
    UML4TERMUX_RUNTIME="$1" "$BIN" up --name "$2" --selftest --no-gvproxy \
      --runtime "$1" --image "$3" ${4:+--ssh-port "$4"} 2>&1
  }
  rec_pid() { sed -n 's/^PID=//p' "$rcd/$1.env" 2>/dev/null; }
  note()    { RUNS="$RUNS $1:$(rec_pid "$1")"; }

  # 1. start
  out="$(do_up "$rt_a" a "$img_a" 2222)"; rc=$?
  if [ "$rc" -eq 0 ]; then ok "$label: up A"; else bad "$label: up A rc=$rc: $out"; fi
  note a
  check "$label: registry mencatat runtime" "$rt_a" "$(sed -n 's/^RUNTIME=//p' "$rcd/a.env" 2>/dev/null)"
  check "$label: status live" "yes" \
    "$("$BIN" status --name a --json | sed -n 's/.*"live":"\([a-z]*\)".*/\1/p')"
  if "$BIN" logs --name a -l 4 >/dev/null 2>&1; then ok "$label: logs terbaca"; else bad "$label: logs gagal"; fi

  # 2. idempotent: the second up must keep the SAME daemon
  pid_before="$(rec_pid a)"
  out="$(do_up "$rt_a" a "$img_a" 2222)"; rc=$?
  pid_after="$(rec_pid a)"
  check "$label: up ulang rc" "0" "$rc"
  if [ -n "$pid_before" ] && [ "$pid_before" = "$pid_after" ] && kill -0 "$pid_after" 2>/dev/null; then
    ok "$label: up idempoten (pid $pid_after dipertahankan)"
  else
    bad "$label: up ulang mengganti daemon (sebelum='$pid_before' sesudah='$pid_after')"
  fi

  # 3. stop/start cycle: a stale state file must not fool the readiness poll
  "$BIN" down --name a >/dev/null 2>&1
  out="$(do_up "$rt_a" a "$img_a" 2222)"; rc=$?
  if [ "$rc" -eq 0 ]; then ok "$label: up setelah down (state basi)"; else bad "$label: up setelah down rc=$rc: $out"; fi
  note a

  # 4. invariants must REFUSE
  out="$(do_up "$rt_a" b "$img_b" 12222)"; rc=$?
  if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "runtime $rt_a is owned by"; then
    ok "$label: invarian runtime ditolak"
  else bad "$label: invarian runtime (rc=$rc): $out"; fi

  out="$(do_up "$rt_b" b "$img_a" 12222)"; rc=$?
  if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "used by live instance 'a'"; then
    ok "$label: invarian image ditolak"
  else bad "$label: invarian image (rc=$rc): $out"; fi

  out="$(do_up "$rt_b" b "$img_b" 2222)"; rc=$?
  if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "port 2222 is held by"; then
    ok "$label: invarian port ditolak"
  else bad "$label: invarian port (rc=$rc): $out"; fi

  # 5. a second instance with its own runtime, image and port IS allowed
  out="$(do_up "$rt_b" b "$img_b" 12222)"; rc=$?
  if [ "$rc" -eq 0 ]; then ok "$label: up B"; else bad "$label: up B rc=$rc: $out"; fi
  note b
  check "$label: ls melihat 2 instance live" "2" "$("$BIN" ls | grep -c ' yes ')"

  # 6. teardown
  "$BIN" down --name a >/dev/null 2>&1; check "$label: down A" "0" "$?"
  "$BIN" down --name b >/dev/null 2>&1; check "$label: down B" "0" "$?"
  sleep 1
  alive=0
  for pair in $RUNS; do kill -0 "${pair#* }" 2>/dev/null && alive=$((alive + 1)); done
  check "$label: semua daemon berhenti" "0" "$alive"
  check "$label: registry kosong" "0" "$(ls "$rcd" 2>/dev/null | wc -l | tr -d ' ')"
  "$BIN" status --name a >/dev/null 2>&1; check "$label: status instance turun" "1" "$?"

  # 7. dry run must not start anything
  out="$(UML4TERMUX_RUNTIME="$work/rt-c-$label" "$BIN" --dry-run up --name c --selftest --no-gvproxy --image "$work/img-c" 2>&1)"
  check "$label: dry-run rc" "0" "$?"
  if printf '%s' "$out" | grep -q ' daemon --selftest'; then ok "$label: dry-run mencetak perintah"; else bad "$label: dry-run: $out"; fi
  if [ -S "$work/rt-c-$label/daemon.sock" ]; then bad "$label: dry-run menyalakan daemon"; else ok "$label: dry-run tidak menyalakan daemon"; fi
}

if [ -x "$C_BIN" ] && can_run "$C_BIN"; then
  run_suite c "$C_BIN"
else
  echo "SKIP: C front end cannot execute here ($C_BIN)"
fi
if [ -x "$RS_BIN" ] && can_run "$RS_BIN"; then
  run_suite rust "$RS_BIN"
else
  echo "SKIP: rust front end not built ($RS_BIN)"
fi

[ "$DEBUG" = "1" ] && echo "  [dbg] RUNS:$RUNS"

echo
if [ "$fails" -eq 0 ]; then
  echo "launcher + registry: OK"
else
  echo "launcher + registry: $fails kegagalan"
  exit 1
fi
