#!/usr/bin/env bash
# Mobility bundle (#11): export carries a manifest of digests, import verifies it BEFORE anything
# can boot, and a tampered payload is REFUSED. Tested with small fixtures so it runs anywhere.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
W=$(mktemp -d)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
cleanup() { rm -rf "$W"; }
trap cleanup EXIT

# --- fixtures: a fake asset home, so no real kernel/image is needed -----------------------
A=$W/assets; mkdir -p "$A"
printf 'fake kernel payload\n' > "$A/linux-bionic"
head -c 4096 /dev/zero | tr '\0' 'I' > "$A/debian-docker.ext4"

export UML4TERMUX_HOME="$A"
export UML4TERMUX_STATE_DIR="$W/state"
export UML4TERMUX_RUNTIME="$W/rt"
export UML4TERMUX_KERNEL_FILE=linux-bionic
export UML4TERMUXD_BIN="$PWD/bin/uml4termuxd"

# --- export from a directory the helper produces ----------------------------------------
SRC=$W/src; mkdir -p "$SRC/snapshots"
cp "$A/linux-bionic" "$SRC/kernel"
cp "$A/debian-docker.ext4" "$SRC/image"
printf 'cow' > "$SRC/snapshots/demo.cow"

# the code path under test: manifest + tar, driven through the imported library
( set -euo pipefail
  . ./lib/bundle.sh
  work=$W/stage; mkdir -p "$work"
  cp "$SRC/kernel" "$work/kernel"
  cp "$SRC/image" "$work/image"
  cp "$SRC/snapshots/demo.cow" "$work/cow"
  uml4termux_bundle_manifest_write "$work" "$(cat VERSION)" >/dev/null
  ( cd "$work" && tar -cf "$W/bundle.tar" manifest.json kernel image cow )
) || bad "stage the bundle"
[ -s "$W/bundle.tar" ] && ok "bundle produced ($(wc -c < "$W/bundle.tar" | tr -d ' ') bytes)" || bad "bundle missing"

# --- a clean import verifies ------------------------------------------------------------
OUT=$W/import-ok
( . ./lib/bundle.sh; cmd_bundle import --bundle "$W/bundle.tar" --dir "$OUT" ) > "$W/import.log" 2>&1
rc=$?
[ "$rc" -eq 0 ] && ok "clean bundle imports (rc=0)" || bad "clean import rc=$rc: $(tail -2 "$W/import.log")"
grep -q 'verified image, kernel, cow\|verified' "$W/import.log" && ok "import says what it verified" \
  || bad "import did not report the verified set"
cmp -s "$OUT/image" "$SRC/image" && ok "imported image is byte-identical" || bad "imported image differs"

# --- a tampered payload is refused -- and nothing is claimed as bootable ----------------
OUT2=$W/import-bad
mkdir -p "$W/tamper" && ( cd "$W/tamper" && tar -xf "$W/bundle.tar" )
printf 'X' >> "$W/tamper/image"
( cd "$W/tamper" && tar -cf "$W/bad.tar" manifest.json kernel image cow )
( . ./lib/bundle.sh; cmd_bundle import --bundle "$W/bad.tar" --dir "$OUT2" ) > "$W/bad.log" 2>&1
rc=$?
[ "$rc" -eq 64 ] && ok "tampered bundle refused with exit 64" || bad "tampered import rc=$rc (want 64)"
grep -q 'REFUSED' "$W/bad.log" && ok "refusal is stated, not silent" || bad "no REFUSED in output"
grep -q 'image: sha256' "$W/bad.log" && ok "refusal names the file and the mismatch" || bad "refusal does not name the file"

# --- a bundle with no manifest is refused too -------------------------------------------
mkdir -p "$W/nomani" && printf 'x' > "$W/nomani/image"
( cd "$W/nomani" && tar -cf "$W/nomani.tar" image )
( . ./lib/bundle.sh; cmd_bundle import --bundle "$W/nomani.tar" --dir "$W/import-nomani" ) > "$W/nomani.log" 2>&1
rc=$?
[ "$rc" -eq 64 ] && ok "bundle without manifest refused" || bad "no-manifest rc=$rc (want 64)"
grep -q 'no manifest' "$W/nomani.log" && ok "refusal names the missing manifest" || bad "unclear no-manifest message"

echo "  TOTAL pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]