#!/usr/bin/env bash
# The version a user sees must be the version the release shipped.
#
# Found by running the new `ulter` wrapper: `--version` printed 0.1.0 while VERSION and
# TERMUX_PKG_VERSION both said 0.5.0, because three places carried their own hardcoded
# fallback. A package whose binary disagrees with its own packaging metadata is the kind of
# thing a maintainer notices once and remembers, so the drift is gated instead of fixed
# once and forgotten.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
ROOT=$PWD
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

want="$(tr -d ' \n' < VERSION)"
[ -n "$want" ] && ok "VERSION file reads '$want'" || bad "VERSION file is empty"

got="$(env -u LD_LIBRARY_PATH ./bin/uml4termux --version 2>&1 | head -1)"
case "$got" in
  *"$want"*) ok "uml4termux --version reports $want" ;;
  *) bad "uml4termux --version says '$got', VERSION says '$want'" ;;
esac

if [ -x ./bin/ulter ]; then
  got_u="$(env -u LD_LIBRARY_PATH ./bin/ulter --version 2>&1 | head -1)"
  case "$got_u" in
    *"$want"*) ok "the ulter alias reports $want" ;;
    *) bad "ulter --version says '$got_u'" ;;
  esac
else
  bad "bin/ulter is missing or not executable"
fi

# The fallback literals are allowed to exist (an installed tree has no VERSION file), but
# every one of them must equal VERSION: that is the invariant, and it makes a version bump
# impossible to half-do.
literals=$(grep -rhoE 'UML4TERMUX_VERSION="\${UML4TERMUX_VERSION:-[0-9]+\.[0-9]+\.[0-9]+}"|"UML4TERMUX_VERSION", "[0-9]+\.[0-9]+\.[0-9]+"' \
             lib/ bin/uml4termux 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | sort -u)
if [ -z "$literals" ]; then
  bad "no version fallback found at all (expected one per entry point)"
elif [ "$literals" = "$want" ]; then
  ok "every version fallback equals VERSION ($want)"
else
  bad "version fallbacks disagree with VERSION='$want': $(printf '%s' "$literals" | tr '\n' ' ')"
fi

# The packaging metadata must agree with the tarball that is actually released.
pkg_ver=$(sed -n 's/^TERMUX_PKG_VERSION="\(.*\)"/\1/p' packaging/termux/build.sh | head -1)
[ "$pkg_ver" = "$want" ] && ok "TERMUX_PKG_VERSION matches VERSION ($pkg_ver)" \
  || bad "TERMUX_PKG_VERSION='$pkg_ver' but VERSION='$want'"

echo "  TOTAL pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]