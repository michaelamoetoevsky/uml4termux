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

# Start dockerd in the background
( dockerd >/var/log/dockerd.log 2>&1 & )
echo "starting dockerd..."
for i in $(seq 1 60); do
  docker info >/dev/null 2>&1 && break
  sleep 2
done

SERVER=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo 'unknown')
DRIVER=$(docker info -f '{{.Driver}}' 2>/dev/null || echo 'unknown')
CGROUPV=$(docker info -f '{{.CgroupVersion}}' 2>/dev/null || echo 'unknown')
echo "SERVER=${SERVER} DRIVER=${DRIVER} CGROUPV=${CGROUPV}"

# Pull base images through gvproxy NAT/DNS
echo "--- fresh pull through gvproxy NAT/DNS ---"
timeout 300 docker pull busybox:latest 2>&1 | tail -2
timeout 300 docker pull alpine:latest 2>&1 | tail -2

# Run a quick test container
echo "--- run pulled image ---"
timeout 120 docker run --rm busybox:latest sh -c 'echo BUSYBOX_RUN_OK; nslookup registry-1.docker.io 2>&1 | tail -3' 2>&1 | tail -6

# Web containers publishing the ports we will expose
echo "--- published port container ---"
docker rm -f web webh >/dev/null 2>&1
docker run -d --name web -p 8123:80 alpine sh -c 'while true; do printf "HTTP/1.1 200 OK\r\nContent-Length: 15\r\n\r\ngvproxy-bess-ok\n" | nc -l -p 80; done' 2>&1 | tail -1
for port in ${WEB_PORTS}; do
  if [ "${port}" = "8124" ]; then
    docker run -d --name webh --network host alpine sh -c 'while true; do printf "HTTP/1.1 200 OK\r\nContent-Length: 11\r\n\r\nhostnet-ok\n" | nc -l -p 8124; done' 2>&1 | tail -1
  fi
done
sleep 12
docker ps --format '{{.Names}} | {{.Status}} | {{.Ports}}' 2>&1 | head -4

echo "WEB_UP_MARKER"

# A2b console agent: lines the daemon writes to the console in the form
#   exec:<command>
# are evaluated here; output lands on the console (= the daemon's PTY log).
( while IFS= read -r aline; do
    case "$aline" in
      exec:*) echo "__AGENT_GOT__: ${aline#exec:}"; eval "${aline#exec:}" ;;
    esac
  done ) < /dev/console &


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