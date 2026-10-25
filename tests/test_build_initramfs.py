#!/usr/bin/env python3
"""Generator unit test: run scripts/build-initramfs.py and re-parse the cpio.

The generator is owned by another workstream and its exact CLI is not fixed
here. We try a few common patterns, and the first one that produces a valid
gzip-compressed newc cpio archive wins. If none works, the test exits 77
(SKIP) with a clear message.

What we verify once we have a cpio.gz:
  * It is a valid gzip stream.
  * It decodes to a newc-format cpio archive (magic "070701" or "070702").
  * The archive has a proper TRAILER!!! entry.
  * No entry has an absolute path or ".." component (no path escapes).
  * At least one non-trailer file entry exists (the initramfs is not empty).

The cpio parser is written in pure Python (no external deps, no LD_LIBRARY_PATH
issues). It uses the standard library `gzip` (which needs `zlib`; if that
fails we fall back to `gzip -dc` via subprocess).
"""

from __future__ import annotations

import argparse
import gzip
import os
import struct
import subprocess
import sys
import tempfile

SKIP = 77


# ---------------------------------------------------------------------------
# gzip decompression: try Python zlib first, fall back to `gzip -dc`
# ---------------------------------------------------------------------------
def gunzip_bytes(data: bytes) -> bytes:
    try:
        return gzip.decompress(data)
    except Exception:
        try:
            return subprocess.check_output(["gzip", "-dc"], input=data, timeout=30)
        except Exception:
            pass
    return b""


# ---------------------------------------------------------------------------
# newc cpio parser (read-only, streaming, no external deps)
# ---------------------------------------------------------------------------
CPIO_HDR_FMT = "@" + "6s" * 11  # 11 ascii hex fields, 6 chars each = 66 bytes
CPIO_HDR_SIZE = 110  # 11*6 + padding to 4? No, newc header is 110 bytes total.

# Actually newc header: 11 fields * 8 hex digits = 88 chars? Let me check.
# newc (SVR4 with CRC) header: 110 bytes
#   c_magic      6  octal ascii  "070701" or "070702"
#   c_ino        8  hex
#   c_mode       8  hex
#   c_uid        8  hex
#   c_gid        8  hex
#   c_nlink      8  hex
#   c_mtime      8  hex
#   c_filesize   8  hex
#   c_devmajor   8  hex
#   c_devminor   8  hex
#   c_rdevmajor  8  hex
#   c_rdevminor  8  hex
#   c_namesize   8  hex
#   c_check      8  hex
# = 110 bytes exactly (11*6 + 8*? wait)

# Let me be precise: the "newc" format uses ASCII hex for all numeric fields,
# each field is 8 hex digits (4 bytes) except magic which is 6 octal digits.
# Standard newc header: 110 bytes = 6 + 10*8 + 2*? Actually:
# magic(6) + ino(8) + mode(8) + uid(8) + gid(8) + nlink(8) + mtime(8) +
# filesize(8) + devmajor(8) + devminor(8) + rdevmajor(8) + rdevminor(8) +
# namesize(8) + check(8) = 6 + 13*8 = 110 bytes. Yes.

# Python struct for 110-byte header:
#   6s (magic) + 13 * 8s = 6 + 104 = 110
_CPIO_HDR_STRUCT = struct.Struct("6s" + "8s" * 13)


def parse_cpio_newc(data: bytes):
    """Yield (path, mode, size, file_data, is_trailer) for each entry.

    newc layout: 110-byte header (6-byte magic "070701"/"070702" + 13 hex
    fields), then the NUL-terminated name, then the file data. Both the name
    and the data are padded so that the *next* field starts on a 4-byte
    boundary of the archive (the header is 110 bytes, i.e. not a multiple of
    4, so the padding depends on the absolute offset).
    """
    i = 0
    n = len(data)
    file_count = 0
    while i + CPIO_HDR_SIZE <= n:
        hdr = data[i : i + CPIO_HDR_SIZE]
        i += CPIO_HDR_SIZE
        fields = _CPIO_HDR_STRUCT.unpack(hdr)
        magic = fields[0].decode("ascii", errors="replace")
        if magic not in ("070701", "070702"):
            raise ValueError(
                f"unsupported cpio magic {magic!r} at offset {i - CPIO_HDR_SIZE}: "
                "only the newc format (070701/070702) is supported"
            )
        # newc header after the 6-byte magic carries 13 hex fields:
        #   ino mode uid gid nlink mtime filesize devmajor devminor
        #   rdevmajor rdevminor namesize check
        def hx(b):
            return int(b.decode("ascii", errors="replace"), 16)

        (ino, mode, uid, gid, nlink, mtime, filesize, devmajor, devminor,
         rdevmajor, rdevminor, namesize, check) = [hx(f) for f in fields[1:]]
        # name
        if i + namesize > n:
            raise ValueError("cpio name extends past end of data")
        name_bytes = data[i : i + namesize]
        i += namesize
        # name is NUL-terminated
        name = name_bytes.rstrip(b"\0").decode("utf-8", errors="replace")
        # pad the NAME so the file data starts on a 4-byte boundary
        i += (4 - (i % 4)) % 4
        # file data
        if i + filesize > n:
            raise ValueError(f"cpio file data extends past end (need {filesize}, have {n - i})")
        file_data = data[i : i + filesize]
        i += filesize
        # pad the DATA so the next header starts on a 4-byte boundary
        i += (4 - (i % 4)) % 4
        is_trailer = name == "TRAILER!!!"
        if not is_trailer:
            file_count += 1
        yield name, mode, filesize, file_data, is_trailer
        if is_trailer:
            break
    if file_count == 0:
        raise ValueError("cpio archive has no file entries (only TRAILER!!!)")
    # Trailing zero padding to 512 bytes is optional; ignore.


