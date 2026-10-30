#!/usr/bin/env bash
#
# Snapshot & resume contract (direction C). Pure file-level tests -- no daemon,
# no guest -- so CI can run them anywhere.
#
# Proves the four things direction C promises:
#   C1  a snapshot is a COW copy plus a metadata record that names the backing
#       image by size, mtime and digest;
#   C2  resume is copy-on-resume: the snapshot is immutable, so the same label
#       can be resumed twice and the two working COWs never touch each other;
#   C3  the list, the removal, and the rotation that keeps only the newest N;
#   C4  a snapshot taken against a different backing image is refused UP FRONT,
#       with the recorded and the observed numbers in the message.
#
# The tests call the library directly (like tests/test-log-rotation.sh) because
# what is under test is the decision logic, not the boot: the daemon side of the
# promise -- that a COW staged here survives the boot instead of being reset -- is
# covered by the device evidence and by the `cow-ensure` parity gate in CI.
#
# SPDX-License-Identifier: GPL-2.0-only
#
# usage: tests/test-snapshot.sh

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/bin/uml4termux"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

[ -x "$BIN" ] || { echo "SKIP: $BIN not executable"; exit 77; }

fails=0
ok()  { printf '  PASS: %s\n' "$1"; }
bad() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }
chk() { # <description> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi
}

export UML4TERMUX_HOME="$work/home"
export UML4TERMUX_STATE_DIR="$work/state"
export UML4TERMUX_RUNTIME="$work/rt"
mkdir -p "$UML4TERMUX_RUNTIME"
# shellcheck source=../lib/common.sh
. "$ROOT/lib/common.sh"
# shellcheck source=../lib/snapshot.sh
. "$ROOT/lib/snapshot.sh"

rt="$UML4TERMUX_RUNTIME"
snaps="$rt/snapshots"

# a base image and a COW with plausible content (snapshot does not interpret it)
img="$work/base.ext4"
head -c 65536 /dev/zero > "$img"
printf 'base-image-payload' >> "$img"
cow="$rt/working.cow"
printf 'MOOO\000\000\000\003' > "$cow"
head -c 8192 /dev/zero >> "$cow"
printf 'guest-writes' >> "$cow"

sha_of() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }

printf '\nC1: a snapshot records what it was taken against\n'
UML4TERMUX_SNAPSHOT_DIGEST=0 uml4termux_snap_create "$rt" first "$img" "$cow" 'Linux 7.2.0-rc4' >/dev/null 2>&1
chk "COW snapshot dibuat"        "yes" "$([ -s "$snaps/first.cow" ] && echo yes || echo no)"
chk "COW snapshot = COW kerja"   "yes" "$(cmp -s "$snaps/first.cow" "$cow" && echo yes || echo no)"
chk "BASE_SIZE dicatat"          "$(stat -c%s "$img")" "$(uml4termux_snap_meta_get "$snaps/first.meta" BASE_SIZE)"
chk "BASE_MTIME dicatat"         "$(stat -c%Y "$img")" "$(uml4termux_snap_meta_get "$snaps/first.meta" BASE_MTIME)"
chk "BASE_SHA256 dicatat"        "$(sha_of "$img")"    "$(uml4termux_snap_meta_get "$snaps/first.meta" BASE_SHA256)"
chk "GUEST_UNAME dicatat"        "Linux 7.2.0-rc4"     "$(uml4termux_snap_meta_get "$snaps/first.meta" GUEST_UNAME)"

printf '\nC4: a different backing image is refused up front, with numbers\n'
uml4termux_snap_verify "$rt" first "$img" >/dev/null 2>&1
chk "image yang sama -> diterima" "0" "$?"

touch -d '2020-01-01 00:00:00' "$img"
out="$(uml4termux_snap_verify "$rt" first "$img" 2>&1)"
rc=$?
chk "mtime berubah -> ditolak" "1" "$rc"
case "$out" in
  *"recorded: size"*) ok "pesan menyebut angka yang dicatat" ;;
  *) bad "pesan tidak menyebut angka: ${out}" ;;
esac
case "$out" in
  *"now     : size"*) ok "pesan menyebut angka yang terlihat sekarang" ;;
  *) bad "pesan tidak menyebut keadaan sekarang" ;;
esac

# restore the identity, then prove the digest path catches same-size same-mtime
touch -d "@$(uml4termux_snap_meta_get "$snaps/first.meta" BASE_MTIME)" "$img"
uml4termux_snap_verify "$rt" first "$img" >/dev/null 2>&1
chk "identitas dipulihkan -> diterima lagi" "0" "$?"

other="$work/other.ext4"
head -c 65536 /dev/zero > "$other"
printf 'fake-image-payload' >> "$other"
touch -r "$img" "$other"
out="$(UML4TERMUX_SNAPSHOT_VERIFY_DIGEST=1 uml4termux_snap_verify "$rt" first "$other" 2>&1)"
chk "image lain (size+mtime dipalsukan) -> ditolak lewat digest" "1" "$?"
case "$out" in
  *"digest mismatch"*) ok "pesan menyebut digest" ;;
  *) bad "pesan tidak menyebut digest: ${out}" ;;
