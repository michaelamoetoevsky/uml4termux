#!/usr/bin/env python3
"""Summarise an operational soak run: cycles.jsonl -> summary.json.

Reports exactly the facts docs/NEXT-STEPS.md section B asks for:
boot/cycle failures, daemon RSS trend (first third vs last third, so a real
climb is visible instead of a single noisy number), leftover processes, and the
mid-soak restart check. Writes nothing else; a missing file is reported, not
invented.

usage: soak/summarise.py <out_dir>
SPDX-License-Identifier: GPL-2.0-only
"""
from __future__ import annotations

import json
import os
import statistics
import sys


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(__doc__)
        return 64
    out = argv[1]
    path = os.path.join(out, "cycles.jsonl")
    if not os.path.exists(path):
        print(f"soak: no cycles.jsonl in {out}", file=sys.stderr)
        return 1

    rows = [json.loads(line) for line in open(path) if line.strip()]
    labels = sorted({r["label"] for r in rows})
    per_label: dict[str, dict] = {}
    for label in labels:
        mine = [r for r in rows if r["label"] == label]
        ts = [r.get("t_epoch", 0) for r in mine]
        drss = [r["daemon_rss_kb"] for r in mine if r["daemon_rss_kb"]]
        krss = [r["kernel_rss_kb"] for r in mine if r["kernel_rss_kb"]]
        third = max(1, len(drss) // 3)
        per_label[label] = {
            "cycles": len(mine),
            "cycles_failed": sum(1 for r in mine if r["up_rc"] != 0),
            "ticks_incomplete": sum(1 for r in mine if not r["tick_complete"]),
            "leftover_processes_total": sum(r["leftover_processes"] for r in mine),
            "image_unchanged_all_cycles": all(r["image_unchanged"] for r in mine),
            "restart_checks": [r["restart_check"] for r in mine if r["restart_check"] != "n/a"],
            "daemon_rss_kb_first_third_median": statistics.median(drss[:third]) if drss else None,
            "daemon_rss_kb_last_third_median": statistics.median(drss[-third:]) if drss else None,
            "daemon_rss_kb_max": max(drss) if drss else None,
            "kernel_rss_kb_max": max(krss) if krss else None,
            "dockerd_ready_cycles": sum(1 for r in mine if "ready=yes" in r["dockerd"]),
            "container_run_cycles": sum(1 for r in mine if "SOAK_RUN_OK" in r["run"]),
            "wall_seconds": (max(ts) - min(ts)) if len(ts) > 1 else 0,
            "seconds_per_cycle": round((max(ts) - min(ts)) / (len(ts) - 1), 1) if len(ts) > 1 else 0,
        }
        p = per_label[label]
        if p["daemon_rss_kb_first_third_median"] and p["daemon_rss_kb_last_third_median"]:
            delta = p["daemon_rss_kb_last_third_median"] - p["daemon_rss_kb_first_third_median"]
            p["daemon_rss_trend_kb"] = delta
            p["daemon_rss_trend_pct"] = round(delta / p["daemon_rss_kb_first_third_median"] * 100, 1)

    summary = {
        "cycles_total": len(rows),
        "labels": per_label,
        "pass": {
            "no_cycle_failures": all(v["cycles_failed"] == 0 for v in per_label.values()),
            "no_leftovers": all(v["leftover_processes_total"] == 0 for v in per_label.values()),
            "images_untouched": all(v["image_unchanged_all_cycles"] for v in per_label.values()),
            "rss_no_upward_trend": all(abs(v.get("daemon_rss_trend_pct", 0) or 0) < 10 for v in per_label.values()),
            "restart_checked": any(v["restart_checks"] for v in per_label.values()),
        },
    }
    with open(os.path.join(out, "summary.json"), "w") as fh:
        json.dump(summary, fh, indent=1)
    print(json.dumps(summary["pass"], indent=1))
    for label, v in per_label.items():
        print(f"{label}: cycles={v['cycles']} failed={v['cycles_failed']} "
              f"rss_trend={v.get('daemon_rss_trend_pct')}% max_rss={v['daemon_rss_kb_max']}KB "
              f"leftovers={v['leftover_processes_total']} runs_ok={v['container_run_cycles']}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))