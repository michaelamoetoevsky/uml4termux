#!/bin/sh
# ---------------------------------------------------------------------------
# Guest side of the performance benchmark (docs/NEXT-STEPS.md, direction A).
#
# Runs as the initramfs entry point. Prints machine-readable RESULT lines on the
# UML console; the host driver (bench/bench.sh) parses them. Nothing here writes
# to the backing image: the disk profile is READ-ONLY on purpose, so a benchmark
# can never disturb an image or a digest baseline.
#
# Profiles (sizes scale by @@BENCH_SCALE@@, substituted at build time; 1 = the
# documented campaign size):
#   forkexec  1500 x /bin/true         -- syscall / fork-exec heavy
#   pagefault 512 MiB read, bs=4k      -- one fault per page (131072 faults)
#   diskread  1 GiB read via /dev/ubda -- sequential ubd path, no writes
#
# Timing source: /proc/uptime (0.01 s resolution). Every phase announces itself
# BEFORE it starts and after it ends, so a slow run is observable instead of
# looking like a hang.
#
# SPDX-License-Identifier: GPL-2.0-only
# ---------------------------------------------------------------------------
set -u

SCALE="@@BENCH_SCALE@@"
[ -n "${SCALE}" ] || SCALE=1

now_ms() { awk '{ printf "%d", $1 * 1000 }' /proc/uptime; }
say() { printf '%s\n' "$*"; }
scaled() { awk -v a="$1" -v s="${SCALE}" 'BEGIN { v = a * s; printf "%d", (v < 1 ? 1 : v) }'; }

FORK_N="$(scaled 1500)"
FILL_MB="$(scaled 512)"
DISK_MB="$(scaled 1024)"

say "BENCH_START kernel=$(uname -r) ncpu=$(grep -c ^processor /proc/cpuinfo) page=$(getconf PAGE_SIZE 2>/dev/null || echo '?') scale=${SCALE}"
say "BENCH_PLAN forkexec_n=${FORK_N} pagefault_mb=${FILL_MB} diskread_mb=${DISK_MB}"

# --- 1. fork + exec -------------------------------------------------------
say "PHASE forkexec START"
t0=$(now_ms)
i=0
while [ "$i" -lt "${FORK_N}" ]; do
  /bin/true
  i=$((i + 1))
done
t1=$(now_ms)
say "RESULT profile=forkexec n=${FORK_N} ms=$((t1 - t0))"
say "PHASE forkexec END"

# --- 2. page-fault heavy (4k reads = one fault per page) ------------------
# The file is created from /dev/zero: filling it is SETUP cost, excluded from the
# measured window, and the fault cost on read is the same -- what is measured is
# the fault path, not /dev/urandom's throughput.
say "PHASE pagefault FILL ${FILL_MB}MiB"
dd if=/dev/zero of=/tmp/bench.bin bs=1M count="${FILL_MB}" 2>/dev/null
sync
say "PHASE pagefault START"
t0=$(now_ms)
dd if=/tmp/bench.bin of=/dev/null bs=4k 2>/dev/null
t1=$(now_ms)
say "RESULT profile=pagefault bytes=$((FILL_MB * 1048576)) bs=4096 ms=$((t1 - t0))"
say "PHASE pagefault END"
rm -f /tmp/bench.bin

# --- 3. sequential disk read, read-only ----------------------------------
if [ -b /dev/ubda ]; then
  say "PHASE diskread START"
  t0=$(now_ms)
  dd if=/dev/ubda of=/dev/null bs=1M count="${DISK_MB}" 2>/dev/null
  t1=$(now_ms)
  say "RESULT profile=diskread bytes=$((DISK_MB * 1048576)) ms=$((t1 - t0))"
  say "PHASE diskread END"
else
  say "RESULT profile=diskread skipped=1 reason=no-ubda"
fi

say "BENCH_DONE"
# poweroff -f, never exit: exiting leaves the kernel hanging (see the skill).
poweroff -f 2>/dev/null || reboot -f 2>/dev/null || true