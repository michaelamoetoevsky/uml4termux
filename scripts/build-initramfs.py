#!/usr/bin/env python3
# -*- coding: utf-8 -*-
#
# scripts/build-initramfs.py — build a newc cpio.gz initramfs for uml4termux.
# Reads a base initramfs (optional), adds/overwrites guest scripts from
# --guest-dir with token substitution (@@KEY@@), and writes a gzipped newc archive.
#
# SPDX-License-Identifier: GPL-2.0-only

import argparse
import gzip
import os
import shutil
import struct
import sys
import tarfile
import tempfile
from pathlib import Path
from typing import Dict, Generator, List, Optional, Tuple

# ---------------------------------------------------------------------------
# cpio "newc" (hex) format constants
# Each header: 110 bytes, fields as 8-char hex (unsigned 32-bit) except
# namesize (16-bit) and name (null-terminated, padded to 4 bytes)
# Followed by file data (padded to 4 bytes), then next header.
# Trailer: name="TRAILER!!!", filesize=0.

HEADER_FMT = (
    "070701"          # magic (6 bytes, no null)
    "{ino:08x}{mode:08x}{uid:08x}{gid:08x}{nlink:08x}"
    "{mtime:08x}{filesize:08x}{devmaj:08x}{devmin:08x}"
    "{rdevmaj:08x}{rdevmin:08x}{namesize:08x}{check:08x}"
)
HEADER_LEN = 110
TRAILER_NAME = b"TRAILER!!!"
PAD_ALIGN = 4

def pad4(n: int) -> int:
    return (n + PAD_ALIGN - 1) & ~(PAD_ALIGN - 1)

def write_header(f, ino: int, mode: int, uid: int, gid: int, nlink: int,
                 mtime: int, filesize: int, devmaj: int, devmin: int,
                 rdevmaj: int, rdevmin: int, name: bytes) -> None:
    # cpio newc requires null-terminated name; ensure it ends with \0
    if not name.endswith(b'\0'):
        name = name + b'\0'
    namesize = len(name)
    # check field must be 0 (spec)
    check = 0
    hdr = HEADER_FMT.format(
        ino=ino, mode=mode, uid=uid, gid=gid, nlink=nlink,
        mtime=mtime, filesize=filesize,
        devmaj=devmaj, devmin=devmin,
        rdevmaj=rdevmaj, rdevmin=rdevmin,
        namesize=namesize, check=check
    ).encode('ascii')
    f.write(hdr)
    f.write(name)
    # Pad the name field so the file data starts on a 4-byte boundary.
    # The header is 110 bytes (not a multiple of 4), so the padding depends
    # on HEADER_LEN, not on namesize alone.
    name_end = HEADER_LEN + namesize
    pad_len = pad4(name_end) - name_end
    if pad_len > 0:
        f.write(b'\x00' * pad_len)

def write_file_entry(f, name: bytes, data: bytes,
                     ino: int, mtime: int, mode: int = 0o100755) -> None:
    write_header(f, ino, mode=mode, uid=0, gid=0, nlink=1,
                 mtime=mtime, filesize=len(data),
                 devmaj=0, devmin=0, rdevmaj=0, rdevmin=0,
                 name=name)
    f.write(data)
    # Pad file data to a 4-byte boundary
    data_pad = pad4(len(data)) - len(data)
    if data_pad > 0:
        f.write(b'\x00' * data_pad)

def parse_newc(archive: bytes) -> Generator[Tuple[str, bytes, int, int, int], None, None]:
    """Yield (name, data, filesize, mtime, mode) from a newc cpio byte stream."""
    off = 0
    end = len(archive)
    while off + HEADER_LEN <= end:
        if archive[off:off+6] != b'070701':
            raise ValueError(f'bad cpio magic at offset {off}: {archive[off:off+12]!r}')
        def get8(i): return int(archive[off+6+i*8:off+6+(i+1)*8], 16)
        ino, mode, uid, gid, nlink, mtime, filesize = get8(0), get8(1), get8(2), get8(3), get8(4), get8(5), get8(6)
        devmaj, devmin, rdevmaj, rdevmin, namesize, check = get8(7), get8(8), get8(9), get8(10), get8(11), get8(12)
        off += HEADER_LEN
        name = archive[off:off+namesize-1].decode('utf-8', 'replace')
        off += namesize
        off = pad4(off)
        data = archive[off:off+filesize]
        off += filesize
        off = pad4(off)
        yield name, data, filesize, mtime, mode
        if name == 'TRAILER!!!':
            break

def read_cpio_file(path: Path) -> bytes:
    if path.suffix == '.gz':
        with gzip.open(path, 'rb') as gz:
            return gz.read()
    return path.read_bytes()

