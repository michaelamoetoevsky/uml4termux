#!/usr/bin/env bash
# Direction G2/G3 device proof: drive a REAL guest through the launcher
# (up/status/logs/expose/down) with failing runit shims first on PATH, so the
# "no runit" claim is tested rather than assumed.
#
# SPDX-License-Identifier: GPL-2.0-only
set -uo pipefail
cd "$HOME/workspace/uml4termux" || exit 1

W="$TMPDIR/g23-proof"; rm -rf "$W"
mkdir -p "$W/home" "$W/state" "$W/initramfs" "$W/rt" "$W/shim" "$W/guest"
KERNEL_PIN="6970ada592e49c03f90e1b422ffb38ea0ceced9d9d1de1c5120542126a426c02"
KERNEL_URL="https://github.com/michaelamoetoevsky/uml4termux/releases/download/v0.5.0/linux-bionic"
FORE="$HOME/.local/share/uml4termux"
IMG_SRC="$HOME/workspace/uml-forensics/cap7/debian-docker.ext4"
RS="$PWD/rust/target/release/uml4termux-rs"

count() { local n; n=$(grep -ac "$1" "$2" 2>/dev/null); [ -n "$n" ] || n=0; printf '%s' "$n"; }

echo "== 1. aset ter-pin di home terisolasi =="
ln -sf "$FORE/stub_exe" "$W/home/stub_exe"
ln -sf "$FORE/gvproxy" "$W/home/gvproxy"
ln -sf "$FORE/initramfs-alpine.cpio.gz" "$W/home/initramfs-alpine.cpio.gz"
if [ ! -s "$W/home/linux-bionic" ]; then
  curl -fsSL -o "$W/home/linux-bionic.part" "$KERNEL_URL" && mv -f "$W/home/linux-bionic.part" "$W/home/linux-bionic"
fi
# curl does not set the exec bit; `fetch` does, and the kernel is exec'd directly
# (without it the daemon's child dies with exit 127).
chmod 0755 "$W/home/linux-bionic"
KD="$(sha256sum "$W/home/linux-bionic" 2>/dev/null | cut -d' ' -f1)"
echo "KERNEL_SHA256 ${KD:0:16} match=$([ "$KD" = "$KERNEL_PIN" ] && echo yes || echo no) size=$(stat -c%s "$W/home/linux-bionic" 2>/dev/null)"

echo "== 2. initramfs docker + image privat =="
cp scripts/guest/init scripts/guest/docker-init.sh scripts/guest/forensic.sh "$W/guest/" 2>/dev/null
chmod 0755 "$W"/guest/* 2>/dev/null
env -u LD_LIBRARY_PATH python3 scripts/build-initramfs.py \
  --guest-dir "$W/guest" --base "$W/home/initramfs-alpine.cpio.gz" \
  --entry /docker-init.sh --out "$W/initramfs/docker.cpio.gz" --force >"$W/build.log" 2>&1
echo "INITRAMFS $([ -s "$W/initramfs/docker.cpio.gz" ] && echo built || echo FAILED) $(stat -c%s "$W/initramfs/docker.cpio.gz" 2>/dev/null)"
ln -f "$IMG_SRC" "$W/img.ext4" 2>/dev/null || cp "$IMG_SRC" "$W/img.ext4"
IMG_BEFORE="$(sha256sum "$W/img.ext4" | cut -d' ' -f1)"
echo "IMAGE_BEFORE ${IMG_BEFORE:0:16} ($(stat -c%s "$W/img.ext4") byte)"

echo "== 3. shim runit yang gagal keras =="
for t in sv runsv runsvdir svlogd chpst; do
  printf '#!/bin/sh\necho "SHIM_FIRED %s $*" >&2\nexit 111\n' "$t" > "$W/shim/$t"
  chmod +x "$W/shim/$t"
done
export PATH="$W/shim:$PATH"

export UML4TERMUX_HOME="$W/home"
export UML4TERMUX_STATE_DIR="$W/state"
export UML4TERMUX_INITRAMFS_DIR="$W/initramfs"
export UML4TERMUX_RUNTIME="$W/rt"
export UML4TERMUXD_BIN="$RS"
export UML4TERMUXD_SELFTEST_CHILD="$(command -v sleep || echo /bin/sleep)"
export NO_COLOR=1

echo "== 4. up (launcher, tanpa runit) =="
t0=$(date +%s)
./bin/uml4termux up --name g2 --image "$W/img.ext4" --ssh-port 12224 --timeout 180 >"$W/up.out" 2>&1
up_rc=$?
t1=$(date +%s)
echo "UP_RC $up_rc after $((t1 - t0))s"
printf '  status: %s\n' "$(grep -a 'state  *:' "$W/up.out" | head -1)"
echo "  registry: $(tr '\n' ' ' < "$W/state/instances/g2.env" 2>/dev/null)"

echo "== 5. guest benar-benar jalan =="
for _ in $(seq 1 60); do [ "$(count 'WEB_UP_MARKER' "$W/rt/uml-console.log")" -ge 1 ] && break; sleep 2; done
echo "WEB_UP_MARKER $(count 'WEB_UP_MARKER' "$W/rt/uml-console.log")"
echo "DISK_ATTACHED $(count 'root_mounted' "$W/rt/uml-console.log")"
echo "NO_DISK $(count 'NO_DISK' "$W/rt/uml-console.log")"
echo "KERNEL_LINE $(grep -ao 'Linux [0-9][^ ]*[^,]*' "$W/rt/uml-console.log" 2>/dev/null | head -1)"

echo "== 6. logs lewat launcher =="
./bin/uml4termux logs --name g2 -l 3 >"$W/logs.out" 2>&1; echo "LOGS_RC $? lines=$(wc -l <"$W/logs.out")"
./bin/uml4termux logs --name g2 --console -l 400 2>/dev/null | grep -ac 'WEB_UP_MARKER' | sed 's/^/  marker lewat logs --console: /'

echo "== 7. expose + inbound =="
./bin/uml4termux expose 18127:8123 2>&1 | head -2
BODY="$(curl -sS --max-time 15 http://127.0.0.1:18127/ 2>&1 | head -c 60)"
echo "CURL_BODY [$BODY]"

echo "== 8. status/ls =="
./bin/uml4termux status --name g2 --json
./bin/uml4termux ls

echo "== 9. down + teardown =="
PID="$(./bin/uml4termux status --name g2 --json | sed -n 's/.*"pid":"\([0-9]*\)".*/\1/p')"
./bin/uml4termux down --name g2 --timeout 45; echo "DOWN_RC $?"
sleep 2
echo "DAEMON_GONE $([ -d "/proc/$PID" ] && echo no || echo yes)"
echo "GVPROXY_MINE $(ps -eo pid,args 2>/dev/null | awk -v rt="$W" '$0 ~ rt && /gvproxy/ {c++} END {print c+0}')"
echo "GUEST_MINE $(ps -eo pid,args 2>/dev/null | awk -v rt="$W" '$0 ~ rt && /bionic/ {c++} END {print c+0}')"
echo "REGISTRY_AFTER $(ls "$W/state/instances" 2>/dev/null | wc -l)"
IMG_AFTER="$(sha256sum "$W/img.ext4" | cut -d' ' -f1)"
echo "IMAGE_UNCHANGED $([ "$IMG_BEFORE" = "$IMG_AFTER" ] && echo yes || echo no)"
echo "SHIM_FIRED $(count 'SHIM_FIRED' "$W/up.out") (dari up.out; 0 = runit tidak pernah dipanggil)"
echo "COW_BYTES $(stat -c%s "$W/rt/g2.cow" 2>/dev/null || echo none)"
