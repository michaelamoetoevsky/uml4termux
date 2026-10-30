#!/bin/sh
# ---------------------------------------------------------------------------
# Own log layout and rotation (direction G4) -- no svlogd needed.
#
# A runtime directory holds three logs, all of which grow without bound while an
# instance runs:
#
#   daemon.log          daemon stdout/stderr (written by the launcher's spawn)
#   uml-console.log     raw guest console (written by the daemon)
#   bess.sock.gv.log    gvproxy's own log (written by gvproxy)
#
# Policy, deliberately simple and explainable:
#   * rotate when a file exceeds UML4TERMUX_LOG_MAX_BYTES (default 10 MiB);
#   * keep UML4TERMUX_LOG_KEEP generations (default 3), then drop the oldest;
#   * rotate from copy+truncate, never by renaming the live file, so a process
#     that already holds the file open keeps writing to the SAME inode (a rename
#     would leave it writing to the rotated generation forever);
#   * callers: `up` rotates before each start, `uml4termux rotate` rotates on
#     demand, and a launcher adapter tick may call it -- that is the svlogd role
#     without svlogd.
#
# SPDX-License-Identifier: GPL-2.0-only
# ---------------------------------------------------------------------------

UML4TERMUX_LOG_MAX_BYTES="${UML4TERMUX_LOG_MAX_BYTES:-10485760}"
UML4TERMUX_LOG_KEEP="${UML4TERMUX_LOG_KEEP:-3}"

uml4termux_log_size() { # <file> -> bytes (0 when missing)
  local f="$1" n
  [ -f "${f}" ] || { printf '0'; return 0; }
  n="$(wc -c < "${f}" 2>/dev/null | tr -d ' ')"
  [ -n "${n}" ] || n=0
  printf '%s' "${n}"
}

# Rotate one file when it exceeds <max_bytes>. Keeps <keep> generations.
uml4termux_log_rotate_file() { # <file> [max_bytes] [keep] -> prints "rotated|kept"
  local f="$1" max="${2:-${UML4TERMUX_LOG_MAX_BYTES}}" keep="${3:-${UML4TERMUX_LOG_KEEP}}"
  local size i
  size="$(uml4termux_log_size "${f}")"
  if [ "${size}" -le "${max}" ]; then
    printf 'kept'
    return 0
  fi
  if uml4termux_is_dry_run; then
    printf '+ (rotate %s: %s bytes, keep %s)\n' "${f}" "${size}" "${keep}"
    printf 'rotated'
    return 0
  fi
  # shift the older generations out of the way, oldest first
  i=$((keep - 1))
  while [ "${i}" -ge 1 ]; do
    if [ -f "${f}.${i}" ]; then mv -f "${f}.${i}" "${f}.$((i + 1))"; fi
    i=$((i - 1))
  done
  rm -f "${f}.$((keep + 1))"
  # keep the current contents as generation 1, then empty the live file IN PLACE
  cp -f "${f}" "${f}.1" 2>/dev/null || true
  : > "${f}"
  printf 'rotated'
}

uml4termux_log_files() { # <runtime dir> -> the three log paths
  printf '%s\n' "$1/daemon.log" "$1/uml-console.log" "$1/bess.sock.gv.log"
}

uml4termux_log_total() { # <runtime dir> -> bytes across the three logs + generations
  local rt="$1" f n total=0
  for f in $(uml4termux_log_files "${rt}"); do
    n="$(uml4termux_log_size "${f}")"; total=$((total + n))
  done
  printf '%s' "${total}"
}

# Rotate every log of one runtime dir. Prints "<file> <before> -> rotated|kept".
uml4termux_log_rotate_runtime() { # <runtime dir> [max_bytes] [keep]
  local rt="$1" max="${2:-${UML4TERMUX_LOG_MAX_BYTES}}" keep="${3:-${UML4TERMUX_LOG_KEEP}}"
  local f before action
  for f in $(uml4termux_log_files "${rt}"); do
    [ -f "${f}" ] || continue
    before="$(uml4termux_log_size "${f}")"
    action="$(uml4termux_log_rotate_file "${f}" "${max}" "${keep}")"
    printf '%s %s %s\n' "${f}" "${before}" "${action}"
  done
}
