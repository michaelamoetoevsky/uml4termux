#!/usr/bin/env bash
#
# Host driver for the performance benchmark (docs/NEXT-STEPS.md, direction A).
#
# Boots a real guest per run through the launcher (no runit), collects the
# RESULT lines the guest prints, and reports median + range per (kernel, profile).
# Read-only on the image; each run gets a private copy and a private ssh port.
#
# usage: bench/bench.sh --kernels "pin=linux-bionic,head=linux-head" \
#                       [--runs 3] [--image PATH] [--out DIR] [--keep]
#
#   --kernels  comma-separated label=filename pairs; the file is resolved in
#              $UML4TERMUX_HOME (so put the second kernel there under its own
#              name and let UML4TERMUX_KERNEL_FILE pick it per run)
#   --runs     repetitions per kernel (default 3; the plan asks for >=3)
#   --image    backing image (default: $UML4TERMUX_HOME/<disk file>)
#   --out      output directory for raw logs + summary (default ./bench/out/<ts>)
#
# SPDX-License-Identifier: GPL-2.0-only
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNELS=""
RUNS=3
IMAGE=""
OUT=""
KEEP=0
SSH_BASE="${BENCH_SSH_PORT:-12400}"

while [ $# -gt 0 ]; do
  case "$1" in
    --kernels) KERNELS="${2:?}"; shift ;;
    --runs)    RUNS="${2:?}"; shift ;;
    --image)   IMAGE="${2:?}"; shift ;;
    --out)     OUT="${2:?}"; shift ;;
    --keep)    KEEP=1 ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "bench: unknown option '$1'" >&2; exit 64 ;;
  esac
  shift
done

[ -n "${KERNELS}" ] || { echo "bench: --kernels is required (label=file,...)" >&2; exit 64; }
[ -x "${ROOT}/bin/uml4termux" ] || { echo "bench: no bin/uml4termux" >&2; exit 1; }

TS="$(date +%Y%m%d-%H%M%S)"
OUT="${OUT:-${ROOT}/bench/out/${TS}}"
mkdir -p "${OUT}/runs"

export NO_COLOR=1
W="${OUT}/work"
mkdir -p "${W}"/{home,state,initramfs,guest} "${W}/rt"

