#!/usr/bin/env bash
# Controlled COW-isolation experiment around one Rust-daemon guest boot.
# SPDX-License-Identifier: GPL-2.0-only
set -uo pipefail
cd "$HOME/workspace/uml4termux" || exit 1
H="$HOME/.local/share/uml4termux"
IMG="$H/debian-docker.ext4"
RS="./rust/target/release/uml4termux-rs"
RT="$TMPDIR/cowexp"
COW="$RT/guest.cow"

rm -rf "$RT"; mkdir -p "$RT"
h() { sha256sum "$1" | cut -d' ' -f1; }

echo "IMAGE_BEFORE $(h "$IMG")"
echo "MTIME_BEFORE $(stat -Lc %y "$IMG")"

UML4TERMUX_RUNTIME="$RT" \
UML4TERMUXD_KERNEL="$H/linux-bionic-smp" \
UML4TERMUXD_STUB="$H/stub_exe" \
UML4TERMUXD_IMAGE="$IMG" \
UML4TERMUXD_INITRAMFS="$TMPDIR/rustguest/initramfs.cpio.gz" \
UML4TERMUXD_COW="$COW" \
UML4TERMUXD_MEM=1024M \
UML4TERMUXD_NCPUS=4 \
"$RS" daemon >"$RT/daemon.log" 2>&1 &
DP=$!

for _ in $(seq 1 120); do
  if grep -q '"phase":"completed"' "$RT/daemon.sock.state" 2>/dev/null; then break; fi
  sleep 1
done
sleep 2

echo "GUEST_MARKERS $(grep -c 'RUSTDAEMON_' "$RT/uml-console.log" 2>/dev/null || echo 0)"
echo "STATE $(cat "$RT/daemon.sock.state" 2>/dev/null)"
echo "COW_SIZE $(stat -c %s "$COW" 2>/dev/null || echo missing)"
echo "COW_HAS_MARKER $(grep -ac 'rust-daemon-boot' "$COW" 2>/dev/null || echo 0)"
echo "IMAGE_AFTER $(h "$IMG")"
echo "MTIME_AFTER $(stat -Lc %y "$IMG")"

# second, independent hash of the COW for the record
echo "COW_SHA $(h "$COW")"

kill "$DP" 2>/dev/null || true
wait "$DP" 2>/dev/null || true
echo "LEFTOVER_UML $(pgrep -c -x linux-bionic 2>/dev/null || echo 0)"
