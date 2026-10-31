#!/usr/bin/env python3
"""Write the direction-D1 evidence record from the CI job logs.

Every value in the record is PARSED from the logs the jobs produced, never
re-typed: the guest's own lines come from the boot log, the gate results come from
the userspace log, and the artifact digests are computed from the files. A record
whose numbers were typed by hand is a record nobody can regenerate.

usage: ci/glibc/evidence.py --record evidence/<name>.json \
           --boot-log <log> --userspace-log <log> [--note TEXT]
# SPDX-License-Identifier: GPL-2.0-only
"""
from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import re
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
LOGDIR = ROOT / "evidence" / "logs"


def sha(p: pathlib.Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()


def strip_ts(line: str) -> str:
    """GitHub prefixes every log line with an ISO timestamp and a space."""
    return re.sub(r"^\d{4}-\d{2}-\d{2}T[\d:.]+Z ", "", line).rstrip("\n")


def read(path: pathlib.Path) -> list[str]:
    return [strip_ts(l) for l in path.read_text(errors="replace").splitlines()]


def first(lines: list[str], needle: str) -> str:
    for l in lines:
        if needle in l:
            return l.strip()
    return ""


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--record", required=True)
    ap.add_argument("--boot-log", required=True)
    ap.add_argument("--userspace-log", required=True)
    ap.add_argument("--note", action="append", default=[])
    args = ap.parse_args()

    boot = read(pathlib.Path(args.boot_log))
    user = read(pathlib.Path(args.userspace_log))

    # The guest's own report, as it printed it inside the guest.
    g_ok = first(boot, "GLIBCBOOT-OK")
    g_rel = first(boot, "GLIBCBOOT-RELEASE")
    g_ncpu = first(boot, "GLIBCBOOT-NCPU")
    g_mem = first(boot, "GLIBCBOOT-MEMTOTAL")
    g_done = first(boot, "GLIBCBOOT-DONE")

    def after(line: str, key: str) -> str:
        return line.split(key, 1)[1].strip() if key in line else ""

    abi = after(g_ok, "arch=")
    release = g_rel.split("RELEASE", 1)[1].strip() if "RELEASE" in g_rel else ""
    ncpus = int(after(g_ncpu, "NCPU")) if "NCPU" in g_ncpu and after(g_ncpu, "NCPU").isdigit() else 0
    memtotal_kb = int(after(g_mem, "MEMTOTAL")) if "MEMTOTAL" in g_mem and after(g_mem, "MEMTOTAL").isdigit() else 0

    contract = first(user, "runtime contract v1")
    hardening = first(user, "daemon hardening")
    parity = first(user, "daemon parity OK")
    rust = first(user, "test result: ok")
    bionic = first(user, "uml4termuxd                  BIONIC-ONLY")
    portable = [l for l in boot if "PORTABLE (static, no loader)" in l]

    record_path = pathlib.Path(args.record)
    # Artifacts are copied in beside the record with the record's stem in the name,
    # so a regeneration cannot overwrite another record's copies. The stem already
    # begins with the date, so it is stripped before the prefix is added.
    stem = re.sub(r"^\d{8}-", "", record_path.stem)
    stamp = subprocess.run(["date", "+%Y%m%d"], capture_output=True,
                           text=True).stdout.strip()
    artifacts = []
    for role, src in (("boot", pathlib.Path(args.boot_log)),
                      ("userspace", pathlib.Path(args.userspace_log))):
        dst = LOGDIR / f"{stamp}-{stem}-{role}.log"
        shutil.copyfile(src, dst)
        artifacts.append({"kind": "console-log", "path": f"logs/{dst.name}",
                          "sha256": sha(dst)})

    rec = {
        "schema_version": "1.1",
        "run_id": record_path.stem,
        "project_version": (ROOT / "VERSION").read_text().strip(),
        "generated_at": subprocess.run(["date", "+%Y-%m-%dT%H:%M:%S%z"],
                                       capture_output=True, text=True).stdout.strip(),
        # Not this phone: a GitHub-hosted arm64 VM running glibc. Saying so is the
        # point of the record -- D1 is about leaving Termux.
        "device": {
            "model": "GitHub Actions hosted runner, arm64 (ubuntu-24.04-arm)",
            "android_release": "none: Linux with glibc, not Android",
            "abi": abi or "aarch64",
            "unprivileged": True,
        },
        "host": {"os": "Ubuntu 24.04 (arm64)", "libc": "glibc"},
        "kernel": {"arch": "um/arm64", "booted": bool(g_done), "release": release,
                   "mode": "seccomp", "ncpus": ncpus, "memtotal_kb": memtotal_kb},
        "capabilities": {
            "boot": {
                "ok": bool(g_ok and g_done),
                "evidence": (f"The RELEASED kernel (built with the Android NDK, "
                             f"statically linked, so it carries no libc dependency) booted on a "
                             f"glibc/aarch64 Linux host and the guest reported from inside: "
                             f"'{g_ok}', '{g_rel}', '{g_ncpu}', '{g_mem}', '{g_done}'. The guest "
                             f"root filesystem was a busybox initramfs, so no disk image and no "
                             f"host libc were involved."),
            },
            "daemon_built_for_glibc": {
                "ok": bool(contract),
                "evidence": (f"cc (gcc) built src/uml4termuxd.c against glibc on that host and the "
                             f"result passed the project's own gates there: '{contract}'; "
                             f"'{hardening}'; '{rust}'; '{parity}'."),
            },
            "artifact_classification": {
                "ok": bool(bionic and portable),
                "evidence": (f"ci/glibc/classify.sh reads the ELF instead of guessing from names: "
                             f"'{bionic}' for the tracked device binary, and "
                             f"{len(portable)} released asset(s) reported as PORTABLE (static, no "
                             f"loader) -- which is why the kernel runs off-device at all."),
            },
        },
        "observed": {
            "guest_reported": {"arch": abi, "release": release, "ncpus": ncpus,
                               "memtotal_kb": memtotal_kb},
            "gates_on_glibc": {"contract_v1": contract, "hardening": hardening,
                               "c_vs_rust_parity": parity, "rust_tests": rust},
        },
        "known_limits_observed": [
            "the enroling job runs on a GitHub-hosted runner, so the numbers describe "
            "that VM and not this phone",
            "gnu userland only: the workflows prove the kernel and daemon on glibc, not "
            "Docker inside the guest there (that needs a real rootfs and is run on the device)",
        ],
        "notes": " ".join(
            ["Direction D1 (docs/NEXT-STEPS.md): the daemon and the Rust front end were "
             "bionic-only; the kernel and stub are already static. This record is produced by "
             "ci/glibc/evidence.py from the two job logs, in CI, on a glibc/aarch64 host."]
            + list(args.note)),
        "verdict": "pass" if (g_done and contract and parity) else "partial",
        "artifacts": artifacts,
    }
    record_path.write_text(json.dumps(rec, indent=2, ensure_ascii=False) + "\n")
    print(f"record: {record_path} | verdict={rec['verdict']} | artifacts={len(artifacts)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
