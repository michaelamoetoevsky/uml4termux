#!/bin/bash
#
# uml4termux docker init: network, cgroups, dockerd, web containers.
# Runs after switch_root in the Debian 12 + Docker image.
# Tokens @@KEY@@ are substituted by scripts/build-initramfs.py at build time.
#
# SPDX-License-Identifier: GPL-2.0-only

set -u
export PATH=/usr/local/sbin:/usr/sbin:/sbin:/bin:/usr/bin

GUEST_ENTRY="@@GUEST_ENTRY@@"
GUEST_MODE="@@GUEST_MODE@@"
GUEST_IP="@@GUEST_IP@@"
GUEST_GW="@@GUEST_GW@@"
GUEST_DNS="@@GUEST_DNS@@"
WEB_PORTS="@@WEB_PORTS@@"
GUEST_LIFETIME="@@GUEST_LIFETIME@@"

echo "=== UML4TERMUX_DOCKER_BEGIN ==="
echo "UNAME: $(uname -srm)"

# ── console agent FIRST ───────────────────────────────────────────────────────────────────
# The daemon writes `exec:<command>` lines to the console and this loop is what reads them, so
# it must start before anything that can block. It used to start after two `docker pull`s with
# 300 s timeouts each: during boot -- and for as long as the network stalled -- every host
# command was echoed and never read, and the clean-shutdown request was never executed.
# Measured before this change: three `exec:` lines in the console, zero `__AGENT_GOT__`, zero
# `TICK` -- the guest never reached the loop (docs/ISSUES.md #8).
( while IFS= read -r aline; do
    case "$aline" in
      exec:*)
        printf '__AGENT_GOT__: %s\n' "${aline#exec:}"
        ( eval "${aline#exec:}" ) &
        ;;
    esac
  done ) < /dev/console &
echo "__AGENT_READY__"

# Network: vec0 is the BESS virtual ethernet interface
ip link set lo up
ip link set vec0 up
if command -v dhclient >/dev/null 2>&1; then
  dhclient -1 -v vec0 2>&1 | tail -2
else
  echo "dhclient not found, using static fallback"
fi
if ! ip -o addr show vec0 | grep -q 'inet 192\.168\.127\.'; then
  ip addr add "${GUEST_IP}/24" dev vec0
  ip route add default via "${GUEST_GW}" dev vec0
  printf 'nameserver %s\n' "${GUEST_DNS}" > /etc/resolv.conf
  echo "STATIC_FALLBACK applied"
fi
echo "ADDR: $(ip -o addr show vec0 | tr '\n' ' ')"
echo "ROUTE: $(ip route show | tr '\n' ' ')"
echo "RESOLV: $(cat /etc/resolv.conf 2>/dev/null | tr '\n' ' ')"
echo "DNS_TEST: $(getent hosts registry-1.docker.io 2>&1 | head -1)"

# cgroups v2 + clean run dirs
mount -t cgroup2 none /sys/fs/cgroup 2>&1
mount -t tmpfs tmpfs /run 2>&1
rm -rf /run/containerd /run/docker /var/run/docker.pid

# Start dockerd in the background. The log is TRUNCATED first: it lives on the guest image, so
# without this it carries the previous session's lines and makes a healthy boot look like a
# restart loop (measured: three containerd "starting signal loop" entries inside one 90 s
# window, none of them from that boot).
: > /var/log/dockerd.log
( dockerd >>/var/log/dockerd.log 2>&1 & )
echo "starting dockerd..."
# Instrumented: say how many attempts it took and how long the successful one itself took.
# "dockerd ready at 84 s" was attributed to the loop, and a loop can be slow for two very
# different reasons -- many fast failures, or one call that hangs -- which need different fixes.
wait_start=$(date +%s)
attempts=0
while [ "${attempts}" -lt 60 ]; do
  attempts=$((attempts + 1))
  if docker info >/dev/null 2>&1; then
    echo "DOCKERD_WAIT attempts=${attempts} total_s=$(( $(date +%s) - wait_start ))"
    break
  fi
  sleep 2
