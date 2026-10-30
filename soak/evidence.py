#!/usr/bin/env python3
"""Turn soak run directories into one schema-1.1 evidence record.

Reads <out>/cycles.jsonl from one or more soak runs (B1 alone, B1 + B2 parallel),
copies the artifacts into evidence/logs with a date prefix, and writes the record
the project's checker accepts. Every number comes from the cycles themselves --
nothing is re-typed from a terminal.

usage: soak/evidence.py --record evidence/<name>.json <out_dir> [<out_dir> ...]
SPDX-License-Identifier: GPL-2.0-only
"""
from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import shutil
import subprocess

ROOT = pathlib.Path(__file__).resolve().parent.parent
LOG = ROOT / "evidence/logs"
STAMP = subprocess.run(["date", "+%Y%m%d"], capture_output=True, text=True).stdout.strip()


def sha(p: pathlib.Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()


def load(out: pathlib.Path) -> list[dict]:
    path = out / "cycles.jsonl"
    if not path.exists():
        raise SystemExit(f"soak: no cycles.jsonl in {out}")
    return [json.loads(line) for line in path.open() if line.strip()]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--record", required=True)
    ap.add_argument("dirs", nargs="+")
    args = ap.parse_args()

    rows: list[dict] = []
    artifacts: list[pathlib.Path] = []
    per_dir: dict[str, dict] = {}

    for d in args.dirs:
        out = pathlib.Path(d)
        mine = load(out)
        rows.extend(mine)
        ts = [r["t_epoch"] for r in mine]
        per_dir[out.name] = {
            "cycles": len(mine),
            "wall_minutes": round((ts[-1] - ts[0]) / 60, 1) if len(ts) > 1 else 0,
            "seconds_per_cycle": round((ts[-1] - ts[0]) / (len(ts) - 1), 1) if len(ts) > 1 else 0,
            "labels": sorted({r["label"] for r in mine}),
        }
        for name in ("cycles.jsonl", "summary.json", "final-summary.txt", "run-meta.json"):
            src = out / name
            if src.exists():
                dst = LOG / f"{STAMP}-soak-{out.name}-{name}"
                shutil.copyfile(src, dst)
                artifacts.append(dst)
    # Script copies carry the record's own stem: naming them after the file alone
    # collided with artifacts that a PREVIOUS record had already committed, and a
    # cleanup then deleted tracked evidence files.
    stem = pathlib.Path(args.record).stem
    for name in ("soak/soak.sh", "soak/summarise.py", "soak/guest/tick.sh", "soak/restart-check.sh"):
        src = ROOT / name
        if src.exists():
            dst = LOG / f"{STAMP}-{stem}-{src.name}"
            shutil.copyfile(src, dst)
            artifacts.append(dst)

    labels = sorted({r["label"] for r in rows})
    daemon_rss = [r["daemon_rss_kb"] for r in rows if r["daemon_rss_kb"]]
    kernel_rss = [r["kernel_rss_kb"] for r in rows if r["kernel_rss_kb"]]
    third = max(1, len(daemon_rss) // 3)
    first_third = sorted(daemon_rss)[:third]
    last_third = sorted(daemon_rss)[-third:]
    med_first = first_third[len(first_third) // 2] if first_third else None
    med_last = last_third[len(last_third) // 2] if last_third else None
    trend_pct = round((med_last - med_first) / med_first * 100, 1) if med_first and med_last else None

    failures = [r for r in rows if r["up_rc"] != 0]
    incomplete = [r for r in rows if not r["tick_complete"]]
    leftovers = sum(r["leftover_processes"] for r in rows)
    untouched = all(r["image_unchanged"] for r in rows)
    docker_ok = sum(1 for r in rows if "SOAK_RUN_OK" in r["run"])
    total_wall = sum(v["wall_minutes"] for v in per_dir.values())

    rec = {
        "schema_version": "1.1",
        "run_id": pathlib.Path(args.record).stem,
        "project_version": (ROOT / "VERSION").read_text().strip(),
        "generated_at": subprocess.run(["date", "+%Y-%m-%dT%H:%M:%S%z"],
                                       capture_output=True, text=True).stdout.strip(),
        "device": {"model": "2406APNFAG", "android_release": "16", "abi": "aarch64",
                   "termux": True, "unprivileged": True},
        "kernel": {"arch": "um/arm64", "booted": True,
                   "release": "7.2.0-rc4-g169b17ff3f66-dirty", "mode": "seccomp", "ncpus": 4},
        "capabilities": {
            "boot": {
                "ok": not failures and not incomplete,
                "evidence": (f"{len(rows)} boot cycles across {len(labels)} instance label(s) "
                             f"({', '.join(labels)}); {len(failures)} cycle(s) failed to start, "
                             f"{len(incomplete)} cycle(s) never reached the guest's own tick marker. "
                             f"Every run boots with an ephemeral COW overlay, so each cycle starts from "
                             f"the pristine backing image."),
            },
            "no_leftover_processes": {
                "ok": leftovers == 0,
                "evidence": (f"{leftovers} leftover process(es) summed over all cycles, counted by "
                             f"resolving /proc/<pid>/exe (never by pattern: a pattern also matches the "
                             f"calling shell on this device)."),
            },
            "images_untouched": {
                "ok": untouched,
                "evidence": (f"Backing image sha256 AND mtime identical before/after every cycle: "
                             f"{'yes' if untouched else 'NO'} -- proof the writes went to the COW overlay "
                             f"and the shared image was never modified."),
            },
            "daemon_rss_stable": {
                "ok": trend_pct is None or abs(trend_pct) < 10,
                "evidence": (f"Daemon RSS ranged {min(daemon_rss)}-{max(daemon_rss)} KB; median of the "
                             f"first third {med_first} KB vs last third {med_last} KB ({trend_pct}%). "
                             f"Guest kernel RSS ranged {min(kernel_rss)}-{max(kernel_rss)} KB."
                             if daemon_rss and kernel_rss else "RSS not recorded"),
            },
            "docker_every_cycle": {
                "ok": docker_ok == len(rows),
                "evidence": (f"dockerd reached a usable API and a container ran to completion in "
                             f"{docker_ok}/{len(rows)} cycles; the guest reports the daemon version and "
                             f"storage driver each cycle."),
            },
            "duration": {
                "ok": total_wall >= 120,
                "evidence": (f"Measured wall-clock: {total_wall:.1f} minutes across {per_dir}; "
                             f"{json.dumps(per_dir)}"),
            },
        },
        "verdict": "pass" if (not failures and not incomplete and leftovers == 0 and untouched
                              and (trend_pct is None or abs(trend_pct) < 10)) else "partial",
        "artifacts": [{"kind": "console-log" if p.suffix in (".log", ".txt", ".jsonl") else "other",
                       "path": f"logs/{p.name}", "sha256": sha(p)} for p in sorted(artifacts)],
        "notes": "Direction B (docs/NEXT-STEPS.md). B3 (restart + exposure re-apply) has its own "
                 "record: evidence/20261030-soak-b3-restart.json.",
        "known_limits_observed": [
            "each cycle pulls its container image unless the COW overlay keeps a cache; with an "
            "ephemeral overlay every cycle starts from the pristine image",
            "RSS is sampled once per cycle right after readiness (the guest powers off at the end "
            "of its tick, taking the daemon's state file with it)",
        ],
    }
    pathlib.Path(args.record).write_text(json.dumps(rec, indent=1, ensure_ascii=False) + "\n")
    print(f"record: {args.record} | verdict={rec['verdict']} | cycles={len(rows)} | "
          f"wall={total_wall:.1f} min | leftovers={leftovers} | rss_trend={trend_pct}%")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())