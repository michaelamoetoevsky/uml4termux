#!/usr/bin/env bash
#
# Daemon hardening contract (direction E3). Runs against a real daemon in
# --selftest mode (no guest, no assets), so CI can run it anywhere.
#
# Proves the four things direction E3 promises:
#   * the control socket is owner-only (0600) and the audit log is created 0600;
#   * a connection from a DIFFERENT uid is refused by the daemon itself
#     (SO_PEERCRED), not merely by the file mode -- exercised by starting the
#     daemon as another user and connecting as root, which is the only way to
#     reach a 0600 socket without being its owner. Needs root, so it SKIPs
#     elsewhere, and it says so instead of pretending to have tested it;
#   * `exec` is rate limited, and a refused exec is refused in the log too;
#   * every state-changing command leaves one line in audit.log, and a crafted
#     command cannot forge a second line.
#
# usage: tests/test-daemon-security.sh [daemon-binary]
# SPDX-License-Identifier: GPL-2.0-only
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
fails=0
skips=0
daemon_pid=""
other_pid=""

cleanup() {
  for p in "${daemon_pid}" "${other_pid}"; do
    [ -n "${p}" ] && kill -TERM "${p}" 2>/dev/null
  done
  sleep 1
  for p in "${daemon_pid}" "${other_pid}"; do
    [ -n "${p}" ] && kill -KILL "${p}" 2>/dev/null
  done
  rm -rf "${work}"
}
trap 'cleanup' EXIT

ok()  { printf '  PASS: %s\n' "$1"; }
bad() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }
skip() { printf '  SKIP: %s\n' "$1"; skips=$((skips + 1)); }
chk() { # <description> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi
}
has() { # <description> <needle> <haystack>
  case "$3" in
    *"$2"*) ok "$1" ;;
    *) bad "$1 (no '$2' in: $(printf '%s' "$3" | head -c 160))" ;;
  esac
}

# --- the daemon under test -------------------------------------------------
# An explicit path first, as the other daemon-driven tests take one, so CI can
# hand over the binary it compiled for the RUNNER's architecture. Otherwise
# $UML4TERMUXD_BIN, otherwise the tracked one -- but only if this host can
# actually execute it: the tracked binary is built for the device (aarch64), and
# on an x86_64 runner exec fails with "Exec format error" (the shell then tries to
# parse the ELF as a script, which is how this test first failed in CI).
mkdir -p "${work}/probe"
runnable() { # <binary> -> 0 when this host can execute it
  local out rc
  out="$(UML4TERMUX_RUNTIME="${work}/probe" "$1" status 2>&1)"
  rc=$?
  case "${rc}" in 126 | 127) return 1 ;; esac
  case "${out}" in *"Exec format error"* | *"cannot execute"*) return 1 ;; esac
  return 0
}
compile_daemon() { # <out>
  { cc -O2 -o "$1" "${ROOT}/src/uml4termuxd.c" 2>/dev/null \
      || clang -O2 -o "$1" "${ROOT}/src/uml4termuxd.c" 2>/dev/null; } || return 1
  [ -x "$1" ]
}
DBIN="${1:-${UML4TERMUXD_BIN:-${ROOT}/bin/uml4termuxd}}"
if [ ! -x "${DBIN}" ] || ! runnable "${DBIN}"; then
  alt="${work}/uml4termuxd"
  if compile_daemon "${alt}" && runnable "${alt}"; then
    DBIN="${alt}"
  else
    echo "SKIP: ${DBIN} cannot run on this host and ${ROOT}/src/uml4termuxd.c did not compile"
    exit 77
  fi
fi
echo "daemon under test: ${DBIN}"

# Every daemon-driven test in this repo names the selftest child explicitly: the
# built-in default is a Termux path, which does not exist on a CI runner (exec then
# fails 127 and the daemon gives up).
SELFTEST_SLEEP="${UML4TERMUXD_SELFTEST_CHILD:-$(command -v sleep || echo /bin/sleep)}"
export UML4TERMUXD_SELFTEST_CHILD="${SELFTEST_SLEEP}"

runtime="${work}/rt"
mkdir -p "${runtime}"
# Created 0700 so the assertion below tests the DAEMON (it must not loosen it,
# umask 0077) instead of testing this script's own mkdir.
chmod 700 "${runtime}"
start_daemon() { # [env assignments...]
  UML4TERMUX_RUNTIME="${runtime}" UML4TERMUXD_SELFTEST_SECONDS="${SELFTEST_SECONDS:-120}" \
    env "$@" "${DBIN}" daemon --selftest >"${work}/daemon.log" 2>&1 &
  daemon_pid=$!
  local i=0
  while [ "${i}" -lt 40 ]; do
    if [ -S "${runtime}/daemon.sock" ] \
       && UML4TERMUX_RUNTIME="${runtime}" "${DBIN}" status >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.5
    i=$((i + 1))
  done
  return 1
}
stop_daemon() {
  [ -n "${daemon_pid}" ] && kill -TERM "${daemon_pid}" 2>/dev/null
  sleep 1
  daemon_pid=""
}

printf '\nE3.1/E3.2: owner-only socket and audit log\n'
if start_daemon UML4TERMUXD_EXEC_MIN_INTERVAL_MS=400; then
  ok "daemon hidup (selftest)"
