#!/usr/bin/env bash
# Issue #7 dogfood: a guest whose backing image another UML already holds must be
# REFUSED, because otherwise it boots with NO_DISK and exits 0 -- a diskless guest
# that reads as a clean session. Both daemon implementations are exercised, since a
# guard that exists in only one of them is not a guarantee.
#
# The override (UML4TERMUXD_ALLOW_SHARED_IMAGE=1) and the free-image case are pinned
# too, so the check cannot degrade into "always refuses" and stay green.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
ROOT=$PWD
A=${A:-${TMPDIR:-/tmp}/bench-assets}
W=$(mktemp -d)  # no TMPDIR assumption: the GitHub runner has none, Termux has no /tmp
PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); echo "    PASS: $1"; }
bad()   { FAIL=$((FAIL+1)); echo "    FAIL: $1"; }
# grep -c prints 0 and exits 1 on no match; appending "|| echo 0" would print two lines
count() { local n; n=$(grep -ac "$1" "$2" 2>/dev/null); [ -n "$n" ] || n=0; printf '%s' "$n"; }

rm -rf "$W"; mkdir -p "$W"

# The assets only have to EXIST: the guard runs after the config check and before any
# boot, so placeholders keep this test runnable where the real assets are absent (the
# x86 CI runner). On the device the real ones are used.
if [ ! -f "$A/linux-bionic" ] || [ ! -f "$A/stub_exe" ] || [ ! -f "$A/initramfs-alpine.cpio.gz" ]; then
  echo "  assets not present under $A: using placeholders (guard runs before boot)"
  A=$W/assets; mkdir -p "$A"
  for f in linux-bionic stub_exe initramfs-alpine.cpio.gz; do : > "$A/$f"; chmod +x "$A/$f"; done
fi

# One image we lock, one we leave free. 1 MiB sparse is enough: the guard runs before
# any ext4 is parsed, and the free case only has to get past it.
for f in locked.ext4 free.ext4; do
  env -u LD_LIBRARY_PATH python3 -c \
    "import os;fd=os.open('$W/$f',os.O_RDWR|os.O_CREAT,0o644);os.ftruncate(fd,1<<20);os.close(fd)"
done

# The holder is a SEPARATE process because POSIX record locks are per-process: a
# same-process "check" reports the image free no matter who holds it.
env -u LD_LIBRARY_PATH python3 - "$W/locked.ext4" <<'PY' &
import fcntl, os, sys, time
fd = os.open(sys.argv[1], os.O_RDWR)
fcntl.lockf(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
open(sys.argv[1] + ".holder", "w").write(str(os.getpid()))
time.sleep(90)
PY
HOLDER=$!
for _ in $(seq 1 50); do [ -s "$W/locked.ext4.holder" ] && break; sleep 0.2; done
HPID=$(cat "$W/locked.ext4.holder" 2>/dev/null)
echo "  holder pid=$HPID"

C_BIN=${TMPDIR:-/tmp}/ilockd-c
if env -u LD_LIBRARY_PATH cc -O2 -Wall -Wextra -Werror -o "$C_BIN" src/uml4termuxd.c 2>"$W/cc.log"; then
  echo "  C daemon built"
else
  echo "  C daemon build FAILED"; sed 's/^/    | /' "$W/cc.log" | head -6; FAIL=$((FAIL+1)); C_BIN=""
fi
R_BIN=$ROOT/rust/target/release/uml4termux-rs
[ -x "$R_BIN" ] || R_BIN=""

check_impl() {  # $1=binary  $2=label
  local bin=$1 label=$2 rc
  local env_common="UML4TERMUXD_KERNEL=$A/linux-bionic UML4TERMUXD_STUB=$A/stub_exe UML4TERMUXD_INITRAMFS=$A/initramfs-alpine.cpio.gz"
  echo "  --- $label"

  # A: locked image, no override -> exit 2, and the message names the holder pid
  env -u LD_LIBRARY_PATH $env_common UML4TERMUXD_IMAGE=$W/locked.ext4 \
      UML4TERMUX_RUNTIME=$W/$label-a "$bin" daemon > "$W/$label-a.log" 2>&1
  rc=$?
  if [ "$rc" = 2 ] && [ "$(count 'already in use' "$W/$label-a.log")" -ge 1 ] &&
     [ "$(count "pid $HPID" "$W/$label-a.log")" -ge 1 ]; then
    ok "$label: locked image refused (rc=2, holder pid named)"
  else
    bad "$label: locked image NOT refused (rc=$rc, guard msgs=$(count 'already in use' "$W/$label-a.log"))"
  fi

  # B: override -> must get past the guard, proved by the guest-config log line
  env -u LD_LIBRARY_PATH $env_common UML4TERMUXD_IMAGE=$W/locked.ext4 \
      UML4TERMUXD_ALLOW_SHARED_IMAGE=1 UML4TERMUXD_GVPROXY=/bin/true \
      UML4TERMUXD_BESS=$W/none.sock UML4TERMUX_RUNTIME=$W/$label-b \
      timeout 8 "$bin" daemon > "$W/$label-b.log" 2>&1
  if [ "$(count 'already in use' "$W/$label-b.log")" -eq 0 ] &&
     [ "$(count 'guest: kernel=' "$W/$label-b.log")" -ge 1 ]; then
    ok "$label: override bypasses the guard"
  else
    bad "$label: override did not bypass the guard"
  fi

  # C: free image -> the guard must not accuse it
  env -u LD_LIBRARY_PATH $env_common UML4TERMUXD_IMAGE=$W/free.ext4 \
      UML4TERMUXD_GVPROXY=/bin/true UML4TERMUXD_BESS=$W/none.sock \
      UML4TERMUX_RUNTIME=$W/$label-c timeout 8 "$bin" daemon > "$W/$label-c.log" 2>&1
  if [ "$(count 'already in use' "$W/$label-c.log")" -eq 0 ] &&
     [ "$(count 'guest: kernel=' "$W/$label-c.log")" -ge 1 ]; then
    ok "$label: free image is not accused"
  else
    bad "$label: free image wrongly refused"
  fi
}

[ -n "$C_BIN" ] && check_impl "$C_BIN" "c"
if [ -n "$R_BIN" ]; then
  check_impl "$R_BIN" "rust"
else
  echo "  --- rust: SKIP (build rust/target/release/uml4termux-rs to include it)"
fi

kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
echo "  ------"
echo "  TOTAL pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]