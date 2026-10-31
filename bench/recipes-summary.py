#!/usr/bin/env python3
"""Summarise a bench/recipes.sh run from the consoles it captured.

ONE parser. The values used to be read twice -- once by bash `value_of` for the note a
human reads, once by an inline python block for summary.json -- and the two disagreed on
the same run: the note printed "push 10074 ms" while the artifact recorded null, because
the python version compared the whole second-to-last token to the key while the marker is
actually a PREFIX ("D4r<epoch>-PUSH_MS 10074"). Two implementations of one number is a
bug in the evidence path, not a formatting detail: the artifact is what outlives the run.

Usage: recipes-summary.py <run-out-dir>
"""
from __future__ import annotations

import json
import pathlib
import sys


def value_of(out: pathlib.Path, name: str, key: str) -> str | None:
    """Last value for <key> in <name>.console.log, where the marker is a PREFIX."""
    f = out / f"{name}.console.log"
    if not f.exists():
        return None
    for line in reversed(f.read_text(errors="replace").splitlines()):
        parts = line.split()
        # parts[-2] is "D4r<epoch>-PUSH_MS", not "PUSH_MS"; accept both so a future
        # harness that emits a bare key keeps working.
        if len(parts) >= 2 and (parts[-2] == key or parts[-2].endswith("-" + key)):
            return parts[-1].strip()
    return None


def as_int(raw: str | None) -> int | None:
    try:
        return int(raw) if raw not in (None, "") else None
    except ValueError:
        return None


def wall(out: pathlib.Path, name: str) -> int | None:
    f = out / f"{name}.seconds"
    try:
        return int(f.read_text().strip())
    except (OSError, ValueError):
        return None


def summarise(out: pathlib.Path) -> dict:
    total = as_int(value_of(out, "r1", "TOTAL_MS"))
    return {
        "container_start_media_ms": total // 10 if total else None,
        "container_start_total_ms": total,
        "alpine_bytes": as_int(value_of(out, "r1", "IMAGE_BYTES")),
        "registry_push_ms": as_int(value_of(out, "r3", "PUSH_MS")),
        "registry_pull_ms": as_int(value_of(out, "r3", "PULL_MS")),
        "registry_image_bytes": as_int(value_of(out, "r3", "IMAGE_BYTES")),
        "harness_wall_seconds": {n: wall(out, n) for n in ("r1", "r2", "r3")},
    }


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: recipes-summary.py <run-out-dir>", file=sys.stderr)
        return 2
    out = pathlib.Path(argv[1])
    summary = summarise(out)
    (out / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print("  summary -> " + str(out / "summary.json"))
    for k, v in summary.items():
        if k != "harness_wall_seconds" and v is not None:
            print(f"    {k}: {v}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))