esac

printf '\nC2: copy-on-resume -- the snapshot is immutable\n'
before="$(sha_of "$snaps/first.cow")"
uml4termux_snap_swap_in "$rt" first "$rt/a.cow" >/dev/null 2>&1
uml4termux_snap_swap_in "$rt" first "$rt/b.cow" >/dev/null 2>&1
chk "snapshot tidak berubah setelah dua resume" "$before" "$(sha_of "$snaps/first.cow")"
chk "resume 1 == resume 2 (isi)"                "yes" "$(cmp -s "$rt/a.cow" "$rt/b.cow" && echo yes || echo no)"
chk "COW kerja bukan berkas yang sama"          "yes" "$([ ! "$rt/a.cow" -ef "$rt/b.cow" ] && echo yes || echo no)"
printf 'later-write' >> "$rt/a.cow"
chk "tulis ke resume 1 tidak menyentuh resume 2" "yes" "$([ "$(stat -c%s "$rt/b.cow")" = "$(stat -c%s "$snaps/first.cow")" ] && echo yes || echo no)"
chk "snapshot tetap utuh setelah tulis ke resume 1" "$before" "$(sha_of "$snaps/first.cow")"

printf '\nC3: list, remove, rotation\n'
for i in 1 2 3 4 5 6; do
  cp -f "$cow" "$snaps/s$i.cow"
  printf 'LABEL=s%s\nCREATED_AT=2026-01-0%sT00:00:00Z\n' "$i" "$i" > "$snaps/s$i.meta"
  touch -d "2026-01-0$i 00:00:00" "$snaps/s$i.meta" "$snaps/s$i.cow"
done
uml4termux_snap_rotate "$rt" 3 >/dev/null 2>&1
# rotation orders by mtime, newest first, and keeps the newest <keep>. 'first'
# was taken during this run, so it is the newest of the seven.
chk "2 snapshot terbaru disimpan"   "yes" "$([ -f "$snaps/s6.meta" ] && [ -f "$snaps/s5.meta" ] && echo yes || echo no)"
chk "snapshot paling baru (first) disimpan" "yes" "$([ -f "$snaps/first.meta" ] && echo yes || echo no)"
chk "yang ke-4 termuda (s4) dibuang" "yes" "$([ ! -e "$snaps/s4.meta" ] && echo yes || echo no)"
chk "sisanya dibuang"               "yes" "$([ ! -e "$snaps/s1.meta" ] && [ ! -e "$snaps/s2.meta" ] && [ ! -e "$snaps/s3.meta" ] && echo yes || echo no)"
chk "COW yang dibuang ikut hilang"  "yes" "$([ ! -e "$snaps/s1.cow" ] && echo yes || echo no)"

UML4TERMUX_RUNTIME="$rt" "$BIN" snapshots > "$work/list" 2>&1
chk "snapshots mendaftar s5" "yes" "$(grep -q '^s5' "$work/list" && echo yes || echo no)"

UML4TERMUX_RUNTIME="$rt" "$BIN" snapshot --rm s5 >/dev/null 2>&1
chk "--rm menghapus metadata" "yes" "$([ ! -e "$snaps/s5.meta" ] && echo yes || echo no)"
chk "--rm menghapus COW"      "yes" "$([ ! -e "$snaps/s5.cow" ] && echo yes || echo no)"
UML4TERMUX_RUNTIME="$rt" "$BIN" snapshot --rm s5 >/dev/null 2>&1
chk "menghapus label yang sudah hilang -> gagal" "1" "$?"

printf '\nNegative cases: bad input is refused, not escaped into a path\n'
UML4TERMUX_RUNTIME="$rt" "$BIN" snapshot '../escape' >/dev/null 2>&1
chk "label dengan '/' ditolak" "1" "$?"
UML4TERMUX_RUNTIME="$rt" "$BIN" snapshot >/dev/null 2>&1
chk "label kosong ditolak" "1" "$?"
uml4termux_snap_verify "$rt" nosuch "$img" >/dev/null 2>&1
chk "label yang tidak ada ditolak" "1" "$?"
uml4termux_snap_create "$rt" empty "$img" "$rt/does-not-exist.cow" >/dev/null 2>&1
chk "tanpa COW kerja -> gagal bersih" "1" "$?"
chk "dan tidak meninggalkan berkas separuh" "yes" "$([ ! -e "$snaps/empty.cow" ] && [ ! -e "$snaps/empty.cow.tmp" ] && echo yes || echo no)"

if [ "$fails" -gt 0 ]; then
  printf '\n%d assertion(s) FAILED\n' "$fails"
  exit 1
fi
printf '\nsnapshot contract: all assertions passed\n'
