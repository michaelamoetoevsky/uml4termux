#!/bin/sh
# Compare two kernel-build artifact ZIPs (or their extracted dirs) and report
# whether the kernel/stub/daemon bytes are identical.
#
#   ci/verify-kernel-reproducible.sh runA.zip runB.zip
#
# Exit 0 = every compared file identical; 1 = a difference (or missing file).
# Part of C5b: KBUILD_BUILD_TIMESTAMP/USER/HOST are pinned in the workflow so
# two builds from the same source produce byte-identical binaries.  Feed this
# script artifacts from two separate workflow runs of the same commit.
#
# SPDX-License-Identifier: GPL-2.0-only
set -eu

if [ "$#" -ne 2 ]; then
	echo "usage: $0 <artifactA.zip|dirA> <artifactB.zip|dirB>" >&2
	exit 64
fi

A="$1"
B="$2"
WORK="${TMPDIR:-/tmp}/repro-verify.$$"
mkdir -p "$WORK/a" "$WORK/b"

unpack() { # $1=archive-or-dir $2=dest
	case "$1" in
	*.zip)
		command -v unzip >/dev/null 2>&1 || {
			echo "unzip not found; extract the archives yourself" >&2
			exit 69
		}
		unzip -o -q "$1" -d "$2"
		;;
	*) cp -R "$1"/. "$2"/ ;;
	esac
}

unpack "$A" "$WORK/a"
unpack "$B" "$WORK/b"

rc=0
for f in linux-bionic stub_exe uml4termuxd; do
	if [ ! -f "$WORK/a/$f" ] || [ ! -f "$WORK/b/$f" ]; then
		printf '%-16s MISSING (a=%s b=%s)\n' "$f" \
			"$([ -f "$WORK/a/$f" ] && echo yes || echo no)" \
			"$([ -f "$WORK/b/$f" ] && echo yes || echo no)"
		rc=1
		continue
	fi
	ha=$(sha256sum "$WORK/a/$f" | cut -d' ' -f1)
	hb=$(sha256sum "$WORK/b/$f" | cut -d' ' -f1)
	if [ "$ha" = "$hb" ]; then
		printf '%-16s IDENTICAL  %s\n' "$f" "$ha"
	else
		printf '%-16s DIFFERS\n  a=%s\n  b=%s\n' "$f" "$ha" "$hb"
		rc=1
	fi
done

rm -rf "$WORK"
[ "$rc" -eq 0 ] && echo "VERDICT=REPRODUCIBLE" || echo "VERDICT=DIFFERENT"
exit "$rc"
