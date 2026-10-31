#!/usr/bin/env bash
# Classify an aarch64 binary as portable or libc-bound, by reading its ELF
# headers rather than trusting a filename. Direction D1 rests on this
# distinction: a STATIC binary needs no loader and runs on any aarch64 Linux,
# while a dynamically linked one names the loader it requires -- /system/bin/
# linker64 means Android (bionic), /lib/ld-linux-aarch64.so.1 means glibc. The
# shipped kernel and stub_exe are static; the shipped daemon is not.
#
# usage: ci/glibc/classify.sh <binary> [binary...]
#        exit 0 = every binary classified, 2 = a binary could not be read
# SPDX-License-Identifier: GPL-2.0-only
set -uo pipefail

[ $# -gt 0 ] || { echo "usage: $0 <binary> [binary...]" >&2; exit 64; }

status=0
for f in "$@"; do
  if [ ! -r "$f" ]; then
    printf '%-28s %s\n' "$(basename "$f")" "UNREADABLE (missing or not readable)"
    status=2
    continue
  fi
  # `file` on a build host may be absent; readelf comes with binutils and is
  # authoritative about the interpreter. BUT the reverse also happens: binutils is
  # not installed everywhere (it is not on the device), and then readelf says
  # nothing while file(1) still names the interpreter -- which is how the shipped
  # daemon first came back "UNKNOWN" instead of BIONIC-ONLY. Read both.
  kind="$( (command -v file >/dev/null 2>&1 && file -b "$f") 2>/dev/null || echo '')"
  interp=""
  if command -v readelf >/dev/null 2>&1; then
    interp="$(readelf -l "$f" 2>/dev/null | sed -n 's/.*[Rr]equesting program interpreter: \[\(.*\)\]/\1/p' | head -1)"
  fi
  if [ -z "$interp" ]; then
    interp="$(printf '%s' "$kind" | sed -n 's/.*interpreter \([^,]*\).*/\1/p' | head -1)"
  fi
  if [ -n "$interp" ]; then
    case "$interp" in
      /system/bin/linker64) verdict="BIONIC-ONLY (device): interpreter ${interp}" ;;
      /lib/ld-linux-aarch64.so.1 | /lib64/ld-linux-aarch64.so.1 | ld-linux-aarch64.so.1)
        verdict="glibc (Linux): interpreter ${interp}" ;;
      *) verdict="libc-bound: interpreter ${interp}" ;;
    esac
  elif printf '%s' "$kind" | grep -q 'statically linked'; then
    verdict="PORTABLE (static, no loader)"
  else
    verdict="UNKNOWN (no interpreter and file(1) says: ${kind:-nothing})"
    status=2
  fi
  printf '%-28s %s\n' "$(basename "$f")" "${verdict}"
done
exit "${status}"
