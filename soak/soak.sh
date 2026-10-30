#!/usr/bin/env bash
#
# Operational soak driver (docs/NEXT-STEPS.md, direction B).
#
# B1: repeated boot -> dockerd -> container run -> clean stop cycles with
#     ephemeral COW, recording daemon and guest-kernel RSS every cycle.
# B2: two instances in parallel for the same wall-clock window (interference:
#     sockets, memory, Android phantom-process killer).
# B3 lives in soak/restart-check.sh (it needs gvproxy + a real host port).
#
# Every cycle appends one JSON line to <out>/cycles.jsonl; <out>/summary.json
# carries the pass/fail facts the plan asks for (boot failures, RSS trend,
# orphans, exposure after restart).
#
# usage: soak/soak.sh [--kernels NAME=FILE] [--cycles N] [--parallel 2]
#                     [--mem 2048M] [--out DIR] [--tick-timeout S]
#
# SPDX-License-Identifier: GPL-2.0-only
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${ROOT}/bin/uml4termux"
DAEMON_BIN="${UML4TERMUXD_BIN:-${ROOT}/bin/uml4termuxd}"
KERNEL_FILE="${SOAK_KERNEL:-linux-bionic}"
CYCLES=5
PARALLEL=1
MEM="${SOAK_MEM:-2048M}"
TICK_TIMEOUT="${SOAK_TICK_TIMEOUT:-420}"
OUT=""
PORT_BASE="${SOAK_SSH_BASE:-12500}"

while [ $# -gt 0 ]; do
  case "$1" in
    --kernels)      KERNEL_FILE="${2#*=}"; shift ;;
    --cycles)       CYCLES="${2:?}"; shift ;;
    --parallel)     PARALLEL="${2:?}"; shift ;;
    --mem)          MEM="${2:?}"; shift ;;
    --out)          OUT="${2:?}"; shift ;;
    --tick-timeout) TICK_TIMEOUT="${2:?}"; shift ;;
    -h|--help)      sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "soak: unknown option '$1'" >&2; exit 64 ;;
  esac
  shift
done

[ -x "${BIN}" ] || { echo "soak: no ${BIN}" >&2; exit 1; }
OUT="${OUT:-${TMPDIR:-/tmp}/soak-$(date +%Y%m%d-%H%M%S)}"
W="${OUT}/work"
IMG_SRC="${UML4TERMUX_HOME:-$HOME/.uml4termux}/${UML4TERMUX_DISK_FILE:-debian-docker.ext4}"
BASE="${UML4TERMUX_HOME:-$HOME/.uml4termux}/initramfs-alpine.cpio.gz"

mkdir -p "${W}/guest" "${W}/initramfs" "${OUT}"
export NO_COLOR=1
# Drive the registry/initramfs locations explicitly: the library defaults to
# $XDG_STATE_HOME/uml4termux, and this driver must look up the same record the
# launcher writes.
export UML4TERMUX_STATE_DIR="${W}/state"
export UML4TERMUX_INITRAMFS_DIR="${W}/initramfs"

# ---- guest payload --------------------------------------------------------
cp "${ROOT}/scripts/guest/init" "${ROOT}/scripts/guest/forensic.sh" "${W}/guest/" 2>/dev/null || true
cp "${ROOT}/soak/guest/tick.sh" "${W}/guest/tick.sh"
chmod 0755 "${W}"/guest/* 2>/dev/null || true
[ -s "${BASE}" ] || { echo "soak: base initramfs missing at ${BASE}" >&2; exit 1; }
env -u LD_LIBRARY_PATH python3 "${ROOT}/scripts/build-initramfs.py" \
  --guest-dir "${W}/guest" --base "${BASE}" --entry /tick.sh --extra-file tick.sh \
  --out "${W}/initramfs/docker.cpio.gz" --force >"${OUT}/build.log" 2>&1 \
  || { echo "soak: initramfs build failed (${OUT}/build.log)" >&2; exit 1; }

[ -s "${IMG_SRC}" ] || { echo "soak: image missing at ${IMG_SRC}" >&2; exit 1; }

img_sha() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }
img_mtime() { stat -c '%Y' "$1" 2>/dev/null; }
exe_of() { readlink "/proc/$1/exe" 2>/dev/null; }

# processes still running the guest kernel or the daemon binary
count_leftovers() {
  local n=0 p exe
  for p in /proc/[0-9]*; do
    exe="$(exe_of "${p#/proc/}")" || continue
    case "${exe}" in
      *linux-bionic*|*uml4termuxd*|*${KERNEL_FILE##*/}*) n=$((n + 1)) ;;
    esac
  done
  printf '%s' "${n}"
}

rss_kb() { awk '/^VmRSS/{print $2}' "/proc/$1/status" 2>/dev/null || echo 0; }

