#!/bin/sh
# ---------------------------------------------------------------------------
# Minimal POSIX supervisor for uml4termux (direction G5).
#
# This is the "plain" adapter: it needs nothing but a POSIX shell, so it works
# on any host -- a bare Termux shell, a container without an init, a CI runner.
# It only knows the documented launcher hook `uml4termux up --foreground`, which
# runs the daemon in the foreground; the daemon already supervises the guest.
#
# Contract:
#   * exit code 0 from `up --foreground` = a deliberate stop (someone ran
#     `uml4termux down`), so the supervisor exits too;
#   * any other exit = a crash, so it restarts after a backoff.
#
# Environment:
#   UML4TERMUX_INSTANCE_NAME   instance name (default "default")
#   UML4TERMUX_SUPERVISE_BACKOFF  seconds between restarts (default 2)
#   UML4TERMUX_SUPERVISE_MAX      stop after N restarts, 0 = unlimited (default 0)
#
# SPDX-License-Identifier: GPL-2.0-only
# ---------------------------------------------------------------------------
set -u

BIN="${UML4TERMUX_BIN:-uml4termux}"
instance="${UML4TERMUX_INSTANCE_NAME:-default}"
backoff="${UML4TERMUX_SUPERVISE_BACKOFF:-2}"
max="${UML4TERMUX_SUPERVISE_MAX:-0}"
tries=0

while :; do
  "$BIN" up --foreground --name "$instance" "$@"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "supervise: 'up --foreground' exited 0 (deliberate stop); not restarting" >&2
    exit 0
  fi
  tries=$((tries + 1))
  echo "supervise: instance '$instance' exited $rc; restart $tries" >&2
  if [ "$max" -gt 0 ] && [ "$tries" -ge "$max" ]; then
    echo "supervise: restart budget ($max) reached; giving up" >&2
    exit "$rc"
  fi
  sleep "$backoff"
done
