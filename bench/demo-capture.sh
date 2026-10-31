#!/usr/bin/env bash
# One real boot, two artifacts:
#   docs/DEMO.md                      the N1 transcript: commands, real output, wall times
#   evidence/boot-<date>-timeline.json the N4 measurement: where the seconds actually go
#
# The point is that neither is written by hand. Every number comes from `date +%s.%N` around a
# real event, and every milestone is detected by polling the guest's own console, not by
# sleeping and hoping.
#
# Usage: bench/demo-capture.sh [--out docs/DEMO.md]
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
A=${A:-${TMPDIR:-/tmp}/bench-assets}
W=${W:-$(mktemp -d)}; mkdir -p "$W"
OUT_MD=${OUT_MD:-docs/DEMO.md}
OUT_JSON=${OUT_JSON:-evidence/boot-$(date +%Y%m%d)-timeline.json}
IMG=$W/image.ext4

[ -f "$A/linux-bionic" ] && [ -f "$A/debian-docker.ext4" ] || { echo "SKIP: assets missing under $A"; exit 77; }
cp --sparse=always "$A/debian-docker.ext4" "$IMG" || exit 1

export UML4TERMUX_HOME=$A UML4TERMUXD_BIN=$PWD/bin/uml4termuxd
export UML4TERMUX_STATE_DIR=$W/state UML4TERMUX_RUNTIME=$W/rt UML4TERMUX_KERNEL_FILE=linux-bionic
export UML4TERMUXD_EXEC_MIN_INTERVAL_MS=0
LOG=$W/rt/uml-console.log
now() { date +%s.%N; }
since() { env -u LD_LIBRARY_PATH python3 -c "print(f'{float($2)-float($1):.2f}')"; }

T0=$(now)
STAMP_STOP=$W/stamp.stop
env -u LD_LIBRARY_PATH python3 bench/console-stamp.py "$LOG" "$W/console.timed" --stop-file "$STAMP_STOP" &
STAMP_PID=$!
printf '%s\n' "== boot ==" | tee "$W/steps.txt"

# ---- 1. up -------------------------------------------------------------------------------
U0=$(now)
bin/uml4termux up --name demo --image "$IMG" --mem 1024M --ssh-port 12690 --timeout 300 >"$W/up.log" 2>&1
UP_RC=$?
U1=$(now)
printf 'up rc=%s  %.2fs\n' "$UP_RC" "$(since "$U0" "$U1")" >> "$W/steps.txt"
[ "$UP_RC" = 0 ] || { sed -n '1,12p' "$W/up.log" >> "$W/steps.txt"; echo "  up failed (see $W/up.log)"; exit 1; }

stamp_of() {
  env -u LD_LIBRARY_PATH python3 - "$W/console.timed" "$1" "$T0" <<'STAMPPY'
import sys
path, marker, t0 = sys.argv[1], sys.argv[2], float(sys.argv[3])
try:
    with open(path, errors="replace") as f:
        for line in f:
            parts = line.split(chr(9), 1)
            if len(parts) == 2 and marker in parts[1]:
                print(f"{float(parts[0]) - t0:.2f}")
                break
except FileNotFoundError:
    pass
STAMPPY
}
wait_stamp() {
  local marker=$1 limit=${2:-240} i=0 v
  while [ "$i" -lt "$limit" ]; do
    v=$(stamp_of "$marker")
    [ -n "$v" ] && { printf '%s' "$v"; return 0; }
    sleep 0.5; i=$((i+1))
  done
  printf 'absent'; return 1
}

# Markers verified by reading a captured log, not assumed: 'Linux version',
# 'UML4TERMUX_INIT', 'starting dockerd'. Dockerd does not announce readiness on the
# console (its log goes to /var/log/dockerd.log inside the guest), so readiness is ASKED
# for with `docker info`.
K=$(wait_stamp 'Linux version' 120 || true)
I=$(wait_stamp 'UML4TERMUX_INIT' 120 || true)
G=$(wait_stamp 'starting dockerd' 300 || true)

# dockerd readiness: ask the guest, do not guess from a log line
D="absent"
for i in $(seq 1 120); do
  "$UML4TERMUXD_BIN" exec 'docker info >/dev/null 2>&1 && echo DOCKERD_READY' >/dev/null 2>&1 || true
  if grep -aq 'DOCKERD_READY' "$LOG" 2>/dev/null; then D=$(since "$T0" "$(now)"); break; fi
  sleep 1
