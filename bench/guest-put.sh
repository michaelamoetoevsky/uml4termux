#!/usr/bin/env bash
# Chunked script upload over the exec channel.
#
# The exec channel delivers ONE console line (the guest agent does
# `IFS= read -r aline` on /dev/console and evals it), and a line longer than what
# the PTY line discipline carries arrives truncated -- measured: 569 bytes arrived
# intact, 2182 bytes produced nothing at all, silently. So a recipe is uploaded as
# base64 in pieces that are comfortably below that, then decoded and run. Every
# piece is its own exec call, which is why the exec rate limit must be off for
# harnesses.
#
# usage: source this file; guest_put_script <rt> <daemon-bin> <local-script> <guest-path>
set -uo pipefail

GUEST_CHUNK="${GUEST_CHUNK:-380}"

guest_exec() { # <rt> <daemon-bin> <command>
  UML4TERMUX_RUNTIME="$1" UML4TERMUXD_EXEC_MIN_INTERVAL_MS=0 "$2" exec "$3" >/dev/null 2>&1
}

guest_put_script() { # <rt> <daemon-bin> <local-script> <guest-path>
  local rt="$1" dbin="$2" src="$3" dst="$4" b64 i=0 piece total
  b64="$(base64 -w0 <"${src}")"
  total=$(( (${#b64} + GUEST_CHUNK - 1) / GUEST_CHUNK ))
  guest_exec "${rt}" "${dbin}" "rm -f ${dst}.b64 ${dst}"
  while [ "${i}" -lt "${total}" ]; do
    piece="${b64:$(( i * GUEST_CHUNK )):GUEST_CHUNK}"
    if [ "${i}" -eq 0 ]; then
      guest_exec "${rt}" "${dbin}" "printf '%s' '${piece}' > ${dst}.b64"
    else
      guest_exec "${rt}" "${dbin}" "printf '%s' '${piece}' >> ${dst}.b64"
    fi
    i=$((i + 1))
  done
  guest_exec "${rt}" "${dbin}" "base64 -d < ${dst}.b64 > ${dst}; chmod +x ${dst}"
  printf '  uploaded %s (%s B base64 in %s chunk(s), max %s B per exec)\n' \
    "${dst}" "${#b64}" "${total}" "${GUEST_CHUNK}"
}