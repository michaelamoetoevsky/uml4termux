#!/bin/sh
# ---------------------------------------------------------------------------
# Guest side of the operational soak (docs/NEXT-STEPS.md, direction B).
#
# One cycle: cgroups + tmpfs /run, start dockerd, wait for the API, run a
# container from a CACHED image (a pull only when nothing is cached), report
# machine-readable SOAK_* lines, then power off. The host driver decides whether
# the cycle passed; this script never lies about a failure -- a missing image or
# a dead dockerd is reported as such.
#
# SPDX-License-Identifier: GPL-2.0-only
# ---------------------------------------------------------------------------
set -u

say() { printf '%s\n' "$*"; }
now_ms() { awk '{ printf "%d", $1 * 1000 }' /proc/uptime; }

say "SOAK_TICK_START kernel=$(uname -r) uptime_s=$(cut -d' ' -f1 /proc/uptime)"

# --- networking (only needed if we have to pull) ---------------------------
if ! ip -o addr show vec0 2>/dev/null | grep -q 'inet 192\.168\.127\.'; then
  ip addr add 192.168.127.2/24 dev vec0 2>/dev/null || true
  ip route add default via 192.168.127.1 dev vec0 2>/dev/null || true
  printf 'nameserver 192.168.127.1\n' > /etc/resolv.conf 2>/dev/null || true
fi

# --- cgroups v2 + clean runtime dirs --------------------------------------
mount -t cgroup2 none /sys/fs/cgroup 2>/dev/null || true
mount -t tmpfs tmpfs /run 2>/dev/null || true
rm -rf /run/containerd /run/docker /var/run/docker.pid

t0=$(now_ms)
( dockerd >/var/log/dockerd.log 2>&1 & )
ready=no
i=0
while [ "$i" -lt 60 ]; do
  if docker info >/dev/null 2>&1; then ready=yes; break; fi
  sleep 2
  i=$((i + 1))
done
t1=$(now_ms)
server="$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo none)"
say "SOAK_DOCKERD ready=${ready} ms=$((t1 - t0)) server=${server}"

# --- one container run, from a cached image when possible ------------------
img=""
for cand in busybox:latest alpine:latest hello-world:latest; do
  if docker image inspect "$cand" >/dev/null 2>&1; then img="$cand"; break; fi
done
if [ -z "$img" ]; then
  say "SOAK_PULL image=busybox:latest"
  if timeout 150 docker pull busybox:latest >/dev/null 2>&1; then img=busybox:latest; fi
fi
if [ -n "$img" ]; then
  t0=$(now_ms)
  out="$(timeout 60 docker run --rm "$img" echo SOAK_RUN_OK 2>&1 | tail -1)"
  t1=$(now_ms)
  say "SOAK_RUN image=${img} out=${out} ms=$((t1 - t0))"
else
  say "SOAK_RUN skipped=1 reason=no-image"
fi

say "SOAK_INFO driver=$(docker info -f '{{.Driver}}' 2>/dev/null || echo none) cgroupv=$(docker info -f '{{.CgroupVersion}}' 2>/dev/null || echo none) containers=$(docker ps -aq 2>/dev/null | wc -l | tr -d ' ')"
say "SOAK_GUESTMEM $(awk '/^MemTotal/{t=$2} /^MemAvailable/{a=$2} END{printf "total_kb=%d avail_kb=%d", t, a}' /proc/meminfo)"
say "SOAK_TICK_DONE"

poweroff -f 2>/dev/null || reboot -f 2>/dev/null || true