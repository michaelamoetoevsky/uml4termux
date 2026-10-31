#!/usr/bin/env python3
"""Prove the guard before proposing it: does an F_SETLK on an image really tell a
second boot apart from the first?

Three things are checked, because two of them are the kind of thing a reviewer
catches immediately if the patch author did not:

  1. with no holder, the probe says "free";
  2. with a holder IN ANOTHER PROCESS, it says "held";
  3. with a holder in the SAME process, it still says "free" -- POSIX record locks
     are per-process, so a self-test that does not fork proves nothing.
"""
import fcntl
import os
import pathlib
import subprocess
import sys
import tempfile


def image_is_held(path: str) -> bool:
    """True when another process holds UML's exclusive F_SETLK on this image."""
    try:
        fd = os.open(path, os.O_RDWR)
    except OSError:
        return False
    try:
        fcntl.lockf(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return True
    finally:
        try:
            fcntl.lockf(fd, fcntl.LOCK_UN)
        except OSError:
            pass
        os.close(fd)
    return False


HOLDER = """import fcntl, os, sys, time
fd = os.open(sys.argv[1], os.O_RDWR)
fcntl.lockf(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
print("holding", flush=True)
time.sleep(float(sys.argv[2]))
"""


def main() -> int:
    fails = 0
    with tempfile.TemporaryDirectory() as tmp:
        img = pathlib.Path(tmp) / "image.ext4"
        img.write_bytes(b"\0" * 4096)

        for label, expect in (("no holder", False),):
            got = image_is_held(str(img))
            print(f"  {'PASS' if got == expect else 'FAIL'}: {label} -> held={got}")
            fails += got != expect

        # a holder in another process: this is the case a second boot hits
        holder = subprocess.Popen([sys.executable, "-c", HOLDER, str(img), "10"],
                                  stdout=subprocess.PIPE, text=True)
        assert holder.stdout is not None  # stdout=PIPE above
        holder.stdout.readline()
        got = image_is_held(str(img))
        print(f"  {'PASS' if got else 'FAIL'}: holder in another process -> held={got}")
        fails += not got

        # POSIX record locks are per-process, so a same-process re-lock succeeds.
        # That is worth pinning: a "self test" that locks the image in the same
        # process it probes would report "free" no matter who holds it, which is how
        # a broken guard passes its own test.
        other = pathlib.Path(tmp) / "another.ext4"
        other.write_bytes(b"\0" * 4096)
        fd = os.open(str(other), os.O_RDWR)
        fcntl.lockf(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        try:
            fcntl.lockf(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            same = True
        except OSError:
            same = False
        fcntl.lockf(fd, fcntl.LOCK_UN)
        os.close(fd)
        print(f"  {'PASS' if same else 'FAIL'}: same-process re-lock succeeds (per-process semantics)")
        fails += not same

        holder.terminate()
        holder.wait()
        got = image_is_held(str(img))
        print(f"  {'PASS' if not got else 'FAIL'}: holder gone -> held={got}")
        fails += got

    print(f"guard test: {fails} failure(s)")
    return 1 if fails else 0


if __name__ == "__main__":
    raise SystemExit(main())
