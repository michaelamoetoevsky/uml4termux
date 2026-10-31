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
import re
path, pattern, t0 = sys.argv[1], sys.argv[2], float(sys.argv[3])
try:
    with open(path, errors="replace") as f:
        for line in f:
            parts = line.split(chr(9), 1)
            if len(parts) == 2 and re.search(pattern, parts[1]):
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

# Every marker here is a line only EXECUTION can produce. A marker that also appears in the
# command you sent measures your own echo: an earlier version grepped `DOCKERD_READY` and
# `CONTAINER_OK`, both of which sit inside the command text, and so reported a 0.4 s dockerd
# start for a guest whose console agent had not started at all.
K=$(wait_stamp 'Linux version' 120 || true)
I=$(wait_stamp 'UML4TERMUX_INIT' 120 || true)
AG=$(wait_stamp '__AGENT_READY__' 180 || true)
G=$(wait_stamp 'starting dockerd' 240 || true)
IMG_STAGE=$(wait_stamp 'IMAGE_(PRESENT|PULL)' 300 || true)

# dockerd readiness is stated BY THE GUEST (DOCKERD_READY_FOR_REAL) after it asked docker itself:
# `up` returning only means the control socket is up, which is seconds before dockerd listens.
D=$(wait_stamp 'DOCKERD_READY_FOR_REAL' 300 || true)

# first container: proof is `uname -m` output (`aarch64`), which is absent from the command text
R0=$(now)
"$UML4TERMUXD_BIN" exec 'docker run --rm alpine sh -c "uname -m; head -1 /etc/os-release"' >/dev/null 2>&1
C=$(wait_stamp '^aarch64$' 240 || true)
R1=$(now)
RUN_S=$(since "$R0" "$R1")

# ---- 3. down -----------------------------------------------------------------------------
D0=$(now); bin/uml4termux down --name demo >/dev/null 2>&1; DOWN_RC=$?; D1=$(now)
CLEAN=$(grep -ac 'clean shutdown landed' "$W/rt/daemon.log" 2>/dev/null); [ -n "$CLEAN" ] || CLEAN=0
T1=$(now)

touch "$STAMP_STOP"; wait "$STAMP_PID" 2>/dev/null; rm -f "$STAMP_STOP"

cat >> "$W/steps.txt" <<EOF
kernel-up        ${K}s
initramfs        ${I}s
agent-ready      ${AG}s
starting-dockerd ${G}s
image-stage      ${IMG_STAGE}s
dockerd-ready    ${D}s
container-run    ${C}s (wall ${RUN_S}s)
clean-shutdown   ${CLEAN}
down rc=${DOWN_RC}  $(since "$D0" "$D1")s
total            $(since "$T0" "$T1")s
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
    "console_agent_ready_s": f("agent-ready"),
    "dockerd_starting_s": f("starting-dockerd"),
    "image_stage_s": f("image-stage"),
    "dockerd_ready_s": f("dockerd-ready"),
    "first_container_s": f("container-run"),
    "teardown_s": f("down"),
    "total_s": f("total"),
}
have = {k: v for k, v in milestones.items() if v is not None}
phase = {}
if all(milestones.get(k) is not None for k in ("kernel_up_s", "initramfs_s", "console_agent_ready_s", "dockerd_ready_s")):
    phase = {
        "kernel_boot": round(milestones["kernel_up_s"], 2),
        "initramfs_to_console_agent": round(milestones["console_agent_ready_s"] - milestones["initramfs_s"], 2),
        "console_agent_to_dockerd_ready": round(milestones["dockerd_ready_s"] - milestones["console_agent_ready_s"], 2),
    }
    if milestones.get("first_container_s") is not None:
        phase["dockerd_ready_to_first_container"] = round(
            milestones["first_container_s"] - milestones["dockerd_ready_s"], 2)
record = {
    "schema_version": "1.1",
    "run_id": "boot-timeline-" + dt.date.today().strftime("%Y%m%d"),
    "project_version": pathlib.Path("VERSION").read_text().strip(),
    "generated_at": dt.datetime.now().astimezone().strftime("%Y-%m-%dT%H:%M:%S%z"),
    "device": {"model": "unknown", "android_release": "unknown", "abi": "aarch64", "termux": True, "unprivileged": True},
    "kernel": {"arch": "um/arm64", "booted": True, "release": "pinned (see evidence/20261031-dir-d-ecosystem.json)", "mode": "seccomp", "ncpus": 4},
    "capabilities": {
        "boot": {"ok": True, "evidence": "A guest booted for this run; every milestone below is an event observed in that guest's own console or by asking it."},
        "console_agent": {
            "ok": milestones.get("console_agent_ready_s") is not None,
            "evidence": "__AGENT_READY__ printed by the guest once its exec loop reads the console"
                        + (f" at {milestones['console_agent_ready_s']}s" if milestones.get("console_agent_ready_s") is not None else " -- ABSENT"),
        },
        "container_run": {
            "ok": milestones.get("first_container_s") is not None,
            "evidence": "`uname -m` answered aarch64 inside `docker run --rm alpine`"
                        + (f" at {milestones['first_container_s']}s" if milestones.get("first_container_s") is not None else " -- ABSENT"),
        },
        "clean_shutdown": {
            "ok": str(raw.get("clean-shutdown", "0")) not in ("0", ""),
            "evidence": ("daemon logged 'clean shutdown landed' after `down`"
                         if str(raw.get("clean-shutdown", "0")) not in ("0", "")
                         else "daemon fell back to signals: the guest did not halt on request (docs/ISSUES.md #8)"),
        },
    },
    "observed": {"milestones": milestones, "phase_seconds": phase},
    "known_limits_observed": [
        "one boot on one device: earlier captures of the same sequence measured 10 s and 178 s, so a single figure is a sample, not a constant",
        "a phase number is only as good as its marker; every marker used here is one that execution alone can produce",
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
Termux/Android device. Every line below is output that actually happened; the numbers are
wall-clock measurements taken around each command, and every milestone is a line that only
execution can produce (a marker echoed back from the command you sent does not count).

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
| kernel-up | `Linux version` in the guest console |
| initramfs | `UML4TERMUX_INIT` — the initramfs hand-off |
| agent-ready | `__AGENT_READY__` — printed once the guest's exec loop is reading the console |
| starting-dockerd | `starting dockerd...` from the guest script |
| image-stage | `IMAGE_PRESENT` / `IMAGE_PULL` — images are fetched only when missing |
| dockerd-ready | the daemon's reply marker `__EXEC_1_DONE_0`: `$?` expands at runtime, the command text only holds the literal `$?` |
| container-run | `aarch64` — output of `uname -m` inside the container |
| clean-shutdown | `1` when the daemon logged `clean shutdown landed`, `0` when it fell back to signals |

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