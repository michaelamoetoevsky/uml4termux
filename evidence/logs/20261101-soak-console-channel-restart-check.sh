#!/usr/bin/env bash
#
# B3 — restart in the middle of a session (docs/NEXT-STEPS.md, direction B).
#
# An instance runs with a real web container in the guest and an exposure
# registered on the host. The daemon is then killed hard and restarted through
# the plain supervisor adapter; the check is that (a) the instance returns,
# (b) the recorded exposure is RE-APPLIED end to end -- a host curl reaches the
# container's banner again, not merely a port that looks open, and (c) nothing
# from the previous daemon is left orphaned.
#
# Two device facts shape this script:
#   * /proc/net/tcp is NOT readable on Termux/Android, so "is the port
#     listening?" must be answered by an actual request, never by parsing /proc;
#   * a guest that powers off after its work makes the daemon exit (exit 0 =
#     session complete), so this uses the repo's docker-init.sh, whose
#     GUEST_LIFETIME=0 keeps the session alive for the restart test.
#
# usage: soak/restart-check.sh [--out DIR] [--ssh-port N] [--host-port N]
# SPDX-License-Identifier: GPL-2.0-only
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${ROOT}/bin/uml4termux"
OUT=""
SSH_PORT="${B3_SSH_PORT:-12600}"
HOST_PORT="${B3_HOST_PORT:-18130}"
GUEST_PORT="${B3_GUEST_PORT:-8123}"
MEM="${B3_MEM:-2048M}"
rc_total=0

while [ $# -gt 0 ]; do
  case "$1" in
    --out)       OUT="${2:?}"; shift ;;
    --ssh-port)  SSH_PORT="${2:?}"; shift ;;
    --host-port) HOST_PORT="${2:?}"; shift ;;
    -h|--help)   sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "b3: unknown option '$1'" >&2; exit 64 ;;
  esac
  shift
done

# /proc/net/tcp is denied on Android, so "is this port free?" is answered by
# trying a connection. A stray forwarder from an earlier interrupted run made an
# expose return gvproxy 500 once; that must be caught here, not attributed to
# the kernel.
port_busy() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }
for _t in 1 2 3 4 5; do port_busy "${HOST_PORT}" || break; HOST_PORT=$((HOST_PORT + 1)); done
for _t in 1 2 3 4 5; do port_busy "${SSH_PORT}" || break; SSH_PORT=$((SSH_PORT + 1)); done
if port_busy "${HOST_PORT}" || port_busy "${SSH_PORT}"; then
  echo "b3: no free host/ssh port near ${HOST_PORT}/${SSH_PORT}" >&2; exit 1
fi
echo "b3: ports host=${HOST_PORT} ssh=${SSH_PORT}"

export NO_COLOR=1
OUT="${OUT:-${TMPDIR:-/tmp}/b3-$(date +%Y%m%d-%H%M%S)}"
W="${OUT}/work"
mkdir -p "${W}/guest" "${W}/initramfs" "${W}/state"
export UML4TERMUX_STATE_DIR="${W}/state"
export UML4TERMUX_INITRAMFS_DIR="${W}/initramfs"
ASSETS="${UML4TERMUX_HOME:-$HOME/.uml4termux}"
IMG_SRC="${ASSETS}/${UML4TERMUX_DISK_FILE:-debian-docker.ext4}"
BASE="${ASSETS}/initramfs-alpine.cpio.gz"
RT="${W}/rt-b3"
NAME="b3"
fail() { printf '  FAIL: %s\n' "$1"; rc_total=1; }
ok()   { printf '  PASS: %s\n' "$1"; }
exe_of() { readlink "/proc/$1/exe" 2>/dev/null; }

for f in "${BASE}" "${IMG_SRC}" "${ASSETS}/gvproxy"; do
  [ -e "${f}" ] || { echo "b3: missing ${f}" >&2; exit 1; }
done

