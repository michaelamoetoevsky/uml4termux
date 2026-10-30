#!/bin/sh
# ---------------------------------------------------------------------------
# Instance registry — the launcher's own bookkeeping (direction G3).
#
# One record per named instance at ${UML4TERMUX_STATE_DIR}/instances/<name>.env:
#
#   NAME=<name>
#   RUNTIME=<runtime dir>      socket, state, console log
#   IMAGE=<backing image>      what UML holds an exclusive F_SETLK on
#   SSH_PORT=<host port>       what gvproxy hard-binds
#   PID=<daemon pid>
#   STARTED=<timestamp>
#
# Why it exists: the two invariants that used to live only in prose -- one guest
# per backing image, one gvproxy per host ssh port -- are exactly the two silent
# failures this project has already hit. A registry turns them into enforcement:
# `up` refuses to start an instance that would violate either.
#
# Nothing here reads `sv` or any runit path: this is launcher state, so the same
# bookkeeping works under runit, systemd, s6 or a bare shell.
#
# SPDX-License-Identifier: GPL-2.0-only
# ---------------------------------------------------------------------------

uml4termux_reg_dir() { printf '%s/instances' "${UML4TERMUX_STATE_DIR}"; }
uml4termux_reg_path() { printf '%s/%s.env' "$(uml4termux_reg_dir)" "${1:?instance name}"; }

uml4termux_reg_write() { # <name> <runtime> <image> <ssh_port> <pid>
  local name="$1" rt="$2" image="$3" port="$4" pid="$5" dir tmp
  uml4termux_is_dry_run && { printf '+ (registry write %s)\n' "${name}"; return 0; }
  dir="$(uml4termux_reg_dir)"
  mkdir -p "${dir}"
  tmp="$(uml4termux_reg_path "${name}").tmp"
  {
    printf 'NAME=%s\n' "${name}"
    printf 'RUNTIME=%s\n' "${rt}"
    printf 'IMAGE=%s\n' "${image}"
    printf 'SSH_PORT=%s\n' "${port}"
    printf 'PID=%s\n' "${pid}"
    printf 'STARTED=%s\n' "$(uml4termux_now)"
  } > "${tmp}"
  mv -f "${tmp}" "$(uml4termux_reg_path "${name}")"
}

uml4termux_reg_get() { # <name> <key>
  local name="$1" key="$2" line f
  f="$(uml4termux_reg_path "${name}")"
  [ -r "${f}" ] || return 1
  while IFS= read -r line; do
    case "${line}" in "${key}="*) printf '%s' "${line#*=}"; return 0 ;; esac
  done < "${f}"
  return 1
}

uml4termux_reg_names() {
  local dir f
  dir="$(uml4termux_reg_dir)"
  [ -d "${dir}" ] || return 0
  for f in "${dir}"/*.env; do
    [ -e "${f}" ] || continue
    f="${f##*/}"
    printf '%s\n' "${f%.env}"
  done
}

# An instance is live when its recorded pid is alive AND its own socket answers
# the contract handshake. A pid alone is not proof (pid reuse); a socket alone
# is not proof (a stale file survives a crash).
uml4termux_reg_live() { # <name>
  local name="$1" rt pid dbin
  rt="$(uml4termux_reg_get "${name}" RUNTIME)" || return 1
  pid="$(uml4termux_reg_get "${name}" PID)" || return 1
  [ -n "${rt}" ] && [ -n "${pid}" ] || return 1
  uml4termux_pid_alive "${pid}" uml4termux || return 1
  [ -S "${rt}/daemon.sock" ] || return 1
  dbin="$(uml4termux_daemon_bin)" || return 1
  # The Rust front end pretty-prints JSON by default (the C one does not), so
  # this must tolerate whitespace: a strict '"protocol":1' match silently made
  # every live instance look dead -- which left daemons, guests and gvproxy
  # running after `up` reported failure.
  UML4TERMUX_RUNTIME="${rt}" "${dbin}" protocol 2>/dev/null \
    | grep -qE '"protocol"[[:space:]]*:[[:space:]]*1'
}

uml4termux_reg_prune() { # drop records whose instance is gone; print how many
  local name n=0
  for name in $(uml4termux_reg_names); do
    if uml4termux_reg_live "${name}"; then continue; fi
    uml4termux_is_dry_run || rm -f "$(uml4termux_reg_path "${name}")"
    n=$((n + 1))
  done
  printf '%s' "${n}"
}

uml4termux_reg_live_image() { # <image path> -> name of the live instance using it
  local name img
  for name in $(uml4termux_reg_names); do
    uml4termux_reg_live "${name}" || continue
    img="$(uml4termux_reg_get "${name}" IMAGE)"
    [ "${img}" = "$1" ] && { printf '%s' "${name}"; return 0; }
  done
  return 1
}

uml4termux_reg_live_runtime() { # <runtime dir> -> name of the live instance owning it
  local name rt
  for name in $(uml4termux_reg_names); do
    uml4termux_reg_live "${name}" || continue
    rt="$(uml4termux_reg_get "${name}" RUNTIME)"
    [ "${rt}" = "$1" ] && { printf '%s' "${name}"; return 0; }
  done
  return 1
}

uml4termux_reg_live_ssh_port() { # <port> -> name of the live instance holding it
  local name port
  for name in $(uml4termux_reg_names); do
    uml4termux_reg_live "${name}" || continue
    port="$(uml4termux_reg_get "${name}" SSH_PORT)"
    [ "${port}" = "$1" ] && { printf '%s' "${name}"; return 0; }
  done
  return 1
}

# First free ssh port: gvproxy binds 2222 by default, so a second instance needs
# its own. Deterministic scan keeps the value explainable in the docs.
uml4termux_reg_pick_ssh_port() {
  local p
  for p in 2222 12222 12223 12224 12225 12226 12227 12228 12229; do
    uml4termux_reg_live_ssh_port "${p}" >/dev/null 2>&1 || { printf '%s' "${p}"; return 0; }
  done
  return 1
}

# Phase of an instance's state file. Guarded on purpose: `sed` exits 2 when the
# file does not exist yet (or any more), and under `set -e` that silently kills
# the caller mid-function -- which is exactly how `status` on a stopped instance
# turned into a bare exit 2 with no output.
uml4termux_state_phase() { # <runtime dir>
  local f="$1/daemon.sock.state"
  [ -r "${f}" ] || return 0
  sed -n 's/.*"phase":"\([a-z]*\)".*/\1/p' "${f}" 2>/dev/null || true
}
