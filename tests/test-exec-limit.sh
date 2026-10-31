#!/usr/bin/env bash
# Issue #1: an over-long `exec` must be REFUSED, not delivered in pieces.
#
# Measured background: the console agent reads one line per command, the daemon's
# request buffer was 512 bytes and read with a single read(), and the front end joined
# argv into a 900-byte buffer after checking the length of the WRONG thing (it tested
# `used` before copying a whole argument). Three separate ways to cut a command in
# half, all silent, while the guest's `__EXEC_n_DONE` marker still appeared -- so the
# client was told rc=0 and the guest ran something else.
#
# No guest is needed: the refusal happens before the guest is consulted, which is
# exactly what makes it testable here and on an x86 runner. Both implementations are
# exercised, daemon side and client side.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
ROOT=$PWD
W=$TMPDIR/exec-limit
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "    PASS: $1"; }
bad()  { FAIL=$((FAIL+1)); echo "    FAIL: $1"; }
count(){ local n; n=$(grep -ac "$1" "$2" 2>/dev/null); [ -n "$n" ] || n=0; printf '%s' "$n"; }

rm -rf "$W"; mkdir -p "$W"

C_BIN=$W/uml4termuxd
if env -u LD_LIBRARY_PATH cc -O2 -Wall -Wextra -Werror -o "$C_BIN" src/uml4termuxd.c 2>"$W/cc.log"; then
  echo "  C daemon built"
else
  echo "  C daemon build FAILED"; sed 's/^/    | /' "$W/cc.log" | head -6; exit 1
fi
R_BIN=$ROOT/rust/target/release/uml4termux-rs
[ -x "$R_BIN" ] || R_BIN=""

probe() {  # $1=rt  $2=payload-bytes
  env -u LD_LIBRARY_PATH python3 - "$1" "$2" <<'PY'
import socket, sys
rt, n = sys.argv[1], int(sys.argv[2])
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(10)
s.connect(rt + "/daemon.sock")
s.sendall(b"exec " + b"x" * n + b"\n")
print(s.recv(4096).decode(errors="replace").strip())
PY
}

check_impl() {  # $1=daemon binary  $2=label  $3=front-end binary (may be empty)
  local daemon=$1 label=$2 front=$3 rt rc out
  rt=$W/rt-$label
  echo "  --- $label"
  env -u LD_LIBRARY_PATH UML4TERMUX_RUNTIME="$rt" UML4TERMUXD_EXEC_MIN_INTERVAL_MS=0 \
      "$daemon" daemon --selftest > "$rt.log" 2>&1 &
  local pid=$!
  for _ in $(seq 1 50); do [ -S "$rt/daemon.sock" ] && break; sleep 0.2; done
  if [ ! -S "$rt/daemon.sock" ]; then
    bad "$label: daemon did not come up (see $rt.log)"; kill "$pid" 2>/dev/null; return
  fi

  out=$(probe "$rt" 2001)
  case "$out" in
    *'"command too long"'*'"limit":2000'*)
      ok "$label: 2001-byte command refused with the documented limit" ;;
    *) bad "$label: 2001-byte command NOT refused (got: ${out:0:90})" ;;
  esac

  out=$(probe "$rt" 2000)
  case "$out" in
    *'command too long'*)
      bad "$label: 2000-byte command refused although the limit is 2000" ;;
    *)
      ok "$label: 2000-byte command passes the length check (got: ${out:0:60})" ;;
  esac

  # The line must survive the round trip WHOLE: the selftest daemon answers "guest not
  # running", which proves it parsed the request rather than a truncated prefix.
  out=$(probe "$rt" 1999)
  case "$out" in
    *'guest not running'*|*'rate-limited'*)
      ok "$label: a long request is read whole, not half-parsed" ;;
    *) bad "$label: long request mishandled (got: ${out:0:90})" ;;
  esac

  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null

  [ -n "$front" ] || { echo "    (no front end for $label)"; return; }
  # Front end: refuse an argument list that cannot fit, exit 64, say why.
  local big small
  big=$(env -u LD_LIBRARY_PATH python3 -c 'print("x"*2100)')
  small=$(env -u LD_LIBRARY_PATH python3 -c 'print("x"*2000)')
  env -u LD_LIBRARY_PATH UML4TERMUX_RUNTIME="$rt" "$front" exec "$big" > "$W/$label-front-big.out" 2>&1
  rc=$?
  if [ "$rc" = 64 ] && [ "$(count 'command too long' "$W/$label-front-big.out")" -ge 1 ]; then
    ok "$label front end: 2100-byte command refused with exit 64"
  else
    bad "$label front end: rc=$rc, message=$(count 'command too long' "$W/$label-front-big.out")"
  fi
  env -u LD_LIBRARY_PATH UML4TERMUX_RUNTIME="$rt" "$front" exec "$small" > "$W/$label-front-small.out" 2>&1
  rc=$?
  if [ "$(count 'command too long' "$W/$label-front-small.out")" -eq 0 ] && [ "$rc" != 64 ]; then
    ok "$label front end: 2000-byte command is not refused locally (rc=$rc)"
  else
    bad "$label front end: rc=$rc, refused a command at the limit"
  fi
}

check_impl "$C_BIN" "c" "$C_BIN"
if [ -n "$R_BIN" ]; then
  check_impl "$R_BIN" "rust" "$R_BIN"
else
  echo "  --- rust: SKIP (build rust/target/release/uml4termux-rs to include it)"
fi

echo "  ------"
echo "  TOTAL pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]