# the guest must stay alive: GUEST_LIFETIME=0 (heartbeat) --
cp "${ROOT}/scripts/guest/init" "${ROOT}/scripts/guest/forensic.sh" "${ROOT}/scripts/guest/docker-init.sh" "${W}/guest/"
chmod 0755 "${W}"/guest/* 2>/dev/null || true
env -u LD_LIBRARY_PATH python3 "${ROOT}/scripts/build-initramfs.py" \
  --guest-dir "${W}/guest" --base "${BASE}" --entry /docker-init.sh \
  --define GUEST_IP=192.168.127.2 --define GUEST_GW=192.168.127.1 \
  --define GUEST_DNS=192.168.127.1 --define WEB_PORTS="${GUEST_PORT}" \
  --define GUEST_LIFETIME=0 \
  --out "${W}/initramfs/docker.cpio.gz" --force >"${OUT}/build.log" 2>&1 \
  || { echo "b3: initramfs build failed (${OUT}/build.log)" >&2; exit 1; }
cp -f "${IMG_SRC}" "${W}/img.ext4"

CONSOLE="${RT}/uml-console.log"
# A request is the ONLY honest liveness probe here (/proc/net/tcp is denied).
http_ok() {
  curl -fsS --max-time 8 "http://127.0.0.1:${HOST_PORT}/" 2>/dev/null | grep -q 'gvproxy-bess-ok'
}
wait_http() { # <seconds>
  local i=0
  while [ "${i}" -lt "$1" ]; do http_ok && return 0; sleep 3; i=$((i + 3)); done
  return 1
}
orphan_count() {
  local n=0 p exe
  for p in /proc/[0-9]*; do
    exe="$(exe_of "${p#/proc/}")" || continue
    case "${exe}" in *linux-bionic*|*uml4termuxd*|*gvproxy*) n=$((n + 1)) ;;
    esac
  done
  printf '%s' "${n}"
}

echo "== langkah 1: up dengan gvproxy =="
UML4TERMUX_RUNTIME="${RT}" "${BIN}" up --name "${NAME}" --image "${W}/img.ext4" \
  --mem "${MEM}" --ssh-port "${SSH_PORT}" --timeout 300 >"${OUT}/up.log" 2>&1 \
  && ok "instance siap (up rc=0)" || fail "up gagal (lihat ${OUT}/up.log)"
PID1="$(sed -n 's/^PID=//p' "${W}/state/instances/${NAME}.env" 2>/dev/null)"
printf '  pid daemon = %s\n' "${PID1}"

echo "== langkah 2: tunggu container web di guest =="
waited=0
while [ "${waited}" -lt 240 ]; do grep -qs 'WEB_UP_MARKER' "${CONSOLE}" 2>/dev/null && break; sleep 5; waited=$((waited + 5)); done
grep -qs 'WEB_UP_MARKER' "${CONSOLE}" 2>/dev/null && ok "container web hidup (WEB_UP_MARKER)" || fail "WEB_UP_MARKER tidak muncul"
echo "== langkah 3: expose ${HOST_PORT}:${GUEST_PORT} =="
UML4TERMUX_RUNTIME="${RT}" "${BIN}" expose "${HOST_PORT}:${GUEST_PORT}" >"${OUT}/expose.log" 2>&1
if wait_http 90; then ok "curl host:${HOST_PORT} -> banner container (exposure jalan)"; else fail "curl host:${HOST_PORT} tidak sampai container"; fi

echo "== langkah 4: bunuh daemon (SIGKILL) =="
kill -KILL "${PID1}" 2>/dev/null
sleep 4
[ -n "${PID1}" ] && [ -d "/proc/${PID1}" ] && fail "daemon ${PID1} masih hidup" || ok "daemon ${PID1} mati"
if wait_http 12; then fail "exposure masih menjawab padahal daemon mati (forwarder yatim)"; else ok "exposure ikut mati bersama daemon"; fi

echo "== langkah 5: restart lewat adapter plain =="
UML4TERMUX_RUNTIME="${RT}" UML4TERMUX_INSTANCE_NAME="${NAME}" UML4TERMUX_BIN="${BIN}" \
  UML4TERMUX_SUPERVISE_BACKOFF=1 UML4TERMUX_SUPERVISE_MAX=1 \
  UML4TERMUX_KERNEL_FILE="${UML4TERMUX_KERNEL_FILE:-linux-bionic}" \
  "${ROOT}/packaging/adapters/plain/supervise.sh" --image "${W}/img.ext4" --mem "${MEM}" \
  --ssh-port "${SSH_PORT}" >"${OUT}/supervise.log" 2>&1 &
SUP=$!
PID2=""
for _ in $(seq 1 60); do
  PID2="$(sed -n 's/^PID=//p' "${W}/state/instances/${NAME}.env" 2>/dev/null)"
  [ -n "${PID2}" ] && [ "${PID2}" != "${PID1}" ] && [ -d "/proc/${PID2}" ] && break
  sleep 2
done
if [ -n "${PID2}" ] && [ "${PID2}" != "${PID1}" ] && [ -d "/proc/${PID2}" ]; then
  ok "instance hidup lagi dengan pid baru (${PID1} -> ${PID2})"
else
  fail "instance tidak hidup ulang (pid2='${PID2}')"
fi

echo "== langkah 6: exposure di-re-apply (uji end-to-end) =="
if wait_http 180; then ok "curl host:${HOST_PORT} -> banner container LAGI setelah restart"; else fail "exposure tidak kembali setelah restart"; fi
if grep -aq "127.0.0.1:${HOST_PORT}" "${RT}/exposures.jsonl" 2>/dev/null; then
  ok "registry exposure milik daemon memuat 127.0.0.1:${HOST_PORT}"
else
  fail "expósures.jsonl tidak memuat 127.0.0.1:${HOST_PORT}"
fi

echo "== langkah 7: teardown bersih =="
UML4TERMUX_RUNTIME="${RT}" "${BIN}" down --name "${NAME}" >>"${OUT}/down.log" 2>&1
for _ in $(seq 1 20); do kill -0 "${SUP}" 2>/dev/null || break; sleep 2; done
kill -KILL "${SUP}" 2>/dev/null
sleep 5
left="$(orphan_count)"
[ "${left}" -eq 0 ] && ok "0 proses tersisa setelah down" || fail "${left} proses tersisa setelah down"

env -u LD_LIBRARY_PATH python3 - "${OUT}" "${PID1}" "${PID2}" "${HOST_PORT}" "${rc_total}" <<'PY'
import json, sys
out, pid1, pid2, host_port, rc = sys.argv[1:6]
json.dump({"check": "B3 restart + exposure re-apply (end-to-end curl)",
           "daemon_pid_before": pid1, "daemon_pid_after": pid2,
           "host_port": int(host_port), "passed": rc == "0"},
          open(f"{out}/b3.json", "w"), indent=1)
PY
echo "b3: hasil -> ${OUT}/b3.json"
[ "${rc_total}" -eq 0 ] && echo "B3: OK" || echo "B3: ADA KEGAGALAN"
exit "${rc_total}"