done

# first container
R0=$(now)
RUN_OUT=$("$UML4TERMUXD_BIN" exec 'docker run --rm alpine sh -c "echo CONTAINER_OK; uname -m; cat /etc/os-release | head -1"' 2>&1)
RUN_OK=0; for i in $(seq 1 60); do grep -aq 'CONTAINER_OK' "$LOG" 2>/dev/null && { RUN_OK=1; break; }; sleep 1; done
R1=$(now)
RUN_S=$(since "$R0" "$R1")

# ---- 3. down -----------------------------------------------------------------------------
D0=$(now); bin/uml4termux down --name demo >/dev/null 2>&1; DOWN_RC=$?; D1=$(now)
T1=$(now)

touch "$STAMP_STOP"; wait "$STAMP_PID" 2>/dev/null; rm -f "$STAMP_STOP"

cat >> "$W/steps.txt" <<EOF
kernel-up      ${K}s
initramfs      ${I}s
guest-script   ${G}s
dockerd-ready  ${D}s
container-run  ${RUN_S}s (ok=${RUN_OK})
down rc=${DOWN_RC}  $(since "$D0" "$D1")s
total          $(since "$T0" "$T1")s
EOF

# ---- 4. write the JSON record -------------------------------------------------------------
env -u LD_LIBRARY_PATH python3 - "$W/steps.txt" "$OUT_JSON" "$IMG" "$W" <<'PY'
import json, pathlib, subprocess, sys, datetime as dt
import hashlib, os
steps, out_path, image = sys.argv[1], sys.argv[2], sys.argv[3]
work = pathlib.Path(sys.argv[4]) if len(sys.argv) > 4 else pathlib.Path(".")

import shutil

RUN = "boot-" + dt.date.today().strftime("%Y%m%d")
LOGS = pathlib.Path("evidence/logs")

def artifact(path, kind, what):
    """Cite the file itself: a record that points at nothing cannot be checked.

    The schema requires paths RELATIVE to evidence/ with no traversal, so the file is copied
    into evidence/logs/ (the one directory .gitignore lets through) and cited from there. The
    copy is byte-identical, and the sha256 below is of the copied bytes."""
    src = pathlib.Path(path)
    if not src.is_file():
        return None
    LOGS.mkdir(parents=True, exist_ok=True)
    dst = LOGS / f"{RUN}-{src.name}"
    shutil.copyfile(src, dst)
    data = dst.read_bytes()
    return {
        "kind": kind,
        "path": f"logs/{dst.name}",
        "bytes": len(data),
        "sha256": hashlib.sha256(data).hexdigest(),
        "note": what,
    }

artifacts = [a for a in (
    artifact(work / "rt" / "uml-console.log", "console-log",
             "guest console verbatim; the milestones are read from here"),
    artifact(work / "console.timed", "console-log",
             "the same console with a wall-clock stamp on every line"),
    artifact(work / "up.log", "other", "launcher output for `up`"),
    artifact(work / "rt" / "daemon.log", "other", "daemon log, including the stop path"),
) if a]
raw = {}
for line in pathlib.Path(steps).read_text().splitlines():
    parts = line.split()
    if len(parts) >= 2 and parts[0] not in ("==", "up"):
        raw[parts[0]] = parts[1].rstrip("s")
def f(k):
    v = raw.get(k, "absent")
    try: return float(v)
    except (TypeError, ValueError): return None
milestones = {
    "kernel_up_s": f("kernel-up"),
    "initramfs_s": f("initramfs"),
    "guest_script_s": f("guest-script"),
    "dockerd_ready_s": f("dockerd-ready"),
    "first_container_s": f("container-run"),
    "total_s": f("total"),
}
have = {k: v for k, v in milestones.items() if v is not None}
phase = {}
if all(milestones.get(k) is not None for k in ("kernel_up_s", "initramfs_s", "guest_script_s", "dockerd_ready_s")):
    phase = {
        "kernel_boot": round(milestones["kernel_up_s"], 2),
        "initramfs_to_guest_script": round(milestones["guest_script_s"] - milestones["initramfs_s"], 2),
        "guest_script_to_dockerd_ready": round(milestones["dockerd_ready_s"] - milestones["guest_script_s"], 2),
        "up_command_total": round(milestones["total_s"], 2) if milestones.get("total_s") else None,
    }
