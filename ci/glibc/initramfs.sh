#!/usr/bin/env bash
# Build a minimal initramfs (newc cpio, gzipped) whose /init prints markers and
# powers off. Used to prove a UML kernel boots on a host, with no disk image and
# no loop mounts -- the guest never needs a root filesystem, so the only things
# under test are the kernel and the host's ability to run it.
#
# busybox-static is required: a dynamically linked busybox would drag the host's
# libc into the guest, and the guest has no libc at all.
#
# usage: ci/glibc/initramfs.sh <output.cpio.gz> [marker]
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail

OUT="${1:?usage: $0 <output.cpio.gz> [marker]}"
MARKER="${2:-GLIBCBOOT}"

BUSYBOX=""
for c in /bin/busybox /usr/bin/busybox; do
  if [ -x "$c" ]; then
    if (command -v file >/dev/null 2>&1 && file -b "$c" | grep -q 'statically linked') \
       || ! command -v file >/dev/null 2>&1; then
      BUSYBOX="$c"
      break
    fi
  fi
done
[ -n "$BUSYBOX" ] || {
  echo "initramfs: no static busybox found (install busybox-static)" >&2
  exit 1
}

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
mkdir -p "${work}/root/bin" "${work}/root/proc" "${work}/root/sys" "${work}/root/dev"
cp "${BUSYBOX}" "${work}/root/bin/busybox"
for applet in sh mount umount cat uname sleep poweroff ls getconf; do
  ln -s busybox "${work}/root/bin/${applet}"
done

# Every line the harness asserts on is prefixed with the marker, so a stray
# kernel message can never satisfy an assertion by accident. The payloads are
# echoed with od, not typed: the console echoes the init script's own text when
# the kernel traces exec, and a literal marker in the script would let the echo
# pass the check while the guest did nothing.
cat >"${work}/root/init" <<'INIT'
#!/bin/busybox sh
/bin/busybox mount -t proc none /proc 2>/dev/null
/bin/busybox mount -t sysfs none /sys 2>/dev/null
printf '%s-OK arch=%s\n' MARKER "$(/bin/busybox uname -m)"
printf '%s-RELEASE %s\n' MARKER "$(/bin/busybox uname -r)"
printf '%s-NCPU %s\n' MARKER "$(/bin/busybox grep -c ^processor /proc/cpuinfo)"
printf '%s-MEMTOTAL %s\n' MARKER "$(/bin/busybox awk '/^MemTotal/{print $2}' /proc/meminfo)"
printf '%s-DONE\n' MARKER
/bin/busybox sync
/bin/busybox poweroff -f
# poweroff -f on a UML guest ends the kernel; if that ever fails, do not sit
# here forever holding the CI job.
/bin/busybox sleep 30
INIT
chmod +x "${work}/root/init"
sed -i "s/MARKER/${MARKER}/g" "${work}/root/init"

( cd "${work}/root" && find . | cpio -o -H newc 2>/dev/null | gzip -9 ) >"${OUT}"
echo "initramfs: ${OUT} ($(stat -c%s "${OUT}") B, marker ${MARKER})"