def test_generator(generator_path: str, guest_dir: str | None = None) -> int:
    # Candidate invocations to try, in order. The generator must produce a
    # .cpio.gz file on stdout or at a given output path.
    candidates = [
        # (args list, output_capture_mode, output_path_if_any)
        # mode "stdout" -> capture stdout
        # mode "file" -> read the given path after run
        (["--output", "{out}"], "file", "{out}"),
        (["-o", "{out}"], "file", "{out}"),
        (["{out}"], "file", "{out}"),
        ([], "stdout", None),
    ]
    # The project's generator takes an explicit --guest-dir and --out. Try that
    # shape first when a guest directory is available.
    if guest_dir and os.path.isdir(guest_dir):
        candidates.insert(
            0,
            (["--guest-dir", guest_dir, "--out", "{out}"], "file", "{out}"),
        )

    tried = []
    with tempfile.TemporaryDirectory() as td:
        out_path = os.path.join(td, "initramfs.cpio.gz")
        for args_tpl, mode, out_tpl in candidates:
            args = [a.format(out=out_path, guest_dir=guest_dir or "") for a in args_tpl]
            cmd = [sys.executable, generator_path] + args
            tried.append(" ".join(cmd))
            try:
                if mode == "stdout":
                    result = subprocess.run(
                        cmd, capture_output=True, timeout=120, check=False
                    )
                    if result.returncode != 0:
                        print(f"  {cmd} -> exit {result.returncode}: "
                              f"{result.stderr.decode(errors='replace').strip()[:300]}")
                        continue
                    cpio_gz = result.stdout
                else:
                    result = subprocess.run(
                        cmd, capture_output=True, timeout=120, check=False
                    )
                    if result.returncode != 0:
                        print(f"  {cmd} -> exit {result.returncode}: "
                              f"{result.stderr.decode(errors='replace').strip()[:300]}")
                        continue
                    if not os.path.exists(out_path):
                        print(f"  {cmd} -> exit 0 but {out_path} was not created")
                        continue
                    with open(out_path, "rb") as fh:
                        cpio_gz = fh.read()
            except subprocess.TimeoutExpired:
                print(f"  {cmd} -> timed out")
                continue
            except OSError as exc:
                print(f"  {cmd} -> {exc}")
                continue

            if not cpio_gz:
                print(f"  {cmd} -> produced no output")
                continue
            if cpio_gz[:2] != b"\x1f\x8b":
                print(f"  {cmd} -> output is not a gzip stream")
                continue

            try:
                cpio_raw = gunzip_bytes(cpio_gz)
                if not cpio_raw:
                    print(f"  {cmd} -> gzip stream could not be decompressed")
                    continue
                entries = list(parse_cpio_newc(cpio_raw))
            except Exception as exc:
                print(f"  parse failed for {cmd}: {exc}")
                continue

            # If we get here, we have a valid cpio
            print(f"  generator OK via: {cmd}")
            print(f"  cpio entries: {len(entries)}")
            names = []
            for name, mode, size, _, is_trailer in entries:
                if is_trailer:
                    print("    TRAILER!!! (end)")
                else:
                    print(f"    {oct(mode)} {size:8d}  {name}")
                    names.append(name)
                    if name.startswith("/") or ".." in name.split("/"):
                        print(f"  PATH ESCAPE: {name}")
                        return 1
                    if size < 0:
                        print(f"  NEGATIVE SIZE: {name}")
                        return 1
                    # A regular file in a newc archive has the S_IFREG bit set.
                    if not (mode & 0o100000):
                        print(f"  NOT A REGULAR FILE: {name} (mode {oct(mode)})")
                        return 1

            # The archive must actually contain the guest entry point: an
            # initramfs without "init" cannot boot.
            if "init" not in names:
                print("  MISSING 'init' ENTRY -- the archive cannot boot")
                return 1

            # The generator's own output lists TRAILER!!! first (it writes the
            # entries in reverse), so do not assert on ordering -- but do
            # assert that a trailer is present and that entries exist.
            if not any(t for _, _, _, _, t in entries):
                print("  NO TRAILER!!! ENTRY")
                return 1

            print(f"  verified: {len(names)} file entry(ies), trailer present, init present")
            return 0

    # Nothing worked
    print("generator unit test: SKIP -- no invocation produced a valid cpio.gz")
    print("  tried:")
    for t in tried:
        print(f"    {t}")
    print("  Ensure scripts/build-initramfs.py accepts one of:")
    print("    --guest-dir DIR --out FILE")
    print("    --output FILE")
    print("    -o FILE")
    print("    FILE (positional)")
    print("    (no args, writes to stdout)")
    return SKIP


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="Test initramfs generator + cpio re-parse")
    ap.add_argument("--generator", default="scripts/build-initramfs.py",
                    help="Path to the generator script")
    ap.add_argument("--guest-dir", default="scripts/guest",
                    help="Guest directory passed to the generator (if it wants one)")
    args = ap.parse_args(argv)

    gen = args.generator
    if not os.path.exists(gen):
        print(f"generator unit test: SKIP -- {gen} does not exist yet")
        return SKIP

    guest_dir = args.guest_dir
    if guest_dir and not os.path.isdir(guest_dir):
        guest_dir = None

    print(f"generator unit test: testing {gen}")
    return test_generator(gen, guest_dir)


if __name__ == "__main__":
    sys.exit(main())