# ---- one instance worker --------------------------------------------------
# $1 label, $2 cycles, $3 port, $4 jsonl path
run_instance() {
  local label="$1" cycles="$2" port="$3" jsonl="$4"
  local rt="${W}/rt-${label}" img="${W}/img-${label}.ext4" name="soak-${label}"
  mkdir -p "${rt}"
  # ALWAYS a real copy: a hardlink would give two instances the same inode, and
  # UML takes an exclusive F_SETLK on the backing image -- the second boot would
  # silently run diskless (the documented NO_DISK trap) and lose every write.
  cp -f "${IMG_SRC}" "${img}"
  local sha_before mtime_before
  sha_before="$(img_sha "${img}")"; mtime_before="$(img_mtime "${img}")"

  local i=1
  while [ "${i}" -le "${cycles}" ]; do
    local t0 t1 rc console daemon_pid kernel_pid drss krss tick_ok
    console="${rt}/uml-console.log"
    : > "${console}" 2>/dev/null || true
    t0="$(date +%s)"
    UML4TERMUX_RUNTIME="${rt}" UML4TERMUX_KERNEL_FILE="${KERNEL_FILE}" \
      "${BIN}" up --name "${name}" --image "${img}" --mem "${MEM}" \
      --ssh-port "${port}" --timeout 240 >"${OUT}/${label}-cycle${i}.up.log" 2>&1
    rc=$?
    t1="$(date +%s)"

    daemon_pid="$(sed -n 's/^PID=//p' "${UML4TERMUX_STATE_DIR}/instances/${name}.env" 2>/dev/null)"
    # child_pid comes from the daemon's own atomic state file: the CLI has no
    # --json flag, so asking for one silently produced 0 KB on every cycle.
    kernel_pid="$(env -u LD_LIBRARY_PATH python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get("child_pid", ""))
except Exception: print("")' "${rt}/daemon.sock.state" 2>/dev/null)"
    drss=0; krss=0
    [ -n "${daemon_pid}" ] && drss="$(rss_kb "${daemon_pid}")"
    [ -n "${kernel_pid}" ] && krss="$(rss_kb "${kernel_pid}")"

    local waited=0
    while [ "${waited}" -lt "${TICK_TIMEOUT}" ]; do
      grep -qs 'SOAK_TICK_DONE' "${console}" 2>/dev/null && break
      sleep 5; waited=$((waited + 5))
    done
    grep -qs 'SOAK_TICK_DONE' "${console}" 2>/dev/null && tick_ok=yes || tick_ok=no

    local dockerline runline
    dockerline="$(grep -a 'SOAK_DOCKERD' "${console}" 2>/dev/null | tail -1 | tr -d '\r')"
    runline="$(grep -a 'SOAK_RUN' "${console}" 2>/dev/null | tail -1 | tr -d '\r')"

    # B3 (restart + exposure re-apply) lives in soak/restart-check.sh: it needs
    # gvproxy and a real host port, which the soak loop deliberately avoids.
    local restart_ok="n/a"

    UML4TERMUX_RUNTIME="${rt}" "${BIN}" down --name "${name}" >>"${OUT}/${label}-cycle${i}.up.log" 2>&1
    sleep 3
    local leftovers
    leftovers="$(count_leftovers)"
    local sha_after mtime_after
    sha_after="$(img_sha "${img}")"; mtime_after="$(img_mtime "${img}")"

    env -u LD_LIBRARY_PATH python3 - "${jsonl}" "${label}" "${i}" "${rc}" \
      "$((t1 - t0))" "${waited}" "${tick_ok}" "${drss}" "${krss}" \
      "${sha_before}" "${sha_after}" "${mtime_before}" "${mtime_after}" \
      "${leftovers}" "${dockerline}" "${runline}" "${restart_ok}" "$(date +%s)" <<'PY'
import json, sys
(a, label, i, rc, dur, waited, tick, drss, krss, s1, s2, m1, m2, left, docker, run, restart, ts) = sys.argv[1:]
rec = {
    "label": label, "cycle": int(i), "up_rc": int(rc), "up_seconds": int(dur),
    "tick_wait_seconds": int(waited), "tick_complete": tick == "yes",
    "daemon_rss_kb": int(drss or 0), "kernel_rss_kb": int(krss or 0),
    "image_sha_before": s1[:16], "image_sha_after": s2[:16],
    "image_unchanged": s1 == s2 and m1 == m2,
    "leftover_processes": int(left or 0),
    "dockerd": docker.split("SOAK_DOCKERD", 1)[1].strip() if "SOAK_DOCKERD" in docker else "missing",
    "run": run.split("SOAK_RUN", 1)[1].strip() if "SOAK_RUN" in run else "missing",
    "restart_check": restart,
    "t_epoch": int(ts),
}
with open(a, "a") as fh:
    fh.write(json.dumps(rec) + "\n")
PY
    printf '  [%s] cycle %s/%s rc=%s tick=%s rss(daemon=%sKB kernel=%sKB) left=%s img_same=%s\n' \
      "${label}" "${i}" "${cycles}" "${rc}" "${tick_ok}" "${drss}" "${krss}" "${leftovers}" \
      "$([ "${sha_before}" = "${sha_after}" ] && echo yes || echo NO)"
    i=$((i + 1))
  done
}

echo "soak: out=${OUT} cycles=${CYCLES} parallel=${PARALLEL} kernel=${KERNEL_FILE}"

pids=()
for k in $(seq 1 "${PARALLEL}"); do
  port=$((PORT_BASE + k))
  run_instance "s${k}" "${CYCLES}" "${port}" "${OUT}/cycles.jsonl" &
  pids+=($!)
done
for p in "${pids[@]}"; do wait "${p}"; done

env -u LD_LIBRARY_PATH python3 "${ROOT}/soak/summarise.py" "${OUT}" --start "$(date +%s)" || true
echo "soak: summary -> ${OUT}/summary.json"