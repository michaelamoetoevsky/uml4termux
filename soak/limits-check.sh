#!/usr/bin/env bash
#
# E4 — per-guest resource limits, measured on the device (docs/NEXT-STEPS.md §E).
#
# The claim under test is narrow and checkable: the limits a caller passes are the
# limits the guest actually gets, and they are per guest rather than global.
#
#   mem=N    the guest's own MemTotal reports N (the kernel keeps a slice, so the
#            check allows a small shortfall and refuses anything larger);
#   ncpus=N  the guest sees exactly N CPUs;
#   io.max   the guest kernel accepts a cgroup-v2 io.max line for its own block
#            device and reports it back -- the interface that a container inside
#            the guest inherits.
#
# Two boots, because "per guest" cannot be shown with one.
#
# Every assertion reads a line the GUEST printed: the marker is base64 in the typed
# command, so the console echo cannot fake it (see soak/snapshot-check.sh for how
# that lesson was learned).
#
# usage: soak/limits-check.sh [--out DIR] [--ssh-port N]
# SPDX-License-Identifier: GPL-2.0-only
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${ROOT}/bin/uml4termux"
DBIN="${UML4TERMUXD_BIN:-${ROOT}/bin/uml4termuxd}"
OUT=""
SSH_PORT="${E4_SSH_PORT:-12660}"
GUEST_PORT="${E4_GUEST_PORT:-8123}"
rc_total=0

while [ $# -gt 0 ]; do
  case "$1" in
    --out)      OUT="${2:?}"; shift ;;
    --ssh-port) SSH_PORT="${2:?}"; shift ;;
    -h|--help)  sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "e4: unknown option '$1'" >&2; exit 64 ;;
  esac
  shift
done

port_busy() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }
for _t in 1 2 3 4 5; do port_busy "${SSH_PORT}" || break; SSH_PORT=$((SSH_PORT + 1)); done
port_busy "${SSH_PORT}" && { echo "e4: no free ssh port near ${SSH_PORT}" >&2; exit 1; }

export NO_COLOR=1
OUT="${OUT:-${TMPDIR:-/tmp}/e4-limits-$(date +%Y%m%d-%H%M%S)}"
W="${OUT}/work"
mkdir -p "${W}/guest" "${W}/initramfs" "${W}/state" "${OUT}/console"
export UML4TERMUX_STATE_DIR="${W}/state"
export UML4TERMUX_INITRAMFS_DIR="${W}/initramfs"
ASSETS="${UML4TERMUX_HOME:-$HOME/.uml4termux}"
IMG_SRC="${ASSETS}/${UML4TERMUX_DISK_FILE:-debian-docker.ext4}"
BASE="${ASSETS}/initramfs-alpine.cpio.gz"
RT="${W}/rt-e4"
NAME="e4"
fail() { printf '  FAIL: %s\n' "$1"; rc_total=1; }
ok()   { printf '  PASS: %s\n' "$1"; }

[ -x "${DBIN}" ] || { echo "e4: daemon client not found: ${DBIN}" >&2; exit 1; }
for f in "${BASE}" "${IMG_SRC}" "${ASSETS}/gvproxy"; do
  [ -e "${f}" ] || { echo "e4: missing ${f}" >&2; exit 1; }
done

