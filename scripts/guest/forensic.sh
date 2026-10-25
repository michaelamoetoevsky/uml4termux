#!/bin/sh
#
# uml4termux gate script: prints boot evidence then halts.
# Runs in the initramfs (busybox) if no disk, or after switch_root on the
# Debian image.  Never uses 'exit': the kernel hangs on exit; use 'poweroff -f'.
#
# SPDX-License-Identifier: GPL-2.0-only

set -u
PATH=/sbin:/usr/sbin:/bin:/usr/bin
export PATH

echo "=== UML4TERMUX_GATE_BEGIN ==="
echo "UNAME: $(uname -srm 2>/dev/null || uname -a)"

# Kernel config summary (if available)
if [ -f /proc/config.gz ]; then
  zcat /proc/config.gz 2>/dev/null | grep -E 'CONFIG_(OVERLAY_FS|VETH|BRIDGE|NETFILTER|PID_NS|USER_NS|CGROUP_PIDS|MEMCG|CGROUP2|DOCKER)' | head -20 || true
fi

# CPU count
echo "CPUS: $(grep -c ^processor /proc/cpuinfo 2>/dev/null || nproc 2>/dev/null || echo '?')"

# Network (vec0 may not exist in the initramfs)
if command -v ip >/dev/null 2>&1; then
  ip link set lo up 2>/dev/null
  if ip link show vec0 >/dev/null 2>&1; then
    ip link set vec0 up 2>/dev/null
    echo "vec0: up"
  fi
fi

# cgroup v2 controllers (if cgroupfs is mounted)
if [ -d /sys/fs/cgroup ]; then
  echo "cgroup2 controllers: $(cat /sys/fs/cgroup/cgroup.controllers 2>/dev/null || echo '?')"
fi

echo "GATE_OK"
echo "=== UML4TERMUX_GATE_END ==="

sync 2>/dev/null || true
if command -v poweroff >/dev/null 2>&1; then poweroff -f; fi
if [ -x /sbin/poweroff ]; then /sbin/poweroff -f; fi
# last resort: magic sysrq
echo o > /proc/sysrq-trigger 2>/dev/null || true
while true; do sleep 3600; done