def write_cpio_file(data: bytes, out: Path, gzip_it: bool = True) -> None:
    if gzip_it:
        with gzip.GzipFile(fileobj=out.open('wb'), mode='wb', mtime=0) as gz:
            gz.write(data)
    else:
        out.write_bytes(data)

def substitute_tokens(text: str, subs: Dict[str, str]) -> str:
    for k, v in subs.items():
        text = text.replace(f'@@{k}@@', v)
    return text

def build_initramfs(guest_dir: Path, base: Optional[Path], out: Path,
                    mode: str, entry: str, defines: Dict[str, str],
                    force: bool, no_gzip: bool) -> None:
    if out.exists() and not force:
        raise FileExistsError(f'output exists: {out} (use --force)')

    subs = {
        'UML4TERMUX_VERSION': os.environ.get('UML4TERMUX_VERSION', '0.1.0'),
        'GUEST_ENTRY': entry,
        'GUEST_MODE': mode,
        **defines,
    }

    # Guest scripts to inject (relative to guest_dir)
    guest_files = ['init', 'docker-init.sh', 'forensic.sh']
    guest_data: Dict[str, bytes] = {}
    for fname in guest_files:
        p = guest_dir / fname
        if not p.is_file():
            print(f'warning: {p} not found, skipping', file=sys.stderr)
            continue
        raw = p.read_text(encoding='utf-8')
        subbed = substitute_tokens(raw, subs)
        guest_data[f'/{fname}'] = subbed.encode('utf-8')

    # Parse base archive if provided
    base_entries: List[Tuple[str, bytes, int, int, int]] = []
    if base and base.is_file():
        raw = read_cpio_file(base)
        for name, data, fsize, mtime, mode in parse_newc(raw):
            if name == 'TRAILER!!!':
                continue
            if name == '.' or name == 'init':
                # skip the base init (we supply our own) and the root dir entry
                continue
            base_entries.append((name, data, fsize, mtime, mode))

    # Write the combined archive
    out.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(delete=False) as tmp:
        tmp_path = Path(tmp.name)
        try:
            with tmp_path.open('wb') as f:
                ino = 1
                # Base entries first (keep their original mode: dirs must stay dirs)
                for name, data, fsize, mtime, mode in base_entries:
                    write_file_entry(f, name.encode('utf-8'), data, ino, mtime, mode)
                    ino += 1
                # Our guest entries (init, forensic.sh, docker-init.sh)
                for name, data in guest_data.items():
                    write_file_entry(f, name.lstrip('/').encode('utf-8'), data, ino, 0, 0o100755)
                    ino += 1
                # Trailer
                write_header(f, ino, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, TRAILER_NAME)
            write_cpio_file(tmp_path.read_bytes(), out, gzip_it=not no_gzip)
        finally:
            tmp_path.unlink(missing_ok=True)

    # Validation: parse back and confirm magic + required entries
    raw = read_cpio_file(out)
    names = {name for name, _, _, _, _ in parse_newc(raw)}
    required = {'init', 'forensic.sh'}
    missing = required - names
    if missing:
        raise RuntimeError(f'built initramfs missing required entries: {missing}')
    print(f'initramfs written: {out} ({len(raw)} bytes, {len(names)} entries)', file=sys.stderr)
    print(f'entries: {sorted(names)[:20]}...' if len(names) > 20 else f'entries: {sorted(names)}', file=sys.stderr)

def main() -> int:
    p = argparse.ArgumentParser(description='build uml4termux guest initramfs')
    p.add_argument('--guest-dir', required=True, type=Path, help='directory with init, forensic.sh, docker-init.sh')
    p.add_argument('--out', required=True, type=Path, help='output .cpio.gz path')
    p.add_argument('--mode', choices=['docker', 'gate'], default='docker', help='guest mode')
    p.add_argument('--base', type=Path, default=None, help='base initramfs .cpio or .cpio.gz (optional)')
    p.add_argument('--entry', default='/docker-init.sh', help='entry point after switch_root')
    p.add_argument('--define', action='append', default=[], help='KEY=VALUE substitutions')
    p.add_argument('--force', action='store_true', help='overwrite output')
    p.add_argument('--no-gzip', action='store_true', help='write raw .cpio instead of .cpio.gz')
    args = p.parse_args()

    defines: Dict[str, str] = {}
    for d in args.define:
        if '=' not in d:
            print(f'error: --define needs KEY=VALUE, got {d!r}', file=sys.stderr)
            return 2
        k, v = d.split('=', 1)
        defines[k] = v

    try:
        build_initramfs(
            guest_dir=args.guest_dir,
            base=args.base,
            out=args.out,
            mode=args.mode,
            entry=args.entry,
            defines=defines,
            force=args.force,
            no_gzip=args.no_gzip,
        )
    except Exception as e:
        import traceback
        traceback.print_exc()
        print(f'error: {e}', file=sys.stderr)
        return 1
    return 0

if __name__ == '__main__':
    sys.exit(main())