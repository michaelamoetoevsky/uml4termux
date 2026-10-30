#!/usr/bin/env bash
#
# Release signature contract (direction E2). Needs openssl and no network: the
# keys are generated here, the "release" is a directory of files.
#
# Proves the promise in docs/NEXT-STEPS.md §E2: an asset whose DIGEST matches
# while the signature does not must be refused -- the digest can be right and the
# file still not be the one the publisher signed. Also proves the fail-closed
# paths: unsigned sums when a signature is required, and a missing or unreadable
# key, are refusals rather than warnings.
#
# usage: tests/test-signature.sh
# SPDX-License-Identifier: GPL-2.0-only
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/bin/uml4termux"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

command -v openssl >/dev/null 2>&1 || { echo "SKIP: openssl not installed"; exit 77; }
[ -x "$BIN" ] || { echo "SKIP: $BIN not executable"; exit 77; }

fails=0
ok()  { printf '  PASS: %s\n' "$1"; }
bad() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }
chk() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi; }
has() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1 (no '$2' in: $(printf '%s' "$3" | head -c 200))" ;; esac; }

# two independent keys: the second one stands in for an attacker's key
openssl ecparam -name prime256v1 -genkey -noout -out "$work/keyA.pem" 2>/dev/null
openssl ecparam -name prime256v1 -genkey -noout -out "$work/keyB.pem" 2>/dev/null
openssl pkey -in "$work/keyA.pem" -pubout -out "$work/pubA.pem" 2>/dev/null
openssl pkey -in "$work/keyB.pem" -pubout -out "$work/pubB.pem" 2>/dev/null
[ -s "$work/pubA.pem" ] && [ -s "$work/pubB.pem" ] || { echo "SKIP: openssl could not generate keys"; exit 77; }

# a "release": one asset plus its sums
printf 'the asset bytes\n' > "$work/asset.bin"
( cd "$work" && sha256sum asset.bin > SHA256SUMS )
openssl dgst -sha256 -sign "$work/keyA.pem" -out "$work/SHA256SUMS.sig" "$work/SHA256SUMS"

export UML4TERMUX_ROOT="$ROOT"
# shellcheck source=../lib/common.sh
. "$ROOT/lib/common.sh"
# shellcheck source=../lib/security.sh
. "$ROOT/lib/security.sh"

printf '\nE2.1: a good signature is accepted\n'
uml4termux_verify_signature "$work/SHA256SUMS" "$work/SHA256SUMS.sig" "$work/pubA.pem" >/dev/null 2>&1
chk "tanda tangan benar -> diterima" "0" "$?"
fp="$(uml4termux_key_fingerprint "$work/pubA.pem")"
[ -n "$fp" ] && ok "fingerprint kunci terhitung (${fp})" || bad "fingerprint kosong"

printf '\nE2.2: the digest matching is not enough when the signature does not\n'
# The sums still name the correct asset digest; only the signature is wrong.
out="$(uml4termux_verify_signature "$work/SHA256SUMS" "$work/SHA256SUMS.sig" "$work/pubB.pem" 2>&1)"
chk "kunci berbeda -> ditolak" "1" "$?"
has "pesan menyebut SIGNATURE MISMATCH" "SIGNATURE MISMATCH" "$out"
has "pesan menyebut kunci yang dipakai" "pubB.pem" "$out"
has "pesan menjelaskan mengapa digest bisa tetap cocok" "digest can still match" "$out"

# Signature valid, but the sums were edited afterwards (digest now differs).
printf 'tampered\n' > "$work/asset.bin"
( cd "$work" && sha256sum asset.bin > SHA256SUMS )
out="$(uml4termux_verify_signature "$work/SHA256SUMS" "$work/SHA256SUMS.sig" "$work/pubA.pem" 2>&1)"
chk "SUMS diubah sesudah ditandatangani -> ditolak" "1" "$?"
has "dan alasannya tetap MISMATCH" "SIGNATURE MISMATCH" "$out"

printf '\nE2.3: unsigned or unverifiable input fails closed\n'
out="$(uml4termux_verify_signature "$work/SHA256SUMS" "$work/missing.sig" "$work/pubA.pem" 2>&1)"
chk "tanda tangan hilang -> ditolak" "1" "$?"
has "pesan menyebut berkas tanda tangan" "missing.sig is missing" "$out"
out="$(uml4termux_verify_signature "$work/SHA256SUMS" "$work/SHA256SUMS.sig" "$work/no-such-key.pem" 2>&1)"
chk "kunci publik tidak ada -> ditolak" "1" "$?"
has "pesan menyarankan UML4TERMUX_RELEASE_PUBKEY" "UML4TERMUX_RELEASE_PUBKEY" "$out"

printf '\nE2.4: fetch refuses end to end, not just the library\n'
# E2.2 left the sums edited and the signature stale on purpose; sign the current
# pair fresh so the positive case below tests a genuinely signed release.
( cd "$work" && sha256sum asset.bin > SHA256SUMS \
    && openssl dgst -sha256 -sign keyA.pem -out SHA256SUMS.sig SHA256SUMS )
home="$work/home"
mkdir -p "$home"
UML4TERMUX_HOME="$home" UML4TERMUX_RELEASE_PUBKEY="$work/pubA.pem" \
  "$BIN" fetch --only sums --sums-url "file://$work/SHA256SUMS" >"$work/fetch-ok.log" 2>&1
chk "fetch dengan tanda tangan benar -> rc 0" "0" "$?"
UML4TERMUX_HOME="$home" UML4TERMUX_RELEASE_PUBKEY="$work/pubB.pem" \
  "$BIN" fetch --only sums --sums-url "file://$work/SHA256SUMS" >"$work/fetch-bad.log" 2>&1
rc_bad=$?
[ "${rc_bad}" -ne 0 ] && ok "fetch dengan kunci salah -> rc ${rc_bad}" || bad "fetch menerima tanda tangan yang salah"
grep -q 'SIGNATURE MISMATCH\|does not verify' "$work/fetch-bad.log" \
  && ok "pesan fetch menyebut sebabnya" || bad "pesan fetch tidak menjelaskan"
UML4TERMUX_HOME="$home" UML4TERMUX_REQUIRE_SIGNATURE=1 \
  "$BIN" fetch --only sums --sums-url "file://$work/only-sums.txt" >"$work/fetch-unsigned.log" 2>&1
( cd "$work" && cp SHA256SUMS only-sums.txt )
UML4TERMUX_HOME="$home" UML4TERMUX_REQUIRE_SIGNATURE=1 \
  "$BIN" fetch --only sums --sums-url "file://$work/only-sums.txt" >"$work/fetch-unsigned.log" 2>&1
rc_req=$?
[ "${rc_req}" -ne 0 ] && ok "UML4TERMUX_REQUIRE_SIGNATURE=1 + tanpa tanda tangan -> rc ${rc_req}" \
  || bad "sums tanpa tanda tangan diterima padahal wajib bertanda tangan"
has "pesannya menyebut UML4TERMUX_REQUIRE_SIGNATURE" "UML4TERMUX_REQUIRE_SIGNATURE" "$(cat "$work/fetch-unsigned.log")"

if [ "$fails" -gt 0 ]; then
  printf '\n%d assertion(s) FAILED\n' "$fails"
  exit 1
fi
printf '\nsignature contract: all assertions passed\n'