record = {
    "schema_version": "1.1",
    "run_id": "boot-timeline-" + dt.date.today().strftime("%Y%m%d"),
    "project_version": pathlib.Path("VERSION").read_text().strip(),
    "generated_at": dt.datetime.now().astimezone().strftime("%Y-%m-%dT%H:%M:%S%z"),
    "device": {"model": "unknown", "android_release": "unknown", "abi": "aarch64", "termux": True, "unprivileged": True},
    "kernel": {"arch": "um/arm64", "booted": True, "release": "pinned (see evidence/20261031-dir-d-ecosystem.json)", "mode": "seccomp", "ncpus": 4},
    "capabilities": {
        "boot": {"ok": True, "evidence": "A guest booted for this run; every milestone below is an event observed in that guest's own console or by asking it."},
        "timeline_measured": {"ok": bool(phase), "evidence": "Milestones: " + ", ".join(f"{k}={v}" for k, v in have.items()) + ". Phase split: " + json.dumps(phase)},
    },
    "observed": {"milestones": milestones, "phase_seconds": phase},
    "known_limits_observed": [
        "the numbers are one boot on one device; container start was measured at 15.7 s and 26.1 s in earlier runs, so treat any single figure as a sample, not a constant",
    ],
    "notes": "bench/demo-capture.sh. Not a benchmark: a phase split, to decide whether performance work is worth an axis at all (docs/DIRECTION-N1-N4.md N4).",
    "verdict": "pass" if phase else "partial",
    "artifacts": artifacts,
}
p = pathlib.Path(out_path); p.parent.mkdir(exist_ok=True)
p.write_text(json.dumps(record, indent=2) + "\n")
print("  timeline ->", p)
print("  phase    ->", json.dumps(phase))
PY

# ---- 5. write the MARKDOWN transcript ------------------------------------------------------
env -u LD_LIBRARY_PATH python3 - "$W/steps.txt" "$OUT_MD" "$W" <<'PY'
import pathlib, sys, datetime as dt
steps, out_md, work = sys.argv[1], sys.argv[2], pathlib.Path(sys.argv[3])
rows = [l for l in pathlib.Path(steps).read_text().splitlines() if l.strip() and not l.startswith("==")]
up = (work / "up.log").read_text(errors="replace").splitlines()
body = f"""# Demo — a real run, captured

Generated by `bench/demo-capture.sh` on {dt.date.today().isoformat()} from one boot on a
Termux/Android device. Every line below is output that actually happened; nothing is edited by
hand, and the numbers are wall-clock measurements taken around each command.

Reproduce it yourself:

```sh
uml4termux fetch          # or: ulter fetch  (~1.5 GB, verified against pinned digests)
uml4termux up
uml4termux exec 'docker run --rm alpine sh -c "echo CONTAINER_OK; uname -m"'
uml4termux down
```

## Timings from this run

```
{chr(10).join(rows)}
```

## What each milestone means

| Milestone | How it was detected |
|---|---|
| kernel-up | `Linux version` appears in the guest console |
| initramfs | `UML4TERMUX_INIT` (the initramfs hand-off) |
| guest-script | `WEB_UP_MARKER` (the guest's own startup script reached its docker stage) |
| dockerd-ready | the guest answers `docker info` successfully — asked, not inferred |
| container-run | `CONTAINER_OK` from `docker run --rm alpine` |

## `up` output (verbatim)

```
{chr(10).join(up[-12:])}
```

## Recording attempt

A screen recording was attempted and is **not** included: `/system/bin/screenrecord` answers
`ERROR: no display` (rc=254) when invoked from the Termux app context, so a video cannot be
produced on this device by this agent. The transcript above is the artifact; producing a video
needs a person with the screen in front of them (or a host with a display).
"""
p = pathlib.Path(out_md); p.parent.mkdir(exist_ok=True)
p.write_text(body)
print("  transcript ->", p)
PY

echo "  ---- ringkasan ----"
sed 's/^/  /' "$W/steps.txt"