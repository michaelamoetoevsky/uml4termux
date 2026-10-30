#!/usr/bin/env bash
#
# Log rotation contract (direction G4): the runtime keeps its own bounded logs
# without svlogd. Pure file-level tests -- no daemon, no guest, so CI can run it.
#
# Proves: a small file is left alone, a big one is rotated, the current file is
# emptied IN PLACE (so a writer holding it open keeps writing to it), the
# generation chain shifts, and only <keep> generations survive.
#
# SPDX-License-Identifier: GPL-2.0-only
#
# usage: tests/test-log-rotation.sh

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/bin/uml4termux"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

[ -x "$BIN" ] || { echo "SKIP: $BIN not executable"; exit 77; }

fails=0
ok()  { printf '  PASS: %s\n' "$1"; }
bad() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (harap '$2', dapat '$3')"; fi }

# Source the library under test directly (no CLI dispatch needed for the units).
# shellcheck source=../lib/common.sh
. "$ROOT/lib/common.sh"
# shellcheck source=../lib/logs.sh
. "$ROOT/lib/logs.sh"

export NO_COLOR=1
UML4TERMUX_DRY_RUN=0

size() { wc -c < "$1" 2>/dev/null | tr -d ' ' || echo 0; }
exists() { [ -e "$1" ] && echo 1 || echo 0; }
fill() { # <file> <bytes>
  head -c "$2" /dev/zero | tr '\0' 'x' > "$1"
}

echo "== berkas kecil tidak disentuh =="
small="$work/small.log"; fill "$small" 1000
check "aksi berkas kecil" "kept" "$(uml4termux_log_rotate_file "$small" 1000000 3)"
check "isi berkas kecil utuh" "1000" "$(size "$small")"
check "tidak ada generasi" "0" "$(exists "$small.1")"

echo "== berkas besar dirotasi =="
big="$work/big.log"; fill "$big" 300000
check "aksi berkas besar" "rotated" "$(uml4termux_log_rotate_file "$big" 100000 3)"
check "berkas aktif dikosongkan di tempat" "0" "$(size "$big")"
check "generasi .1 berisi isi lama" "300000" "$(size "$big.1")"

echo "== rantai generasi bergeser, retensi dijaga =="
fill "$big" 300000; uml4termux_log_rotate_file "$big" 100000 3 >/dev/null
fill "$big" 300000; uml4termux_log_rotate_file "$big" 100000 3 >/dev/null
fill "$big" 300000; uml4termux_log_rotate_file "$big" 100000 3 >/dev/null
check "generasi .1 ada" "300000" "$(size "$big.1")"
check "generasi .2 ada" "300000" "$(size "$big.2")"
check "generasi .3 ada" "300000" "$(size "$big.3")"
check "generasi .4 TIDAK dibuat (keep=3)" "0" "$(exists "$big.4")"

echo "== inode tidak berubah (penulis tidak kehilangan berkasnya) =="
ino_before="$(stat -c '%i' "$big")"
fill "$big" 300000
uml4termux_log_rotate_file "$big" 100000 3 >/dev/null
check "inode sama setelah rotasi" "$ino_before" "$(stat -c '%i' "$big")"

echo "== rotate pada direktori runtime (tanpa daemon) =="
rt="$work/rt"; mkdir -p "$rt"
fill "$rt/daemon.log" 200000
fill "$rt/uml-console.log" 500
env UML4TERMUX_RUNTIME="$rt" "$BIN" rotate --max-bytes 100000 --keep 2 >"$work/out" 2>&1
check "rotate rc" "0" "$?"
check "daemon.log dirotasi" "200000" "$(size "$rt/daemon.log.1")"
check "console log kecil dibiarkan" "0" "$(exists "$rt/uml-console.log.1")"
grep -q 'daemon.log' "$work/out" && ok "rotate melaporkan berkas" || bad "keluaran rotate: $(cat "$work/out")"

echo "== total ukuran dilaporkan =="
total="$(uml4termux_log_total "$rt")"
[ "$total" -ge 500 ] && ok "uml4termux_log_total mengembalikan angka ($total)" || bad "total=$total"

echo "== dry-run tidak mengubah apa pun =="
dry="$work/dry.log"; fill "$dry" 200000
out="$(UML4TERMUX_DRY_RUN=1 uml4termux_log_rotate_file "$dry" 100000 3)"
# In dry-run the helper prints the plan AND reports the action it would take.
case "$out" in
  *"+ (rotate"*"rotated"*) ok "dry-run melaporkan rencana + aksi" ;;
  *) bad "dry-run: $out" ;;
esac
check "dry-run tidak mengubah isi" "200000" "$(size "$dry")"

echo
if [ "$fails" -eq 0 ]; then
  echo "log rotation: OK"
else
  echo "log rotation: $fails kegagalan"
  exit 1
fi