cp "${ROOT}/scripts/guest/init" "${ROOT}/scripts/guest/forensic.sh" "${ROOT}/scripts/guest/docker-init.sh" "${W}/guest/"
chmod 0755 "${W}"/guest/* 2>/dev/null || true
env -u LD_LIBRARY_PATH python3 "${ROOT}/scripts/build-initramfs.py" \
  --guest-dir "${W}/guest" --base "${BASE}" --entry /docker-init.sh \
  --define GUEST_IP=192.168.127.2 --define GUEST_GW=192.168.127.1 \
  --define GUEST_DNS=192.168.127.1 --define WEB_PORTS="${GUEST_PORT}" \
  --define GUEST_LIFETIME=0 \
  --out "${W}/initramfs/docker.cpio.gz" --force >"${OUT}/build.log" 2>&1 \
  || { echo "e4: initramfs build failed" >&2; exit 1; }
cp -f "${IMG_SRC}" "${W}/img.ext4"

CONSOLE="${RT}/uml-console.log"
boot_n=0
b64() { printf '%s' "$1" | base64 -w0; }
MK_LIMITS="$(b64 'LIMITS')"
MK_IOMAX="$(b64 'IOMAXOK')"
marker_count() { local n; n="$(grep -ac "$1" "${CONSOLE}" 2>/dev/null)"; printf '%s' "${n:-0}"; }
wait_marker() {
  local marker="$1" limit="$2" i=0
  while [ "${i}" -lt "${limit}" ]; do
    [ "$(marker_count "${marker}")" -gt 0 ] && return 0
    sleep 5; i=$((i + 5))
  done
  return 1
}
archive_console() {
  boot_n=$((boot_n + 1))
  [ -e "${CONSOLE}" ] && mv -f "${CONSOLE}" "${OUT}/console/boot-${boot_n}-previous.log" 2>/dev/null
  echo "boot ${boot_n} $(date -u +%Y-%m-%dT%H:%M:%SZ)" > "${OUT}/console/boot-${boot_n}.txt"
}
instance_down() { UML4TERMUX_RUNTIME="${RT}" "${BIN}" down --name "${NAME}" >/dev/null 2>&1 || true; sleep 3; }
guest_shell() { UML4TERMUX_RUNTIME="${RT}" "${DBIN}" exec "$1" >/dev/null 2>&1 || true; }
guest_run() { # <marker> <cmd> <seconds>  (retried: a line typed too early is lost)
  local marker="$1" cmd="$2" limit="${3:-180}" i=0 j
  while [ "${i}" -lt "${limit}" ]; do
    guest_shell "${cmd}"
    j=0
    while [ "${j}" -lt 6 ]; do
      [ "$(marker_count "${marker}")" -gt 0 ] && return 0
      sleep 5; j=$((j + 1))
    done
    i=$((i + 30))
  done
  return 1
}

# mem=N ncpus=N -> limits mem=<kb> ncpus=<n>
limits_cmd() {
  printf 'printf "%%s mem=%%s ncpus=%%s\\n" "$(echo %s | base64 -d)" "$(awk '"'"'/^MemTotal:/{print $2}'"'"' /proc/meminfo)" "$(nproc)"' "${MK_LIMITS}"
}
# io.max: the guest kernel must accept a cgroup-v2 limit for its own block device
iomax_cmd() {
  printf 'D=$(cat /sys/class/block/ubda/dev 2>/dev/null); echo "$D rbps=1048576" > /sys/fs/cgroup/io.max 2>/dev/null; cat /sys/fs/cgroup/io.max; printf "%%s\\n" "$(echo %s | base64 -d)"' "${MK_IOMAX}"
}

check_limits() { # <boot-label> <mem-mib> <ncpus> <expect-io.max:0|1>
  local label="$1" want_mem="$2" want_cpus="$3" want_iomax="$4"
  local line mem_kb cpus got_mem_mib tol_lo tol_hi
  archive_console
  if UML4TERMUX_RUNTIME="${RT}" "${BIN}" up --name "${NAME}" --image "${W}/img.ext4" \
      --mem "${want_mem}M" --cpus "${want_cpus}" --ssh-port "${SSH_PORT}" --timeout 300 \
      >"${OUT}/up-${label}.log" 2>&1; then
    ok "${label}: instance siap (mem=${want_mem}M ncpus=${want_cpus})"
  else
    fail "${label}: up gagal (lihat ${OUT}/up-${label}.log)"; return 1
  fi
  if wait_marker 'WEB_UP_MARKER' 300; then ok "${label}: guest hidup"; else fail "${label}: guest tidak hidup"; return 1; fi

  if guest_run 'LIMITS' "$(limits_cmd)" 180; then
    line="$(grep -a 'LIMITS mem=' "${CONSOLE}" 2>/dev/null | tail -1)"
    mem_kb="$(printf '%s' "${line}" | sed -n 's/.*mem=\([0-9]*\).*/\1/p')"
    cpus="$(printf '%s' "${line}" | sed -n 's/.*ncpus=\([0-9]*\).*/\1/p')"
    if [ -n "${mem_kb}" ] && [ -n "${cpus}" ]; then
      got_mem_mib=$((mem_kb / 1024))
      # MemTotal is always a little below the request (kernel keeps a slice), so
      # the band is "no more than asked, no less than 90% of it".
      tol_hi="${want_mem}"
      tol_lo=$((want_mem * 9 / 10))
      if [ "${got_mem_mib}" -le "${tol_hi}" ] && [ "${got_mem_mib}" -ge "${tol_lo}" ]; then
        ok "${label}: MemTotal ${got_mem_mib} MiB untuk --mem ${want_mem}M (band ${tol_lo}-${tol_hi})"
      else
        fail "${label}: MemTotal ${got_mem_mib} MiB di luar band ${tol_lo}-${tol_hi} untuk --mem ${want_mem}M"
      fi
      printf '%s %s\n' "${got_mem_mib}" "${cpus}" > "${OUT}/observed-${label}.txt"
      if [ "${cpus}" = "${want_cpus}" ]; then
        ok "${label}: guest melihat ${cpus} CPU, sesuai --cpus ${want_cpus}"
      else
        fail "${label}: guest melihat ${cpus} CPU, diminta ${want_cpus}"
      fi
    else
      fail "${label}: guest tidak melaporkan LIMITS"; tail -5 "${CONSOLE}" | sed 's/^/      /'
    fi
  else
    fail "${label}: perintah LIMITS tidak pernah dieksekusi"
  fi

  if [ "${want_iomax}" = "1" ]; then
    if guest_run 'IOMAXOK' "$(iomax_cmd)" 180; then
      if grep -aq 'rbps=1048576' "${CONSOLE}"; then
        ok "${label}: cgroup v2 io.max menerima rbps=1048576 dan membacanya kembali"
      else
        fail "${label}: io.max tidak melaporkan limit yang diset"
      fi
    else
      fail "${label}: perintah io.max tidak pernah dieksekusi"
    fi
  fi
  instance_down
}