# ---- guest payload -> initramfs (built once) ------------------------------
# The builder validates that the payload carries the repo's init + forensic.sh
# scaffolding (the init is what mounts the root and hands over to --entry).
cp "${ROOT}/scripts/guest/init" "${ROOT}/scripts/guest/forensic.sh" "${W}/guest/" 2>/dev/null || true
cp "${ROOT}/bench/guest/bench.sh" "${W}/guest/bench.sh"
chmod 0755 "${W}/guest"/*
# The base initramfs supplies /bin/sh; it is a released asset, not optional.
BASE="${UML4TERMUX_HOME:-$HOME/.uml4termux}/initramfs-alpine.cpio.gz"
[ -s "${BASE}" ] || { echo "bench: base initramfs missing at ${BASE}" >&2; exit 1; }
env -u LD_LIBRARY_PATH python3 "${ROOT}/scripts/build-initramfs.py" \
  --guest-dir "${W}/guest" --base "${BASE}" \
  --entry /bench.sh --extra-file bench.sh \
  --define BENCH_SCALE="${BENCH_SCALE:-1}" \
  --out "${W}/initramfs/docker.cpio.gz" --force >"${OUT}/build.log" 2>&1 \
  || { echo "bench: initramfs build failed, see ${OUT}/build.log" >&2; exit 1; }

export UML4TERMUX_STATE_DIR="${W}/state"
export UML4TERMUX_INITRAMFS_DIR="${W}/initramfs"
export UML4TERMUX_RUNTIME="${W}/rt"

# private image copy per benchmark campaign (never the shared one: a guest holds
# an exclusive F_SETLK on its backing image)
if [ -z "${IMAGE}" ]; then
  disk="${UML4TERMUX_DISK_FILE:-debian-docker.ext4}"
  IMAGE="${UML4TERMUX_HOME:-$HOME/.uml4termux}/${disk}"
fi
[ -s "${IMAGE}" ] || { echo "bench: image missing at ${IMAGE}" >&2; exit 1; }
cp -f "${IMAGE}" "${W}/img.ext4" 2>/dev/null || ln -f "${IMAGE}" "${W}/img.ext4"

echo "bench: out=${OUT} runs=${RUNS} kernels=${KERNELS}"
port="${SSH_BASE}"
rc_all=0

IFS=',' read -r -a pairs <<< "${KERNELS}"
for pair in "${pairs[@]}"; do
  label="${pair%%=*}"
  kfile="${pair#*=}"
  [ -s "${UML4TERMUX_HOME:-$HOME/.uml4termux}/${kfile}" ] \
    || { echo "bench: kernel '${label}' missing: ${UML4TERMUX_HOME:-$HOME/.uml4termux}/${kfile}" >&2; rc_all=1; continue; }
  for run in $(seq 1 "${RUNS}"); do
    port=$((port + 1))
    name="bench-${label}-${run}"
    log="${OUT}/runs/${label}-${run}.log"
    rt="${W}/rt-${label}-${run}"
    echo "  -> ${label} run ${run}/${RUNS} (ssh ${port})"
    UML4TERMUX_KERNEL_FILE="${kfile}" UML4TERMUX_RUNTIME="${rt}" \
      "${ROOT}/bin/uml4termux" up --name "${name}" --image "${W}/img.ext4" \
      --ssh-port "${port}" --no-gvproxy --timeout 180 >"${log}" 2>&1
    up_rc=$?
    # the guest prints on the console; the launcher has already rotated logs
    console="${rt}/uml-console.log"
    # up returns once the instance is READY; the benchmark then runs inside the
    # guest for a while, so wait for the guest's own BENCH_DONE marker.
    waited=0
    while [ "${waited}" -lt "${BENCH_WAIT:-420}" ]; do
      if grep -qs 'BENCH_DONE' "${console}" 2>/dev/null; then break; fi
      sleep 5; waited=$((waited + 5))
    done
    [ -f "${console}" ] && cat "${console}" >> "${log}"
    if ! grep -q 'BENCH_DONE' "${log}" 2>/dev/null; then
      echo "     ! no BENCH_DONE (up rc=${up_rc}) -- see ${log}" >&2
      rc_all=1
    fi
    UML4TERMUX_RUNTIME="${rt}" "${ROOT}/bin/uml4termux" down --name "${name}" >>"${log}" 2>&1
  done
done

# ---- summarise: median + range per (kernel, profile) ---------------------
env -u LD_LIBRARY_PATH python3 - "${OUT}" "${KERNELS}" <<'PY'
import glob, json, os, re, statistics, sys

out, kernels = sys.argv[1], sys.argv[2]
data = {}      # label -> profile -> [ms]
meta = {}
for path in sorted(glob.glob(os.path.join(out, "runs", "*.log"))):
    label, run = os.path.basename(path)[:-4].rsplit("-", 1)
    txt = open(path, errors="replace").read()
    m = re.search(r"Linux ([\w.\-+]+)", txt)
    if m:
        meta.setdefault(label, set()).add(m.group(1))
    for prof, ms in re.findall(r"RESULT profile=(\w+) .*?ms=(\d+)", txt):
        data.setdefault(label, {}).setdefault(prof, []).append(int(ms))

summary = {"kernels": sorted(data), "profiles": sorted({p for v in data.values() for p in v}), "cells": {}}
lines = ["| kernel | profile | runs | median ms | min | max | spread |", "|---|---|---|---|---|---|---|"]
for label in sorted(data):
    for prof in summary["profiles"]:
        vals = data[label].get(prof, [])
        if not vals:
            continue
        med = statistics.median(vals)
        summary["cells"][f"{label}/{prof}"] = {
            "runs": len(vals), "median_ms": med, "min_ms": min(vals), "max_ms": max(vals), "values": vals,
        }
        spread = (max(vals) - min(vals)) / med * 100 if med else 0
        lines.append(f"| {label} | {prof} | {len(vals)} | {med:.0f} | {min(vals)} | {max(vals)} | {spread:.1f}% |")

summary["kernel_releases"] = {k: sorted(v) for k, v in meta.items()}
json.dump(summary, open(os.path.join(out, "summary.json"), "w"), indent=1)
open(os.path.join(out, "summary.md"), "w").write("\n".join(lines) + "\n")
print("\n".join(lines))

# verdict per profile, only when every kernel has >=3 runs (the plan's bar)
labels = sorted(data)
for prof in summary["profiles"]:
    got = {l: len(data[l].get(prof, [])) for l in labels}
    if len(labels) >= 2 and all(n >= 3 for n in got.values()):
        a, b = labels[0], labels[-1]
        ma = statistics.median(data[a][prof]); mb = statistics.median(data[b][prof])
        delta = (mb - ma) / ma * 100
        verdict = "setara" if abs(delta) < 5 else (f"{b} lebih cepat {abs(delta):.1f}%" if delta < 0 else f"{b} lebih lambat {delta:.1f}%")
        print(f"VERDICT {prof}: {a} {ma:.0f} ms vs {b} {mb:.0f} ms -> {verdict}")
PY

echo "bench: summary -> ${OUT}/summary.md"
[ "${KEEP}" = "1" ] || rm -f "${W}/img.ext4"
exit "${rc_all}"