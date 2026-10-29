#!/usr/bin/env bash
#
# Daemon parity gate: the Rust daemon must answer exactly like the C daemon.
#
# Both daemons run in --selftest (fake child, no guest boot) on the SAME
# runtime directory, one after the other, and the same client queries both.
# Only PIDs are normalised: they are inherently different per process.
#
# SPDX-License-Identifier: GPL-2.0-only
#
# usage: ci/verify-daemon-parity.sh [c-daemon] [rust-daemon]

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
C_DAEMON="${1:-}"
RS_DAEMON="${2:-}"

work="$(mktemp -d)"
SELFTEST_CHILD="${UML4TERMUXD_SELFTEST_CHILD:-$(command -v sleep || echo /bin/sleep)}"
trap 'rm -rf "$work"' EXIT

# Build the C daemon when not supplied (needs a C compiler; skipped otherwise).
if [ -z "$C_DAEMON" ]; then
  if command -v cc >/dev/null 2>&1; then
    C_DAEMON="$work/uml4termuxd"
    cc -O2 -o "$C_DAEMON" "$ROOT/src/uml4termuxd.c"
  elif command -v clang >/dev/null 2>&1; then
    C_DAEMON="$work/uml4termuxd"
    clang -O2 -o "$C_DAEMON" "$ROOT/src/uml4termuxd.c"
  else
    echo "SKIP: no C compiler available"; exit 77
  fi
fi
if [ -z "$RS_DAEMON" ]; then
  RS_DAEMON="$ROOT/rust/target/release/uml4termux-rs"
fi
[ -x "$RS_DAEMON" ] || { echo "SKIP: rust binary not built at $RS_DAEMON"; exit 77; }

RT="$work/rt"
mkdir -p "$RT"
export UML4TERMUX_RUNTIME="$RT"
export UML4TERMUXD_SELFTEST_CHILD="$SELFTEST_CHILD"
export UML4TERMUXD_HTTP="127.0.0.1:19119"
export NO_COLOR=1

# PID varies per run; everything else must match byte for byte.
normalize() { sed -E 's/"child_pid":[0-9]+/"child_pid":PID/g'; }

query_daemon() { # $1 = daemon binary, $2 = phase name
  local bin="$1" phase="$2"
  "$bin" daemon --selftest >"$work/$phase.daemon.log" 2>&1 &
  local dp=$!
  for _ in $(seq 1 60); do
    [ -S "$RT/daemon.sock" ] && break
    sleep 0.25
  done
  if [ ! -S "$RT/daemon.sock" ]; then
    echo "FAIL($phase): daemon never created its socket"
    sed -n '1,40p' "$work/$phase.daemon.log"
    return 1
  fi
  local c_client="$C_DAEMON"
  # The client's own exit code is NOT part of this gate (client parity is
  # checked separately), and an unknown command legitimately exits non-zero,
  # so errexit/pipefail must not abort the comparison here.
  local rc=0
  set +e
  {
    "$c_client" status
    "$c_client" ports
    "$c_client" exec uname -a
    "$c_client" expose 8124 80
    "$c_client" bogus-command
  } 2>/dev/null | normalize >"$work/$phase.replies"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || true
  # state file shape (fields + phase), PIDs and ts normalised
  if [ -f "$RT/daemon.sock.state" ]; then
    sed -E 's/"child_pid":[0-9-]+/"child_pid":PID/; s/"ts":[0-9]+/"ts":TS/' \
      "$RT/daemon.sock.state" >>"$work/$phase.replies"
  fi
  # Optional HTTP health endpoint (D2): same port for both daemons, so the
  # bodies must match modulo the child pid.
  if command -v curl >/dev/null 2>&1; then
    curl -sS --max-time 5 "http://127.0.0.1:19119/status" 2>/dev/null | normalize \
      >>"$work/$phase.replies" || echo "http: no response ($phase)" >>"$work/$phase.replies"
  fi
  "$c_client" stop >/dev/null 2>&1 || true
  wait "$dp" 2>/dev/null || true
  rm -f "$RT/daemon.sock"
}

query_daemon "$C_DAEMON" c
query_daemon "$RS_DAEMON" rust

if diff -u "$work/c.replies" "$work/rust.replies" >"$work/diff.txt"; then
  echo "daemon parity OK (C vs Rust, $(wc -l <"$work/c.replies") normalised lines)"
  cat "$work/c.replies" | sed 's/^/  /'
else
  echo "DAEMON PARITY MISMATCH"
  sed -n '1,60p' "$work/diff.txt"
  exit 1
fi
