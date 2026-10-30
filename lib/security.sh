#!/bin/sh
# ---------------------------------------------------------------------------
# Release signature verification (direction E2).
#
# The digest pins in lib/common.sh answer "are these the bytes we meant?". A
# signature answers a different question: "did the publisher vouch for them?".
# The pins live in the same tree as the code, so anyone who can write here can
# rewrite both; a signature over SHA256SUMS, verified against a key that is not
# inside the sums file, is what makes the sums attributable.
#
# What this does NOT do, and must not be read as doing:
#   * it does not survive a compromised release key;
#   * it does not make the mirror trustworthy -- it makes one file attributable;
#   * it does not replace the digest pins: both are checked, and the pin stays
#     the authority for "which bytes".
#
# SPDX-License-Identifier: GPL-2.0-only
# ---------------------------------------------------------------------------

# The repository key. Overridable so a fork (or CI) can verify with its own.
uml4termux_release_pubkey() {
  if [ -n "${UML4TERMUX_RELEASE_PUBKEY:-}" ]; then
    printf '%s' "${UML4TERMUX_RELEASE_PUBKEY}"
    return 0
  fi
  printf '%s' "${UML4TERMUX_ROOT}/packaging/keys/release.pub.pem"
}

uml4termux_signature_required() { [ "${UML4TERMUX_REQUIRE_SIGNATURE:-0}" = "1" ]; }

uml4termux_openssl() {
  command -v openssl >/dev/null 2>&1 || return 1
  printf '%s' "$(command -v openssl)"
}

# sha256 of the DER-encoded public key: a short, comparable identity for a key,
# so an error message can say *which* key rejected the file.
uml4termux_key_fingerprint() { # <pubkey>
  local pub="$1" ossl
  ossl="$(uml4termux_openssl)" || return 1
  [ -r "${pub}" ] || return 1
  "${ossl}" pkey -pubin -in "${pub}" -outform DER 2>/dev/null \
    | sha256sum | cut -c1-16
}

# uml4termux_verify_signature <file> <sigfile> <pubkey>
# Returns 0 only when the signature is valid for this exact file. Every other
# outcome fails closed with a message that names the file, the key and why.
uml4termux_verify_signature() {
  local file="$1" sig="$2" pub="$3" ossl fp out

  [ -r "${file}" ] || { err "signature check: ${file} is missing"; return 1; }
  [ -r "${sig}" ] || { err "signature check: ${sig} is missing"; return 1; }
  if [ ! -r "${pub}" ]; then
    err "signature check: no public key at ${pub}"
    err "  set UML4TERMUX_RELEASE_PUBKEY, or drop UML4TERMUX_REQUIRE_SIGNATURE=1 to skip signing"
    return 1
  fi
  if ! ossl="$(uml4termux_openssl)"; then
    # No openssl: verification is impossible, and pretending otherwise is exactly
    # the failure mode this feature exists to prevent.
    err "signature check: openssl is not installed, so ${file} cannot be verified"
    err "  refusing rather than trusting an unverified file (install openssl)"
    return 1
  fi
  fp="$(uml4termux_key_fingerprint "${pub}")"

  if uml4termux_is_dry_run; then
    uml4termux_print_cmd openssl dgst -sha256 -verify "${pub}" -signature "${sig}" "${file}"
    return 0
  fi

  # Ed25519 needs pkeyutl -rawin; RSA and ECDSA go through dgst.
  if "${ossl}" pkey -pubin -in "${pub}" -noout -text 2>/dev/null | head -2 | grep -qi 'ed25519'; then
    out="$("${ossl}" pkeyutl -verify -pubin -inkey "${pub}" -rawin -in "${file}" -sigfile "${sig}" 2>&1)"
  else
    out="$("${ossl}" dgst -sha256 -verify "${pub}" -signature "${sig}" "${file}" 2>&1)"
  fi
  case "${out}" in
    *"Verified OK"*) return 0 ;;
  esac
  err "SIGNATURE MISMATCH for ${file}"
  err "  key         ${pub} (fingerprint ${fp:-unknown})"
  err "  signature   ${sig}"
  err "  openssl     ${out%%$'\n'*}"
  err "  the digest can still match while this fails: it means the bytes are not"
  err "  the ones this key signed. Refusing."
  return 1
}