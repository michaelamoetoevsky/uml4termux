# shellcheck shell=bash
#
# uml4termux — lib/mobility.sh
# Android lifecycle helpers: the Termux wake lock.
#
# A UML guest with a full Docker daemon is a sustained, CPU-heavy workload
# running inside an ordinary app process.  Android decides when to freeze an
# app: with the screen off and no wakelock, the guest is put to doze and stops
# making progress (measured: see docs/MOBILITY.md §5).  Holding a wake lock
# keeps the CPU awake for as long as the guest runs.
#
# The lock is released by 'uml4termux stop' and, as a safety net, by the
# watchdog that removes the runtime directory.  The lock is *not* released
# when the command that acquired it exits: the guest keeps running in the
# background, so releasing it there would defeat the purpose.
#
# SPDX-License-Identifier: GPL-2.0-only

# Is a Termux wake lock available on this host?
uml4termux_wakelock_available() {
  command -v termux-wake-lock >/dev/null 2>&1 &&
    command -v termux-wake-unlock >/dev/null 2>&1
}

uml4termux_wakelock_state_file() {
  printf '%s/wakelock.state' "${UML4TERMUX_RUNTIME}"
}

# Acquire the wake lock.  Returns:
#   0  lock held
#   1  not available on this host (not an error: it is a Termux-only feature)
#   2  the lock tool failed
uml4termux_wakelock_acquire() {
  local state; state="$(uml4termux_wakelock_state_file)"
  if ! uml4termux_wakelock_available; then
    warn "termux-wake-lock is not installed; the guest may be frozen when the screen is off"
    warn "install it with: pkg install termux-tools"
    return 1
  fi
  uml4termux_runtime_init
  if uml4termux_is_dry_run; then
    printf '+ termux-wake-lock\n'
    return 0
  fi
  if termux-wake-lock >/dev/null 2>&1; then
    printf 'acquired\n' >"${state}"
    ok "wake lock acquired (the guest keeps running with the screen off)"
    return 0
  fi
  err "termux-wake-lock failed"
  return 2
}

# Release the wake lock.  Safe to call when no lock is held.
uml4termux_wakelock_release() {
  local state; state="$(uml4termux_wakelock_state_file)"
  if ! uml4termux_wakelock_available; then
    rm -f "${state}"
    return 0
  fi
  if [ ! -f "${state}" ]; then
    return 0
  fi
  if uml4termux_is_dry_run; then
    printf '+ termux-wake-unlock\n'
    rm -f "${state}"
    return 0
  fi
  termux-wake-unlock >/dev/null 2>&1 || warn "termux-wake-unlock failed"
  rm -f "${state}"
  info "wake lock released"
  return 0
}

# Is a lock currently held by us?
uml4termux_wakelock_held() {
  [ -f "$(uml4termux_wakelock_state_file)" ]
}
