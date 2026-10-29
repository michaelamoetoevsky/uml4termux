#!/usr/bin/env bash
# Corrected soak for the Rust daemon: N cycles, each one a REAL disk boot.
#
# Differences from the first soak (which silently measured diskless boots):
#   * private backing image (never touched by the runit service), so UML's
#     exclusive F_SETLK cannot collide with another guest
#   * UML4TERMUXD_STRICT_UBD=1, so a failed ubd attach aborts instead of
#     quietly running the guest in RAM
#   * every cycle must prove the disk attached (init's root_mounted +
#     SWITCH_ROOT_NOW) and that the guest's writes reached the COW bitmap
#   * RSS is sampled from the daemon-reported child pid, not from a global
#     process-name match (which also sees the service's own guest)
#
# SPDX-License-Identifier: GPL-2.0-only
set -uo pipefail
cd "$HOME/workspace/uml4termux" || exit 1

H="$HOME/.local/share/uml4termux"
IMG="$HOME/workspace/uml-forensics/cap7/debian-docker.ext4"
RS="./rust/target/release/uml4termux-rs"
BASE="$TMPDIR/soak-real"
CYCLES="${1:-6}"
INITRD="$TMPDIR/rustguest/initramfs.cpio.gz"

[ -x "$RS" ] || { echo "FAIL: rust daemon not built"; exit 1; }
[ -r "$IMG" ] || { echo "FAIL: private image missing at $IMG"; exit 1; }
[ -r "$INITRD" ] || { echo "FAIL: initramfs missing"; exit 1; }

rm -rf "$BASE"; mkdir -p "$BASE"

# grep -c prints "0" AND exits 1 on no match, so `|| echo 0` appends a second
# line and every numeric test breaks. Always emit exactly one integer.
count() { local n; n=$(grep -ac "$1" "$2" 2>/dev/null); [ -n "$n" ] || n=0; printf '%s' "$n"; }
IMG_BEFORE=$(sha256sum "$IMG" | cut -d' ' -f1)
IMG_MTIME_BEFORE=$(stat -c %Y "$IMG")
echo "SOAK_START cycles=$CYCLES image=$IMG"
echo "IMG_BEFORE $IMG_BEFORE mtime=$IMG_MTIME_BEFORE"

ok=0; fail=0; peak_rss=0
for i in $(seq 1 "$CYCLES"); do
  RT="$BASE/c$i"; mkdir -p "$RT"
  UML4TERMUX_RUNTIME="$RT" \
  UML4TERMUXD_KERNEL="$H/linux-bionic-smp" \
  UML4TERMUXD_STUB="$H/stub_exe" \
  UML4TERMUXD_IMAGE="$IMG" \
  UML4TERMUXD_INITRAMFS="$INITRD" \
  UML4TERMUXD_COW="$RT/guest.cow" \
  UML4TERMUXD_MEM=1024M \
  UML4TERMUXD_NCPUS=4 \
  UML4TERMUXD_STRICT_UBD=1 \
  "$RS" daemon >"$RT/daemon.log" 2>&1 &
  dp=$!

  t0=$(date +%s)
  rss=0
  for _ in $(seq 1 120); do
    cp_id=$(sed -n 's/.*"child_pid":\([0-9]\+\).*/\1/p' "$RT/daemon.sock.state" 2>/dev/null | tail -1)
    if [ -n "${cp_id:-}" ] && [ "$cp_id" -gt 0 ] 2>/dev/null && [ -r "/proc/$cp_id/status" ]; then
      cur=$(awk '/VmRSS/{print $2}' "/proc/$cp_id/status" 2>/dev/null || echo 0)
      [ "${cur:-0}" -gt "$rss" ] 2>/dev/null && rss=$cur
    fi
    grep -qE '"phase":"(completed|failed)"' "$RT/daemon.sock.state" 2>/dev/null && break
    sleep 1
  done
  t1=$(date +%s)
  [ "${rss:-0}" -gt "$peak_rss" ] && peak_rss=$rss

  disk=$(count 'root_mounted' "$RT/uml-console.log")
  switch=$(count 'SWITCH_ROOT_NOW' "$RT/uml-console.log")
  nodisk=$(count 'NO_DISK' "$RT/uml-console.log")
  markers=$(count 'RUSTDAEMON_' "$RT/uml-console.log")
  state=$(cat "$RT/daemon.sock.state" 2>/dev/null || echo none)
  bits=$(env -u LD_LIBRARY_PATH python3 - "$RT/guest.cow" <<'PY' 2>/dev/null || echo 0
import sys
with open(sys.argv[1], 'rb') as f:
    f.read(4608)
    bm = f.read(786432)
print(sum(bin(b).count('1') for b in bm))
PY
)
  alloc=$(du -sk "$RT/guest.cow" 2>/dev/null | cut -f1)

  if [ "$disk" -ge 1 ] && [ "$switch" -ge 1 ] && [ "$nodisk" -eq 0 ] \
     && [ "${bits:-0}" -gt 0 ] && [ "${markers:-0}" -ge 5 ] \
     && printf '%s' "$state" | grep -q '"phase":"completed"'; then
    ok=$((ok + 1)); verdict=ok
  else
    fail=$((fail + 1)); verdict=FAIL
  fi
  echo "cycle $i: $verdict disk=$disk switch_root=$switch nodisk=$nodisk markers=$markers cow_bits=${bits:-0} cow_kb=${alloc:-0} rss_kb=$rss secs=$((t1 - t0))"
  [ "$verdict" = FAIL ] && { echo "  state=$state"; grep -aE 'FAIL|Failed|ubd|aborting' "$RT/daemon.log" | tail -3; }

  "$RS" --socket "$RT/daemon.sock" --raw stop >/dev/null 2>&1 || true
  wait "$dp" 2>/dev/null || true
  sleep 2
  rm -rf "$RT"
done

IMG_AFTER=$(sha256sum "$IMG" | cut -d' ' -f1)
IMG_MTIME_AFTER=$(stat -c %Y "$IMG")
echo "IMG_AFTER $IMG_AFTER mtime=$IMG_MTIME_AFTER"
[ "$IMG_BEFORE" = "$IMG_AFTER" ] && [ "$IMG_MTIME_BEFORE" = "$IMG_MTIME_AFTER" ] \
  && echo "PRIVATE_IMAGE_UNCHANGED yes" || echo "PRIVATE_IMAGE_UNCHANGED no"
echo "PEAK_GUEST_RSS_KB $peak_rss"
echo "RESULT cycles=$CYCLES ok=$ok fail=$fail"
