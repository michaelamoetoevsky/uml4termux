#!/usr/bin/env bash
# End-to-end gvproxy + exposure test for the RUST daemon.
#
#   1. daemon starts gvproxy (proot-wrapped) and waits for the bess socket
#   2. guest boots with the vec0 bess transport, runs dockerd + the demo web
#      container (guest 8123), printing WEB_UP_MARKER
#   3. `expose 18124 8123` over the control socket -> gvproxy API + registry
#   4. the host fetches http://127.0.0.1:18124 and must see the demo body
#   5. `ports` must list the registry entry
#   6. clean stop must leave no daemon, no gvproxy group, no guest behind
#
# SPDX-License-Identifier: GPL-2.0-only
set -uo pipefail
cd "$HOME/workspace/uml4termux" || exit 1

H="$HOME/.local/share/uml4termux"
IMG="$HOME/workspace/uml-forensics/cap7/debian-docker.ext4"
GV="$H/gvproxy"
RS="./rust/target/release/uml4termux-rs"
RT="$TMPDIR/gve2e"
INITRD="$TMPDIR/gvguest/initramfs.cpio.gz"
HOSTPORT=18124
GUESTPORT=8123

count() { local n; n=$(grep -ac "$1" "$2" 2>/dev/null); [ -n "$n" ] || n=0; printf '%s' "$n"; }

[ -x "$GV" ] || { echo "SKIP: no gvproxy binary at $GV"; exit 77; }
[ -r "$INITRD" ] || { echo "SKIP: no docker-guest initramfs at $INITRD"; exit 77; }
rm -rf "$RT"; mkdir -p "$RT"
IMG_BEFORE=$(sha256sum "$IMG" | cut -d' ' -f1)

UML4TERMUX_RUNTIME="$RT" \
UML4TERMUXD_KERNEL="$H/linux-bionic-smp" \
UML4TERMUXD_STUB="$H/stub_exe" \
UML4TERMUXD_IMAGE="$IMG" \
UML4TERMUXD_INITRAMFS="$INITRD" \
UML4TERMUXD_COW="$RT/guest.cow" \
UML4TERMUXD_MEM=1024M \
UML4TERMUXD_NCPUS=4 \
UML4TERMUXD_STRICT_UBD=1 \
UML4TERMUXD_GVPROXY="$GV" \
UML4TERMUXD_BESS="$RT/bess.sock" \
UML4TERMUXD_GVPROXY_SSH_PORT=12224 \
"$RS" daemon >"$RT/daemon.log" 2>&1 &
dp=$!

for _ in $(seq 1 180); do
  grep -qa 'WEB_UP_MARKER' "$RT/uml-console.log" 2>/dev/null && break
  grep -qa '"phase":"failed"' "$RT/daemon.sock.state" 2>/dev/null && break
  sleep 2
done
sleep 3

echo "GVPROXY_PID $(pgrep -f "$GV" | head -1 || echo none)"
echo "BESS_SOCK $([ -S "$RT/bess.sock" ] && echo yes || echo no)"
echo "GVAPI_SOCK $([ -S "$RT/bess.sock.gv.sock" ] && echo yes || echo no)"
echo "WEB_UP_MARKER $(count 'WEB_UP_MARKER' "$RT/uml-console.log")"
echo "DISK_ATTACHED $(count 'root_mounted' "$RT/uml-console.log")"

echo "--- daemon: gvproxy/threading lines ---"
grep -aE 'gvproxy|http health|re-appl' "$RT/daemon.log" | tail -4

echo "--- expose $HOSTPORT -> guest $GUESTPORT ---"
"$RS" --socket "$RT/daemon.sock" --raw expose "$HOSTPORT" "$GUESTPORT" | tee "$RT/expose.out"

echo "--- registry file ---"
cat "$RT/exposures.jsonl" 2>/dev/null || echo "(missing)"

echo "--- inbound fetch through the exposure ---"
BODY=$(curl -sS --max-time 15 "http://127.0.0.1:$HOSTPORT/" 2>&1 | head -c 200)
echo "CURL_BODY [$BODY]"

echo "--- ports over the control socket ---"
"$RS" --socket "$RT/daemon.sock" --raw ports

echo "--- HTTP health endpoint from inside the daemon would need UML4TERMUXD_HTTP; skip ---"

"$RS" --socket "$RT/daemon.sock" --raw stop >/dev/null 2>&1 || true
for _ in $(seq 1 30); do kill -0 "$dp" 2>/dev/null || break; sleep 1; done
echo "DAEMON_EXITED $([ -d "/proc/$dp" ] && echo no || echo yes)"
echo "GVPROXY_AFTER $(pgrep -f "$GV" | head -1 || echo none)"
echo "COW_BITS $(env -u LD_LIBRARY_PATH python3 - "$RT/guest.cow" <<'PY' 2>/dev/null || echo 0
import sys
with open(sys.argv[1], 'rb') as f:
    f.read(4608); bm = f.read(786432)
print(sum(bin(b).count('1') for b in bm))
PY
)"
IMG_AFTER=$(sha256sum "$IMG" | cut -d' ' -f1)
echo "IMAGE_UNCHANGED $([ "$IMG_BEFORE" = "$IMG_AFTER" ] && echo yes || echo no)"