done

# Say it out loud, from the guest. `up` returning does not mean dockerd is listening -- `up`
# answers when the control socket is up, which is seconds earlier -- and the host must not infer
# readiness from a marker it typed itself.
if docker info >/dev/null 2>&1; then
  SERVER=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo 'unknown')
  DRIVER=$(docker info -f '{{.Driver}}' 2>/dev/null || echo 'unknown')
  CGROUPV=$(docker info -f '{{.CgroupVersion}}' 2>/dev/null || echo 'unknown')
  echo "SERVER=${SERVER} DRIVER=${DRIVER} CGROUPV=${CGROUPV}"
  # dockerd's own timestamps, in the same console as the wall clock: the only way to tell
  # "dockerd was slow to start" from "the first client call hung" -- measured: the first
  # `docker info` took ~46 s and the second one, immediately after, answered at 48 s.
  echo "--- dockerd startup (its own clock) ---"
  grep -aE 'API listen|Daemon has completed|Default bridge|Loading containers|Start docker' /var/log/dockerd.log | tail -6
  echo "DOCKERD_READY_FOR_REAL"
else
  echo "DOCKERD_FAILED_AFTER_120S"
  tail -15 /var/log/dockerd.log
fi

# ── images: pull only when MISSING ───────────────────────────────────────────────────────
# An unconditional pull at boot makes boot time a function of the network -- the same sequence
# measured 10 s in one capture and 178 s in another, and here it also stood between the guest
# and its own console agent. A present image costs one `inspect`; a missing one is fetched.
pull_if_missing() {
  local img="$1"
  if docker image inspect "${img}" >/dev/null 2>&1; then
    echo "IMAGE_PRESENT ${img}"
    return 0
  fi
  echo "IMAGE_PULL ${img}"
  timeout 300 docker pull "${img}" 2>&1 | tail -1
}
if docker info >/dev/null 2>&1; then
  pull_if_missing busybox:latest
  pull_if_missing alpine:latest
else
  echo "IMAGES_SKIPPED dockerd is not answering"
fi

# Local-only runtime check: proves the container runtime works without needing the network at
# boot. The old check ran `nslookup` at boot, so a DNS hiccup delayed every boot.
echo "--- local runtime check ---"
timeout 120 docker run --rm busybox:latest sh -c 'echo BUSYBOX_RUN_OK' 2>&1 | tail -3

# Web containers publishing the ports we will expose (skipped when the image is absent)
echo "--- published port container ---"
docker rm -f web webh >/dev/null 2>&1
if docker image inspect alpine:latest >/dev/null 2>&1; then
  docker run -d --name web -p 8123:80 alpine sh -c 'while true; do printf "HTTP/1.1 200 OK\r\nContent-Length: 15\r\n\r\ngvproxy-bess-ok\n" | nc -l -p 80; done' 2>&1 | tail -1
  for port in ${WEB_PORTS}; do
    if [ "${port}" = "8124" ]; then
      docker run -d --name webh --network host alpine sh -c 'while true; do printf "HTTP/1.1 200 OK\r\nContent-Length: 11\r\n\r\nhostnet-ok\n" | nc -l -p 8124; done' 2>&1 | tail -1
    fi
  done
else
  echo "WEB_SKIPPED alpine:latest not present"
fi
sleep 12
docker ps --format '{{.Names}} | {{.Status}} | {{.Ports}}' 2>&1 | head -4

echo "WEB_UP_MARKER"

# Lifetime: 0 = run forever with heartbeat; >0 = power off after N seconds
if [ "${GUEST_LIFETIME}" -gt 0 ] 2>/dev/null; then
  echo "guest lifetime ${GUEST_LIFETIME}s, then poweroff"
  sleep "${GUEST_LIFETIME}"
  echo "=== UML4TERMUX_DOCKER_END ==="
  sync; poweroff -f
else
  # Heartbeat so the host can see the guest is alive
  n=0
  while true; do
    sleep 30
    n=$((n + 1))
    echo "TICK ${n}"
  done
fi