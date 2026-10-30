#!/usr/bin/env python3
"""Summarise bench run logs: median + range per (kernel, profile).

Kept as a standalone script (not an inline heredoc) so a campaign can be
re-summarised after extra runs are added, without re-booting anything.

usage: benchmark-summarise.py <runs_dir_or_campaign_dir> [--min-runs 3]

Reads every *.log under <dir>/runs (or <dir> itself when it already is a runs
dir), finds `RESULT profile=<p> ... ms=<n>` lines, and writes summary.json +
summary.md next to the logs. A verdict line is only printed when every kernel
has at least --min-runs values for that profile -- a cell with too few runs is
reported as incomplete instead of guessed at.

SPDX-License-Identifier: GPL-2.0-only
"""
from __future__ import annotations

import glob
import json
import os
import re
import statistics
import sys

RESULT_RE = re.compile(r"RESULT profile=(\w+)[^\n]*?\bms=(\d+)")
KERNEL_RE = re.compile(r"Linux version ([\w.\-+]+)|kernel=([\w.\-+]+)")
SKIP_RE = re.compile(r"RESULT profile=(\w+)[^\n]*?\bskipped=1")


def collect(out: str) -> tuple[dict, dict]:
    runs_dir = os.path.join(out, "runs") if os.path.isdir(os.path.join(out, "runs")) else out
    data: dict[str, dict[str, list[int]]] = {}
    releases: dict[str, set[str]] = {}
    for path in sorted(glob.glob(os.path.join(runs_dir, "*.log"))):
        label = os.path.basename(path)[:-4].rsplit("-", 1)[0]
        txt = open(path, errors="replace").read()
        for m in KERNEL_RE.finditer(txt):
            rel = m.group(1) or m.group(2)
            if rel:
                releases.setdefault(label, set()).add(rel)
                break
        for skipped in SKIP_RE.findall(txt):
            data.setdefault(label, {}).setdefault(skipped, [])
        for prof, ms in RESULT_RE.findall(txt):
            data.setdefault(label, {}).setdefault(prof, []).append(int(ms))
    return data, releases


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(__doc__)
        return 64
    out = argv[1]
    min_runs = 3
    if "--min-runs" in argv:
        min_runs = int(argv[argv.index("--min-runs") + 1])

    data, releases = collect(out)
    profiles = sorted({p for v in data.values() for p in v})
    labels = sorted(data)

    cells: dict[str, dict] = {}
    lines = [
        "| kernel | release | profile | runs | median ms | min | max | spread |",
        "|---|---|---|---|---|---|---|---|",
    ]
    for label in labels:
        rel = ",".join(sorted(releases.get(label, {"?"}))) or "?"
        for prof in profiles:
            vals = data[label].get(prof, [])
            if not vals:
                lines.append(f"| {label} | {rel} | {prof} | 0 | - | - | - | incomplete |")
                continue
            med = statistics.median(vals)
            spread = (max(vals) - min(vals)) / med * 100 if med else 0.0
            cells[f"{label}/{prof}"] = {
                "runs": len(vals),
                "median_ms": med,
                "min_ms": min(vals),
                "max_ms": max(vals),
                "spread_pct": round(spread, 1),
                "values": vals,
            }
            lines.append(
                f"| {label} | {rel} | {prof} | {len(vals)} | {med:.0f} | "
                f"{min(vals)} | {max(vals)} | {spread:.1f}% |"
            )

    verdicts = []
    for prof in profiles:
        got = {l: len(data[l].get(prof, [])) for l in labels}
        if len(labels) < 2 or any(n < min_runs for n in got.values()):
            verdicts.append(f"VERDICT {prof}: INCOMPLETE (runs {got}, need {min_runs} per kernel)")
            continue
        a, b = labels[0], labels[-1]
        ma = statistics.median(data[a][prof])
        mb = statistics.median(data[b][prof])
        delta = (mb - ma) / ma * 100 if ma else 0.0
        rel = "setara (selisih <5%)" if abs(delta) < 5 else (
            f"{b} lebih cepat {abs(delta):.1f}%" if delta < 0 else f"{b} lebih lambat {delta:.1f}%"
        )
        verdicts.append(f"VERDICT {prof}: {a} {ma:.0f} ms vs {b} {mb:.0f} ms -> {rel}")

    summary = {
        "kernels": labels,
        "profiles": profiles,
        "kernel_releases": {k: sorted(v) for k, v in releases.items()},
        "cells": cells,
        "verdicts": verdicts,
        "min_runs": min_runs,
    }
    with open(os.path.join(out, "summary.json"), "w") as fh:
        json.dump(summary, fh, indent=1)
    with open(os.path.join(out, "summary.md"), "w") as fh:
        fh.write("\n".join(lines) + "\n\n" + "\n".join(verdicts) + "\n")
    print("\n".join(lines))
    print()
    print("\n".join(verdicts))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
