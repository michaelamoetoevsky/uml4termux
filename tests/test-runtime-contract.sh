#!/usr/bin/env bash
#
# Runtime contract v1 gate (docs/RUNTIME-CONTRACT.md).
#
# Every assertion here maps 1:1 to a promise in the contract document. If the
# daemon stops honouring one, this fails -- the doc is not allowed to drift.
# Runs against BOTH implementations (C and Rust) so the contract binds both.
#
# SPDX-License-Identifier: GPL-2.0-only
#
# usage: tests/test-runtime-contract.sh [c-daemon] [rust-binary]

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
C_DAEMON="${1:-$ROOT/bin/uml4termuxd}"
RS_BIN="${2:-$ROOT/rust/target/release/uml4termux-rs}"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

SELFTEST_SLEEP="$(command -v sleep || echo /bin/sleep)"
PROTOCOL_REPLY='{"protocol":1,"runtime_contract":1,"commands":["status","stop","ports","expose","exec","protocol"]}'

fails=0
ok()   { echo "  PASS: $1"; }
bad()  { echo "  FAIL: $1"; fails=$((fails + 1)); }
check() { # $1 = label, $2 = expected, $3 = actual
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (harap '$2', dapat '$3')"; fi
}

# The C binary is shipped as bin/uml4termuxd; build a local one when the
# checked-in binary cannot run here (different arch, e.g. a CI runner).
build_c() {
  local out="$work/uml4termuxd"
  if cc -O2 -o "$out" "$ROOT/src/uml4termuxd.c" 2>/dev/null; then printf '%s' "$out"; return 0; fi
  if clang -O2 -o "$out" "$ROOT/src/uml4termuxd.c" 2>/dev/null; then printf '%s' "$out"; return 0; fi
  return 1
}

# $1 = implementation label, $2 = daemon binary, $3 = client binary
probe() {
  local label="$1" daemon="$2" client="$3"
  local rt="$work/rt-$label"
  mkdir -p "$rt"
  echo "== $label =="

  # The client must look at THIS runtime dir too -- exporting only for the
  # daemon start would silently point the client at the default socket.
  export UML4TERMUX_RUNTIME="$rt"
  export UML4TERMUXD_SELFTEST_CHILD="$SELFTEST_SLEEP"
  export UML4TERMUXD_SELFTEST_SECONDS="${UML4TERMUXD_SELFTEST_SECONDS:-300}"

  "$daemon" daemon --selftest >"$work/$label.daemon.log" 2>&1 &
  local dp=$!
  for _ in $(seq 1 60); do [ -S "$rt/daemon.sock" ] && break; sleep 0.25; done
  if [ ! -S "$rt/daemon.sock" ]; then
    bad "$label: socket kontrol tidak pernah dibuat"
    sed -n '1,15p' "$work/$label.daemon.log"
    return
  fi

  # --- §1 layout: the socket is private (0600) ---
  check "$label §1 socket mode 0600" "600" "$(stat -c '%a' "$rt/daemon.sock")"

  # --- §2 protocol handshake, byte for byte ---
  local proto; proto="$("$client" --raw protocol 2>/dev/null)"
  [ -n "$proto" ] || proto="$("$client" protocol 2>/dev/null | tr -d '\n ')"
  check "$label §2 balasan protocol" "$PROTOCOL_REPLY" "$proto"
  check "$label §2 status" "0" "$("$client" status >/dev/null 2>&1; echo $?)"
  check "$label §2 ports" "0" "$("$client" ports >/dev/null 2>&1; echo $?)"

  # --- §3 exit codes ---
  check "$label §3 perintah tak dikenal -> 64" "64" "$("$client" bogus-command >/dev/null 2>&1; echo $?)"

  # --- §4 state file schema ---
  if [ -r "$rt/daemon.sock.state" ]; then
    local st; st="$(cat "$rt/daemon.sock.state")"
    case "$st" in
      *'"phase":'*) ok "$label §4 state punya phase" ;;
      *) bad "$label §4 state tanpa phase: $st" ;;
    esac
    case "$st" in
      *'"child_pid":'*'"restarts":'*'"detail":'*'"ts":'*) ok "$label §4 field wajib lengkap" ;;
      *) bad "$label §4 field wajib tidak lengkap: $st" ;;
    esac
    local ph; ph="$(printf '%s' "$st" | sed -n 's/.*"phase":"\([a-z]*\)".*/\1/p')"
    case "$ph" in
      running|stopped|completed|exited|failed) ok "$label §4 fase '$ph' ada di vokabuler" ;;
      *) bad "$label §4 fase di luar vokabuler: '$ph'" ;;
    esac
  else
    bad "$label §4 state file tidak ada"
  fi

  # --- §5 readiness: protocol answers AND phase is running ---
  if printf '%s' "$proto" | grep -q '"protocol":1' && \
     grep -q '"phase":"running"' "$rt/daemon.sock.state"; then
    ok "$label §5 tiga syarat ready terpenuhi"
  else
    bad "$label §5 instance seharusnya ready"
  fi

  # --- §2 single writer: a foreign writer must not be able to break it ---
  # the registry is only ever written through the daemon, so the file may be
  # absent while no exposure was requested, but must never be a directory etc.
  if [ -e "$rt/exposures.jsonl" ] && [ ! -f "$rt/exposures.jsonl" ]; then
    bad "$label §2 exposures.jsonl bukan berkas biasa"
  else
    ok "$label §2 exposures.jsonl bukan entitas aneh"
  fi

  "$client" stop >/dev/null 2>&1 || true
  for _ in $(seq 1 40); do kill -0 "$dp" 2>/dev/null || break; sleep 0.25; done
  if kill -0 "$dp" 2>/dev/null; then
    bad "$label: daemon tidak berhenti setelah stop"
    kill "$dp" 2>/dev/null
  fi
  rm -f "$rt/daemon.sock"

  # --- §3 exit 3 when the daemon is unreachable ---
  check "$label §3 tanpa daemon -> 3" "3" "$("$client" status >/dev/null 2>&1; echo $?)"
}

# --- C implementation ---
# Prefer the tracked bin/uml4termuxd (that is the binary users actually get), so
# a stale shipped binary fails the contract here instead of shipping silently.
# Only fall back to compiling from source when it cannot run on this machine
# (e.g. the aarch64 binary on an x86 runner): main() answers `--help` with the
# usage text and exit 64.
C_BIN=""
if [ -x "$C_DAEMON" ]; then
  "$C_DAEMON" --help >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 64 ] && C_BIN="$C_DAEMON"
fi
if [ -z "$C_BIN" ]; then
  C_BIN="$(build_c || true)"
  [ -n "$C_BIN" ] && echo "catatan: bin/uml4termuxd tidak bisa dijalankan di sini; memakai hasil kompilasi dari sumber"
fi
if [ -n "$C_BIN" ]; then
  probe c "$C_BIN" "$C_BIN"
else
  echo "SKIP: no runnable C daemon (neither $C_DAEMON nor a C compiler)"
fi

# --- Rust implementation (daemon + its own client) ---
if [ -x "$RS_BIN" ]; then
  probe rust "$RS_BIN" "$RS_BIN"
else
  echo "SKIP: rust binary not built at $RS_BIN"
fi

echo
if [ "$fails" -eq 0 ]; then
  echo "runtime contract v1: OK"
else
  echo "runtime contract v1: $fails pelanggaran"
  exit 1
fi
