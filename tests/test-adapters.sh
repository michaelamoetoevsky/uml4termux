#!/usr/bin/env bash
#
# Launcher adapter contract (direction G5).
#
# Every adapter must drive the SAME documented hook -- `uml4termux up
# --foreground` -- and only the runit adapter may mention runit at all. Beyond
# the static checks, the plain adapter is exercised for real: a supervisor must
# bring the instance back after the daemon is killed, and must NOT restart after
# a deliberate stop (exit 0).
#
# SPDX-License-Identifier: GPL-2.0-only
#
# usage: tests/test-adapters.sh [daemon-binary]

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/bin/uml4termux"
DAEMON="${1:-$ROOT/bin/uml4termuxd}"
A="$ROOT/packaging/adapters"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fails=0
ok()  { printf '  PASS: %s\n' "$1"; }
bad() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (harap '$2', dapat '$3')"; fi }

echo "== adapter ada =="
for f in systemd/uml4termux@.service s6/run s6/finish plain/supervise.sh runit/run; do
  [ -s "$A/$f" ] && ok "ada: $f" || bad "hilang: $f"
done

echo "== setiap adapter memakai kail resmi up --foreground =="
for f in systemd/uml4termux@.service s6/run plain/supervise.sh runit/run; do
  if grep -q 'up --foreground' "$A/$f"; then ok "$f memakai kail"; else bad "$f tidak memakai kail"; fi
done

echo "== hanya adapter runit yang menyebut runit =="
for f in systemd/uml4termux@.service s6/run s6/finish plain/supervise.sh; do
  hits="$(grep -nE '\bsv\b|runsv|svlogd|termux-services' "$A/$f" | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
  [ -z "$hits" ] && ok "$f bersih dari runit" || bad "$f menyebut runit: $hits"
done

echo "== unit systemd valid (bila systemd-analyze ada) =="
if command -v systemd-analyze >/dev/null 2>&1; then
  if systemd-analyze verify "$A/systemd/uml4termux@.service" >"$work/sysd.out" 2>&1; then
    ok "systemd-analyze verify"
  else
    # An unknown ExecStart path is reported too; only structural errors matter.
    if grep -qiE 'invalid|missing|unknown key|bad' "$work/sysd.out"; then
      bad "systemd-analyze: $(head -3 "$work/sysd.out")"
    else
      ok "systemd-analyze verify (hanya peringatan path)"
    fi
  fi
else
  echo "  SKIP: systemd-analyze tidak tersedia"
fi

echo "== s6 finish: eksit bersih harus menahan restart =="
"$A/s6/finish" 0 0; check "finish(0,0) -> 125 (jangan restart)" "125" "$?"
"$A/s6/finish" 1 0; check "finish(1,0) -> 0 (restart)" "0" "$?"

echo "== plain supervisor menghidupkan ulang setelah daemon dibunuh =="
# main() answers usage with exit 64, so only 126/127 mean "cannot run here".
runnable=no
if [ -x "$DAEMON" ]; then
  "$DAEMON" --help >/dev/null 2>&1; drc=$?
  [ "$drc" -ne 126 ] && [ "$drc" -ne 127 ] && runnable=yes
fi
if [ "$runnable" = "yes" ]; then
  export UML4TERMUX_HOME="$work/home" UML4TERMUX_STATE_DIR="$work/state"
  export UML4TERMUX_INITRAMFS_DIR="$work/initramfs"
  export UML4TERMUXD_BIN="$DAEMON"
  ADAPTER_SLEEP="$(command -v sleep || echo /bin/sleep)"
  export UML4TERMUXD_SELFTEST_CHILD="$ADAPTER_SLEEP"
  export UML4TERMUXD_SELFTEST_SECONDS=600
  export NO_COLOR=1
  mkdir -p "$UML4TERMUX_HOME" "$UML4TERMUX_STATE_DIR" "$UML4TERMUX_INITRAMFS_DIR"
  rt="$work/rt"
  rec="$UML4TERMUX_STATE_DIR/instances/plain.env"

  UML4TERMUX_RUNTIME="$rt" UML4TERMUX_BIN="$BIN" UML4TERMUX_INSTANCE_NAME=plain \
    UML4TERMUX_SUPERVISE_BACKOFF=1 UML4TERMUX_SUPERVISE_MAX=3 \
    "$A/plain/supervise.sh" --selftest --no-gvproxy --runtime "$rt" --image "$work/img" \
    >"$work/sup.log" 2>&1 &
  sup=$!

  for _ in $(seq 1 60); do [ -s "$rec" ] && break; sleep 0.5; done
  pid1="$(sed -n 's/^PID=//p' "$rec" 2>/dev/null)"
  check "supervisor menyalakan instance" "yes" "$([ -n "$pid1" ] && kill -0 "$pid1" 2>/dev/null && echo yes || echo no)"

  # kill the daemon hard: the supervisor must notice a non-zero exit and restart
  [ -n "$pid1" ] && kill -KILL "$pid1" 2>/dev/null
  pid2=""
  for _ in $(seq 1 40); do
    pid2="$(sed -n 's/^PID=//p' "$rec" 2>/dev/null)"
    [ -n "$pid2" ] && [ "$pid2" != "$pid1" ] && kill -0 "$pid2" 2>/dev/null && break
    sleep 0.5
  done
  if [ -n "$pid2" ] && [ "$pid2" != "$pid1" ] && kill -0 "$pid2" 2>/dev/null; then
    ok "supervisor menghidupkan ulang (pid $pid1 -> $pid2)"
  else
    bad "daemon tidak dihidupkan ulang (pid1=$pid1 pid2=$pid2)"
    sed -n '1,10p' "$work/sup.log" | sed 's/^/    /'
  fi

  # deliberate stop: exit 0 must end the supervisor, not loop forever
  UML4TERMUX_RUNTIME="$rt" "$BIN" down --name plain >/dev/null 2>&1
  stopped="no"
  for _ in $(seq 1 40); do kill -0 "$sup" 2>/dev/null || { stopped="yes"; break; }; sleep 0.5; done
  check "supervisor berhenti setelah stop bersih" "yes" "$stopped"
  kill -KILL "$sup" 2>/dev/null
  [ -n "${pid1:-}" ] && kill -KILL "$pid1" 2>/dev/null
  [ -n "${pid2:-}" ] && kill -KILL "$pid2" 2>/dev/null
else
  echo "  SKIP: daemon binary tidak bisa dijalankan di sini"
fi

echo
if [ "$fails" -eq 0 ]; then
  echo "adapters: OK"
else
  echo "adapters: $fails kegagalan"
  exit 1
fi
