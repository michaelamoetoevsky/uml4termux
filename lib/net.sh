# shellcheck shell=bash
#
# uml4termux — lib/net.sh
# gvproxy (userspace net stack + port forwarder) lifecycle and inbound port
# exposure.  gvproxy bridges the host loopback to the guest's vec0 (BESS
# transport), which is the only inbound path that works unprivileged here.
#
# SPDX-License-Identifier: GPL-2.0-only

# ---------------------------------------------------------------------------
# proot wrapper
# ---------------------------------------------------------------------------
# gvproxy reads /etc/resolv.conf for its upstream DNS.  Android has none, and
# Termux cannot create it, so gvproxy runs under `proot -b $PREFIX/etc:/etc`.
# On a normal Linux host the real /etc/resolv.conf exists and proot is
# unnecessary (and may not be installed).
net_proot_wanted() {
  case "${UML4TERMUX_GVPROXY_PROOT}" in
    always) return 0 ;;
    never)  return 1 ;;
  esac
  command -v proot >/dev/null 2>&1 || return 1
  [ -r /etc/resolv.conf ] && return 1
  [ -r "${PREFIX}/etc/resolv.conf" ] || return 1
  return 0
}

net_gvproxy_argv() {
  # echoes the argv (one line, shell-quoted) and sets the global GV_ARGV array
  GV_ARGV=()
  if net_proot_wanted; then
    GV_ARGV+=(proot -b "${PREFIX}/etc:/etc")
  fi
  GV_ARGV+=("$(uml4termux_asset_path gvproxy)")
  GV_ARGV+=(-debug
            -listen "unix://${UML4TERMUX_GVNET_SOCK}"
            -listen-bess "unixpacket://${UML4TERMUX_BESS_SOCK}"
            -log-file "${UML4TERMUX_GVPROXY_LOG}")
  uml4termux_quote "${GV_ARGV[@]}"
}

# ---------------------------------------------------------------------------
# start / readiness / stop
# ---------------------------------------------------------------------------
net_start_gvproxy() {
  uml4termux_require_assets gvproxy
  local bin; bin="$(uml4termux_asset_path gvproxy)"
  uml4termux_runtime_init

  step "starting gvproxy (BESS bridge: ${UML4TERMUX_BESS_SOCK})"
  # A previous UML run leaves the BESS peer gone and gvproxy dead: never reuse
  # sockets, always start a fresh process for this run.
  if ! uml4termux_is_dry_run; then
    rm -f "${UML4TERMUX_GVNET_SOCK}" "${UML4TERMUX_BESS_SOCK}"
    : > "${UML4TERMUX_GVPROXY_LOG}"
  else
    printf '+ rm -f %s %s\n' "$(uml4termux_quote "${UML4TERMUX_GVNET_SOCK}" "${UML4TERMUX_BESS_SOCK}")" ""
    printf '+ : > %s\n' "${UML4TERMUX_GVPROXY_LOG}"
  fi

  if net_proot_wanted; then
    info "proot -b ${PREFIX}/etc:/etc (gvproxy needs /etc/resolv.conf)"
  else
    info "no proot wrapper needed on this host (or UML4TERMUX_GVPROXY_PROOT=never)"
  fi

  GV_ARGV=()
  if net_proot_wanted; then GV_ARGV+=(proot -b "${PREFIX}/etc:/etc"); fi
  GV_ARGV+=("${bin}" -debug
            -listen "unix://${UML4TERMUX_GVNET_SOCK}"
            -listen-bess "unixpacket://${UML4TERMUX_BESS_SOCK}"
            -log-file "${UML4TERMUX_GVPROXY_LOG}")
  uml4termux_spawn gvproxy /dev/null "${GV_ARGV[@]}"

  net_wait_ready "${UML4TERMUX_GVPROXY_READY_TIMEOUT:-40}"
}

net_wait_ready() {
  local timeout="${1:-40}" i pid
  if uml4termux_is_dry_run; then
    printf '+ (wait up to %ss for %s and %s)\n' "${timeout}" "${UML4TERMUX_BESS_SOCK}" "${UML4TERMUX_GVNET_SOCK}"
    return 0
  fi
  for ((i = 0; i < timeout; i++)); do
    if [ -S "${UML4TERMUX_BESS_SOCK}" ] && [ -S "${UML4TERMUX_GVNET_SOCK}" ]; then
      ok "gvproxy up: control ${UML4TERMUX_GVNET_SOCK}, bess ${UML4TERMUX_BESS_SOCK}"
      return 0
    fi
    pid="$(uml4termux_read_pid gvproxy)"
    if [ -n "${pid}" ] && ! uml4termux_pid_alive "${pid}"; then
      err "gvproxy died during startup (pid ${pid})"
      uml4termux_tail "${UML4TERMUX_GVPROXY_LOG}" 20
      return 1
    fi
    sleep 1
  done
  err "gvproxy did not create its sockets within ${timeout}s"
  uml4termux_tail "${UML4TERMUX_GVPROXY_LOG}" 20
  return 1
}

net_gvproxy_alive() {
  local pid; pid="$(uml4termux_read_pid gvproxy)"
  uml4termux_pid_alive "${pid}"
}

net_health() {
  # GET /services/forwarder/all is the lightest control-plane probe.
  uml4termux_run curl -sS -m 10 --unix-socket "${UML4TERMUX_GVNET_SOCK}" \
    http://unix/services/forwarder/all
}

