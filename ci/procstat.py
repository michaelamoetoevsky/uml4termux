#!/usr/bin/env python3
"""Read /proc/<pid>/stat without tripping over the comm field.

`/proc/<pid>/stat` is space-separated EXCEPT field 2 (comm), which is wrapped in parentheses and
may itself contain spaces and parentheses -- so `open(...).read().split()` silently misreads every
later field for any process whose name contains one. That is exactly how the first attempt at
counting the instance's host children died:

    ValueError: invalid literal for int() with base 10: '@playw)'

Everything after the LAST ')' is regular space-separated data, so that is where parsing starts.

Usage:
  procstat.py ppid <pid>        parent pid of <pid>
  procstat.py children [<pid>]  pids whose parent is <pid>
  procstat.py table [<pid>]     "pid ppid threads comm" per process, space separated
"""
from __future__ import annotations

import os
import sys


def parse_stat_line(raw: str) -> list[str] | None:
    """Split one /proc/<pid>/stat line. Pure function, so the trap can be tested with a crafted
    line instead of depending on a live process being named awkwardly."""
    close = raw.rfind(")")
    if close < 0:
        return None
    head, tail = raw[:close], raw[close + 2:]
    # head is "<pid> (<comm>"; only the pid before the first space is useful
    pid_str = head.split(" ", 1)[0]
    return [pid_str] + tail.split()


def stat_fields(pid: int | str) -> list[str] | None:
    """Fields of /proc/<pid>/stat, with comm removed: [0]=pid(p), [1]=state, [2]=ppid, ..."""
    try:
        raw = open(f"/proc/{pid}/stat", "rb").read().decode("utf-8", "replace")
    except OSError:
        return None
    return parse_stat_line(raw)


def ppid_of(pid: int | str) -> int | None:
    f = stat_fields(pid)
    if not f or len(f) < 2:
        return None
    try:
        return int(f[2])
    except (IndexError, ValueError):
        return None


def threads_of(pid: int | str) -> int:
    try:
        return len(os.listdir(f"/proc/{pid}/task"))
    except OSError:
        return 0


def comm_of(pid: int | str) -> str:
    try:
        raw = open(f"/proc/{pid}/stat", "rb").read().decode("utf-8", "replace")
    except OSError:
        return "?"
    if raw.rfind(")") < 0:
        return "?"
    return raw[raw.find("(") + 1:raw.rfind(")")]


def all_pids() -> list[int]:
    return [int(p) for p in os.listdir("/proc") if p.isdigit()]


def children_of(pid: int | str) -> list[int]:
    target = int(pid)
    return [p for p in all_pids() if ppid_of(p) == target]


def main(argv: list[str]) -> int:
    if len(argv) < 2 or argv[1] not in ("ppid", "children", "table", "parse"):
        print(__doc__.strip().split("Usage:")[1].strip(), file=sys.stderr)
        return 2
    mode = argv[1]
    if mode == "parse":
        f = parse_stat_line(argv[2])
        print(f[2] if f and len(f) > 2 else "unparsed")
        return 0
    if mode == "ppid":
        if len(argv) < 3:
            return 2
        print(ppid_of(argv[2]))
        return 0
    target = int(argv[2]) if len(argv) > 2 else os.getpid()
    if mode == "children":
        for p in children_of(target):
            print(p)
        return 0
    for p in all_pids():
        print(f"{p} {ppid_of(p)} {threads_of(p)} {comm_of(p)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))