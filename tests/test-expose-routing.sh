#!/usr/bin/env bash
#
# Contract test: with a daemon owning the runtime, the shell CLI must route
# `expose` through the daemon's control socket instead of keeping its own
# expose.list / curl path. Proves the dedup actually happens (the daemon in
# selftest has no gvproxy, so its error is the tell-tale answer).
#
# SPDX-License-Identifier: GPL-2.0-only
#
# usage: tests/test-expose-routing.sh [uml4termuxd]

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN_SHELL="$ROOT/bin/uml4termux"
DAEMON="${1:-$ROOT/bin/uml4termuxd}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

[ -x "$BIN_SHELL" ] || { echo "SKIP: $BIN_SHELL not executable"; exit 77; }
[ -x "$DAEMON" ] || { echo "SKIP: no daemon binary at $DAEMON"; exit 77; }

RT="$work/rt"; mkdir -p "$RT"
export UML4TERMUX_RUNTIME="$RT"
export UML4TERMUX_HOME="$work/home"; mkdir -p "$UML4TERMUX_HOME"
export UML4TERMUX_STATE_DIR="$work/state"; mkdir -p "$UML4TERMUX_STATE_DIR"
export UML4TERMUXD_BIN="$DAEMON"
SELFTEST_SLEEP="$(command -v sleep || echo /bin/sleep)"
export UML4TERMUXD_SELFTEST_CHILD="$SELFTEST_SLEEP"
export UML4TERMUXD_SELFTEST_SECONDS="${UML4TERMUXD_SELFTEST_SECONDS:-300}"
export NO_COLOR=1

"$DAEMON" daemon --selftest >"$work/daemon.log" 2>&1 &
dp=$!
for _ in $(seq 1 40); do
  [ -S "$RT/daemon.sock" ] && break
  sleep 0.25
done
if [ ! -S "$RT/daemon.sock" ]; then
  echo "FAIL: daemon never created its socket"
  sed -n '1,20p' "$work/daemon.log"
  exit 1
fi

# the shell CLI takes ONE spec per argument: HOSTPORT[:GUESTPORT]
out="$("$BIN_SHELL" expose 18125:80 2>&1)"
rc=$?

"$DAEMON" stop >/dev/null 2>&1 || true
wait "$dp" 2>/dev/null || true

fail=0
if printf '%s' "$out" | grep -q '"gvproxy not running"'; then
  echo "PASS: shell exposed via the daemon socket (daemon answered: ${out})"
else
  echo "FAIL: expected the daemon's reply, got: ${out}"
  fail=1
fi

# the legacy parallel registry must NOT have been written
if [ -e "$RT/expose.list" ]; then
  echo "FAIL: legacy $RT/expose.list was written -- routing did not happen"
  fail=1
else
  echo "PASS: no legacy expose.list (single owner kept)"
fi

# a non-zero exit must surface a failed expose (the daemon reported an error)
if [ "$rc" -ne 0 ]; then
  echo "PASS: exit code propagated ($rc)"
else
  echo "WARN: exit code was 0 although the daemon answered with an error"
fi

[ "$fail" -eq 0 ] || exit 1
echo "expose routing contract: OK"