net_stop() {
  # Order matters: kill UML first so gvproxy sees the BESS peer EOF, then
  # gvproxy.  gvproxy exits by itself on peer disconnect, so a missing process
  # here is normal, not an error.
  step "stopping uml4termux instance"
  uml4termux_kill_label uml
  uml4termux_kill_label gvproxy
  if uml4termux_is_dry_run; then
    printf '+ rm -f %s\n' "$(uml4termux_quote "${UML4TERMUX_GVNET_SOCK}" "${UML4TERMUX_BESS_SOCK}")"
    printf '+ rm -rf %s\n' "${HOME}/.uml/${UML4TERMUX_UMID}"
    return 0
  fi
  rm -f "${UML4TERMUX_GVNET_SOCK}" "${UML4TERMUX_BESS_SOCK}"
  # kernel umid dir (~/.uml/<umid>): only removed when no UML process is left
  local upid; upid="$(uml4termux_read_pid uml)"
  if ! uml4termux_pid_alive "${upid}"; then
    rm -rf "${HOME}/.uml/${UML4TERMUX_UMID}" 2>/dev/null || true
  fi
  uml4termux_instance_clear
  rm -f "$(uml4termux_pidfile uml)" "$(uml4termux_pidfile gvproxy)"
  ok "instance stopped"
}

# ---------------------------------------------------------------------------
# port forwarding (host loopback -> guest)
# ---------------------------------------------------------------------------
net_parse_mapping() {
  # "8123" or "8123:80" -> "8123 8123" / "8123 80"
  local spec="$1" host guest
  host="${spec%%:*}"
  if [ "${spec}" = "${host}" ]; then guest="${host}"; else guest="${spec##*:}"; fi
  case "${host}" in ''|*[!0-9]*) die "bad port specification: '${spec}' (expected HOSTPORT[:GUESTPORT])" ;; esac
  case "${guest}" in ''|*[!0-9]*) die "bad guest port in: '${spec}'" ;; esac
  printf '%s %s' "${host}" "${guest}"
}

net_expose() {
  local spec="$1" host guest parsed
  parsed="$(net_parse_mapping "${spec}")"
  host="${parsed%% *}"; guest="${parsed##* }"
  if ! uml4termux_is_dry_run; then
    net_gvproxy_alive || die "gvproxy is not running; expose needs a live instance (see 'uml4termux docker')"
  fi
  local payload
  payload="$(printf '{"local":"127.0.0.1:%s","remote":"%s:%s"}' "${host}" "${UML4TERMUX_GUEST_IP}" "${guest}")"
  uml4termux_run curl -sS -m 10 --unix-socket "${UML4TERMUX_GVNET_SOCK}" \
    -X POST -d "${payload}" http://unix/services/forwarder/expose
  info "exposed 127.0.0.1:${host} -> guest ${UML4TERMUX_GUEST_IP}:${guest}"
}

net_unexpose() {
  local spec="$1" host guest parsed
  parsed="$(net_parse_mapping "${spec}")"
  host="${parsed%% *}"; guest="${parsed##* }"
  if ! uml4termux_is_dry_run; then
    net_gvproxy_alive || die "gvproxy is not running"
  fi
  local payload
  payload="$(printf '{"local":"127.0.0.1:%s","remote":"%s:%s"}' "${host}" "${UML4TERMUX_GUEST_IP}" "${guest}")"
  uml4termux_run curl -sS -m 10 --unix-socket "${UML4TERMUX_GVNET_SOCK}" \
    -X POST -d "${payload}" http://unix/services/forwarder/unexpose >/dev/null
  info "unexposed 127.0.0.1:${host}"
}

# net_verify_port <port> [timeout] -> prints HTTP result, rc 0 when reachable
net_verify_port() {
  local port="$1" timeout="${2:-8}" out rc=0
  if uml4termux_is_dry_run; then
    printf '+ curl -sS -m %s -o - http://127.0.0.1:%s/\n' "${timeout}" "${port}"
    return 0
  fi
  if command -v curl >/dev/null 2>&1; then
    out="$(curl -sS -m "${timeout}" -o - "http://127.0.0.1:${port}/" 2>&1)" || rc=$?
  else
    out="$(uml4termux_python - "${port}" "${timeout}" <<'PYEOF'
import socket, sys
port, t = int(sys.argv[1]), float(sys.argv[2])
try:
    s = socket.create_connection(('127.0.0.1', port), timeout=t)
    s.sendall(b'GET / HTTP/1.0\r\nHost: localhost\r\n\r\n')
    data = s.recv(300).decode('utf-8', 'replace').strip().replace('\r', '')
    s.close()
    print(data)
except Exception as e:  # noqa: BLE001 - report the failure verbatim
    print('FAIL', type(e).__name__, e)
    sys.exit(1)
PYEOF
)" || rc=$?
  fi
  if [ "${rc}" -ne 0 ] || [ -z "${out}" ]; then
    printf 'FAIL\t127.0.0.1:%s\t%s\n' "${port}" "${out:-no response}"
    return 1
  fi
  printf 'OK\t127.0.0.1:%s\t%s\n' "${port}" "$(printf '%s' "${out}" | head -1)"
  return 0
}