else
  bad "daemon tidak siap"; sed -n '1,10p' "${work}/daemon.log" | sed 's/^/    /'
fi
chk "mode socket 0600" "600" "$(stat -c%a "${runtime}/daemon.sock" 2>/dev/null)"
chk "mode audit.log 0600" "600" "$(stat -c%a "${runtime}/audit.log" 2>/dev/null)"
chk "direktori runtime tidak world-readable" "700" "$(stat -c%a "${runtime}" 2>/dev/null)"

printf '\nE3.3: exec di-rate-limit, dan penolakannya ikut tercatat\n'
out1="$(UML4TERMUX_RUNTIME="${runtime}" "${DBIN}" exec 'echo satu' 2>&1)"
out2="$(UML4TERMUX_RUNTIME="${runtime}" "${DBIN}" exec 'echo dua' 2>&1)"
has "exec pertama lolos pembatas (sampai ke penolakan guest)" "guest not running" "${out1}"
has "exec kedua dalam jendela yang sama DITOLAK" "rate-limited" "${out2}"
has "balasan menyebut jendelanya" "min_interval_ms" "${out2}"
sleep 0.6
out3="$(UML4TERMUX_RUNTIME="${runtime}" "${DBIN}" exec 'echo tiga' 2>&1)"
has "setelah jendela lewat, exec diterima lagi" "guest not running" "${out3}"

printf '\nE3.4: audit log mencatat, dan tidak bisa dipalsukan\n'
audit="$(cat "${runtime}/audit.log" 2>/dev/null)"
has "baris exec tercatat" "exec uid=" "${audit}"
has "perintahnya ikut tercatat" "echo satu" "${audit}"
has "penolakan rate-limit tercatat" "exec-denied uid=" "${audit}"
has "dan alasannya ikut" "rate-limited" "${audit}"
n_before="$(grep -c '' "${runtime}/audit.log" 2>/dev/null || echo 0)"
# A real ESC byte in the command: if control characters were written through, one
# command could inject a second line and forge an audit entry of its own.
crafted="$(printf 'printf x\033[31m; echo injeksi')"
UML4TERMUX_RUNTIME="${runtime}" "${DBIN}" exec "${crafted}" >/dev/null 2>&1
sleep 0.6
n_after="$(grep -c '' "${runtime}/audit.log" 2>/dev/null || echo 0)"
chk "satu perintah = tepat dua baris (permintaan + penolakan guest)" "$((n_before + 2))" "${n_after}"
if LC_ALL=C grep -q "$(printf '\033')" "${runtime}/audit.log" 2>/dev/null; then
  bad "byte kontrol lolos ke berkas audit"
else
  ok "byte kontrol dinetralkan (ESC menjadi '_')"
fi
has "teks perintah tetap terbaca sesudah sanitasi" "injeksi" "$(cat "${runtime}/audit.log")"
UML4TERMUX_RUNTIME="${runtime}" "${DBIN}" stop >/dev/null 2>&1
sleep 1
has "perintah stop tercatat" "stop uid=" "$(cat "${runtime}/audit.log" 2>/dev/null)"
has "audit memakai UTC ISO-8601" "Z stop uid=" "$(cat "${runtime}/audit.log" 2>/dev/null)"
stop_daemon

printf '\nE3.5: koneksi dari uid lain ditolak daemon (SO_PEERCRED)\n'
if [ "$(id -u)" = "0" ]; then
  rt2="${work}/rt2"
  mkdir -p "${rt2}"
  other="u4tsec"
  id "${other}" >/dev/null 2>&1 || useradd -M -s /bin/false "${other}"
  chown -R "${other}" "${rt2}" 2>/dev/null
  chmod 755 "${work}"
  su -s /bin/sh "${other}" -c "UML4TERMUX_RUNTIME='${rt2}' UML4TERMUXD_SELFTEST_SECONDS=120 ${DBIN} daemon --selftest" >"${work}/daemon2.log" 2>&1 &
  other_pid=$!
  i=0
  while [ "${i}" -lt 40 ]; do
    [ -S "${rt2}/daemon.sock" ] && break
    sleep 0.5
    i=$((i + 1))
  done
  if [ -S "${rt2}/daemon.sock" ]; then
    reply="$(UML4TERMUX_RUNTIME="${rt2}" "${DBIN}" status 2>&1 || true)"
    has "root ditolak oleh daemon milik user lain" "not the owner" "${reply}"
    sleep 1
    has "penolakan tercatat di audit" "denied uid=" "$(cat "${rt2}/audit.log" 2>/dev/null)"
  else
    bad "daemon milik user lain tidak siap"
    sed -n '1,10p' "${work}/daemon2.log" 2>/dev/null | sed 's/^/    /'
  fi
  kill -TERM "${other_pid}" 2>/dev/null
  sleep 1
  kill -KILL "${other_pid}" 2>/dev/null
  other_pid=""
else
  skip "bukan root: koneksi dari uid lain tidak bisa diuji di sini (socket 0600 sudah menutup jalur biasa; yang diuji di CI adalah kasus peer bukan pemilik yang tetap bisa menyentuh socket)"
fi

if [ "${fails}" -gt 0 ]; then
  printf '\n%d assertion(s) FAILED (%d skipped)\n' "${fails}" "${skips}"
  exit 1
fi
printf '\ndaemon hardening: all assertions passed (%d skipped)\n' "${skips}"