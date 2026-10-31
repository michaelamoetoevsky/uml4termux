#!/usr/bin/env python3
"""Stamp a growing console log with wall-clock epochs, line by line.

The guest console has no timestamps, and a phase breakdown without them is a guess: "dockerd
took 149 s" cannot be attributed to kernel, initramfs or dockerd without knowing WHEN each line
appeared. This writes `<epoch>\t<line>` as lines arrive, so `bench/demo-capture.sh` can answer
"which second is expensive" from the guest's own output instead of from polling guesses.

Usage: console-stamp.py <console.log> <timed.out> [--stop-file <path>]
Stops when <console.log> disappears, when --stop-file exists, or on SIGTERM.
"""
from __future__ import annotations

import os
import pathlib
import signal
import sys
import time

STOP = False


def _stop(*_):
    global STOP
    STOP = True


def main(argv: list[str]) -> int:
    if len(argv) < 3:
        print("usage: console-stamp.py <console.log> <timed.out> [--stop-file <path>]", file=sys.stderr)
        return 2
    src, dst = pathlib.Path(argv[1]), pathlib.Path(argv[2])
    stop_file = None
    if "--stop-file" in argv:
        stop_file = pathlib.Path(argv[argv.index("--stop-file") + 1])

    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGINT, _stop)

    # Wait for the file to appear (the daemon creates it at spawn).
    for _ in range(600):
        if src.exists():
            break
        if STOP:
            return 0
        time.sleep(0.1)

    with src.open("r", errors="replace") as f, dst.open("w") as out:
        while not STOP:
            line = f.readline()
            if line:
                stamp = time.time()
                out.write(f"{stamp:.3f}\t{line.rstrip(chr(10))}\n")
                out.flush()
                continue
            if stop_file and stop_file.exists():
                break
            if not src.exists():
                break
            time.sleep(0.05)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))