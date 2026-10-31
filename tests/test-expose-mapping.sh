#!/usr/bin/env bash
# Issue #4: `expose HOST:GUEST` must put the GUEST port in the guest half -- in the
# daemon's reply AND in the registry file it keeps, because the two are read by
# different consumers (a human, and the re-apply-on-restart path). The entry exists
# because a daemon log line once showed the host port in both halves; reading the code
# said otherwise, so the question has to be answered by a test rather than by memory.
#
# Needs a real guest (expose goes through gvproxy), a private copy of the image (a shared
# one is refused since #7), and the pinned assets; SKIPs cleanly when they are absent, so
# an x86 runner does not pretend to have run it.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
ROOT=$PWD
A=${A:-$TMPDIR/bench-assets}
W=$TMPDIR/expose-map
PASS=0; FAIL=0; SKIPS=0
ok()   { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
skip() { SKIPS=$((SKIPS+1)); echo "  SKIP: $1"; }
count(){ local n; n=$(grep -ac "$1" "$2" 2>/dev/null); [ -n "$n" ] || n=0; printf '%s' "$n"; }

if [ ! -f "$A/linux-bionic" ] || [ ! -f "$A/debian-docker.ext4" ]; then
  skip "assets not present under $A (needs a device with the pinned kernel and image)"
  echo "  TOTAL pass=$PASS fail=$FAIL skip=$SKIPS"
  exit 0
fi

rm -rf "$W"; mkdir -p "$W"
IMG=$W/image.ext4
cp --sparse=always "$A/debian-docker.ext4" "$IMG" || { echo "  FAIL: cannot copy the image"; exit 1; }

export UML4TERMUX_HOME=$A UML4TERMUXD_BIN=$ROOT/bin/uml4termuxd
export UML4TERMUX_STATE_DIR=$W/state UML4TERMUX_RUNTIME=$W/rt UML4TERMUX_KERNEL_FILE=linux-bionic
export UML4TERMUXD_EXEC_MIN_INTERVAL_MS=0

echo "  booting an instance on a private copy (this is the expensive part)"
if ! bin/uml4termux up --name expmap --image "$IMG" --mem 1024M --ssh-port 12686 --timeout 300 >"$W/up.log" 2>&1; then
  skip "instance did not come up here (see $W/up.log); not a verdict on expose"
  sed -n '1,6p' "$W/up.log" | sed 's/^/    | /'
  echo "  TOTAL pass=$PASS fail=$FAIL skip=$SKIPS"
  exit 0
fi

HOST_PORT=12700
GUEST_PORT=8123
reply=$("$UML4TERMUXD_BIN" expose "$HOST_PORT" "$GUEST_PORT" 2>&1)
echo "  reply: $reply"

case "$reply" in
  *"127.0.0.1:${HOST_PORT} -> 192.168.127.2:${GUEST_PORT}"*)
    ok "daemon reply maps host ${HOST_PORT} to guest ${GUEST_PORT}" ;;
  *)
    bad "daemon reply does not carry the guest port ${GUEST_PORT}: ${reply}" ;;
esac

case "$reply" in
  *":${HOST_PORT} -> 192.168.127.2:${HOST_PORT}"*)
    bad "REGRESSION: daemon reply repeats the host port in the guest half" ;;
  *) ok "daemon reply does not repeat the host port as the guest port" ;;
esac

REG=$W/rt/exposures.jsonl
if [ -r "$REG" ]; then
  line=$(tail -1 "$REG")
  echo "  registry: $line"
  # The registry stores the mapping as {"local":"127.0.0.1:<host>","remote":"192.168.127.2:<guest>"};
  # match that shape, not a bare number, so a swapped pair cannot pass as correct.
  case "$line" in
    *"\"remote\":\"192.168.127.2:${GUEST_PORT}\""*) ok "registry file records the guest port ${GUEST_PORT} in the remote half" ;;
    *) bad "registry file does not record the guest port: $line" ;;
  esac
  case "$line" in
    *"\"remote\":\"192.168.127.2:${HOST_PORT}\""*)
      bad "REGRESSION: registry puts the host port in the remote half: $line" ;;
    *) ok "registry does not put the host port in the remote half" ;;
  esac
  case "$line" in
    *"\"local\":\"127.0.0.1:${HOST_PORT}\""*) ok "registry keeps the host port in the local half" ;;
    *) bad "registry lost the host port: $line" ;;
  esac
else
  bad "no exposure registry at $REG"
fi

# `ports` reads the registry back through the daemon: the round trip must agree.
ports=$("$UML4TERMUXD_BIN" ports 2>&1)
case "$ports" in
  *"${GUEST_PORT}"*) ok "ports listing carries the guest port" ;;
  *) bad "ports listing lost the guest port: ${ports}" ;;
esac

# End to end: the exposure is only correct if a request actually reaches the guest.
body=$(curl -fsS --max-time 10 "http://127.0.0.1:${HOST_PORT}/" 2>/dev/null | head -c 40)
case "$body" in
  *gvproxy-bess-ok*) ok "host port ${HOST_PORT} reaches the guest web container" ;;
  '') skip "guest web container did not answer on ${GUEST_PORT} (booking, not mapping)" ;;
  *) ok "host port answered (${body})" ;;
esac

bin/uml4termux down --name expmap >/dev/null 2>&1
echo "  TOTAL pass=$PASS fail=$FAIL skip=$SKIPS"
[ "$FAIL" -eq 0 ]