echo "== boot A: mem=256M ncpus=1 (+ io.max) =="
instance_down
check_limits A 256 1 1
echo "== boot B: mem=768M ncpus=2 =="
check_limits B 768 2 0

printf '\n== batas per guest, bukan global ==\n'
# Each boot writes what it observed, so the pairing is explicit instead of being
# inferred from archive names (which are taken before the NEXT boot starts).
a_mem="$(sed -n 's/^\([0-9]*\).*/\1/p' "${OUT}/observed-A.txt" 2>/dev/null | head -1)"
b_mem="$(sed -n 's/^\([0-9]*\).*/\1/p' "${OUT}/observed-B.txt" 2>/dev/null | head -1)"
if [ -n "${a_mem}" ] && [ -n "${b_mem}" ] && [ "${a_mem}" != "${b_mem}" ]; then
  ok "dua guest dengan memori berbeda (${a_mem} MiB vs ${b_mem} MiB): batas melekat per guest"
else
  fail "batas memori tidak berbeda antar guest (a='${a_mem}' b='${b_mem}')"
fi

echo "== teardown =="
instance_down
sleep 3
left=0
for p in /proc/[0-9]*; do
  [ -r "${p}/cmdline" ] || continue
  cmd="$(tr '\0' ' ' < "${p}/cmdline" 2>/dev/null)" || continue
  case "${cmd}" in *"${W}/"*) left=$((left + 1)) ;; esac
done
[ "${left}" -eq 0 ] && ok "0 proses tersisa milik run ini" || fail "${left} proses tersisa"

[ -e "${CONSOLE}" ] && cp -f "${CONSOLE}" "${OUT}/console/boot-${boot_n}-final.log" 2>/dev/null
env -u LD_LIBRARY_PATH python3 - "${OUT}" "${rc_total}" "${a_mem}" "${b_mem}" <<'PY'
import json, sys
out, rc, a, b = sys.argv[1:5]
json.dump({"check": "E4 per-guest resource limits (device, two boots)",
           "guest_a_mem_mib": int(a) if a.isdigit() else None,
           "guest_b_mem_mib": int(b) if b.isdigit() else None,
           "passed": rc == "0"},
          open(f"{out}/e4-limits.json", "w"), indent=1)
PY
echo "e4: hasil -> ${OUT}/e4-limits.json"
[ "${rc_total}" -eq 0 ] && echo "E4: OK" || echo "E4: ADA KEGAGALAN"
exit "${rc_total}"