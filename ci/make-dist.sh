#!/usr/bin/env bash
# ci/make-dist.sh -- build the release tarball + SHA256SUMS.
#
# Shared by `make dist`, ci/local-ci.sh and .github/workflows/{ci,release}.yml so
# that the artifact is produced identically everywhere.
#
# Produces (paths relative to the repo root, or to --outdir):
#   dist/uml4termux-<VERSION>.tar.gz
#   dist/SHA256SUMS                 ("<sha256>  <filename>", sha256sum -c compatible)
#
# The tarball contains a single top-level directory uml4termux-<VERSION>/ with
# whatever source is present. Large binary assets (kernels, rootfs images,
# gvproxy) are never packaged: they are fetched by the CLI from .gitignore'd
# paths, so a dist tarball stays a few tens of kilobytes.
#
# Reproducibility: SOURCE_DATE_EPOCH, when set, is stamped onto every member
# (GNU tar --mtime/--clamp-mtime), which makes the tarball byte-reproducible
# across machines. Ownership is normalised to 0/0 and symlinks are dereferenced
# so the archive survives extraction by an unprivileged Termux user.
#
# Usage: ci/make-dist.sh [--outdir DIR] [--quiet]
# Exit:  0 ok, 1 failure, 77 prerequisite missing (no VERSION file).
set -uo pipefail

# Allow --help/-h to show usage and exit 0
case "${1:-}" in
  -h|--help)
    sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
esac

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
outdir="$root/dist"
quiet=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --outdir) outdir=${2:?--outdir needs a value}; shift 2 ;;
    --outdir=*) outdir=${1#--outdir=}; shift ;;
    --quiet) quiet=1; shift ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "make-dist: unknown argument: $1" >&2; exit 2 ;;
  esac
done

cd "$root" || exit 1

say() { [ "$quiet" -eq 1 ] || printf '%s\n' "$*"; }

if [ ! -f VERSION ]; then
  echo "make-dist: VERSION file missing -- nothing to package (SKIP)" >&2
  exit 77
fi

version=$(tr -d ' \t\r\n' < VERSION)
if [ -z "$version" ]; then
  echo "make-dist: VERSION is empty" >&2
  exit 1
fi

pkg="uml4termux-$version"
stage="$outdir/.stage"
pkgdir="$stage/$pkg"

say "make-dist: version=$version outdir=$outdir"

rm -rf "$stage"
mkdir -p "$pkgdir" "$outdir" || exit 1

# --- collect the source tree ------------------------------------------------
# tar-pipe (rather than cp -a/rsync) because it handles permissions and
# symlinks identically on Android, Linux and macOS, and needs no extra tool.
tar -chf - \
  --exclude='./.git' \
  --exclude='./.git/*' \
  --exclude='./.uml' \
  --exclude='./.uml/*' \
  --exclude='./build' \
  --exclude='./build/*' \
  --exclude='./dist' \
  --exclude='./dist/*' \
  --exclude='./tmp' \
  --exclude='./node_modules' \
  --exclude='./__pycache__' \
  --exclude='*/__pycache__' \
  --exclude='*.pyc' \
  --exclude='*.log' \
  --exclude='*.raw.log' \
  --exclude='*.cpio' \
  --exclude='*.cpio.gz' \
  --exclude='*.ext4' \
  --exclude='./gvproxy' \
  --exclude='./bin/linux*' \
  -C "$root" . 2>/dev/null | tar -xf - -C "$pkgdir" || {
    echo "make-dist: failed to stage the source tree" >&2
    rm -rf "$stage"
    exit 1
  }

if [ ! -e "$pkgdir/VERSION" ]; then
  echo "make-dist: staging produced no VERSION file -- aborting" >&2
  rm -rf "$stage"
  exit 1
fi

# --- tarball ----------------------------------------------------------------
tarball="$outdir/$pkg.tar.gz"
rm -f "$tarball"

# Deterministic metadata, so the same commit yields the same tarball
# everywhere (Termux device and GitHub runner alike).
#   epoch: SOURCE_DATE_EPOCH, else the commit time, else 0. Never a file mtime:
#          a fresh checkout stamps "now", which made the two builds differ.
#   --sort=name: readdir order differs between filesystems.
#   --mode: a checkout under umask 077 yields 600/700 members while a runner
#          checkout yields 644/755, and tar records the mode bits.
#   --format=gnu + numeric 0/0: pins the header layout and identity.
if [ -n "${SOURCE_DATE_EPOCH:-}" ]; then
  epoch="$SOURCE_DATE_EPOCH"
elif command -v git >/dev/null 2>&1 && git rev-parse --git-dir >/dev/null 2>&1; then
  epoch=$(git log -1 --format=%ct 2>/dev/null || echo 0)
else
  epoch=0
fi
[ -n "$epoch" ] || epoch=0
echo "make-dist: SOURCE_DATE_EPOCH=$epoch"

# gzip -n keeps the timestamp/name out of the gzip header; without it the
# archive changes on every build even when the tar stream is identical.
tar --sort=name --format=gnu \
  --mtime="@$epoch" \
  --mode='u+rw,go=rX' \
  --owner=0 --group=0 --numeric-owner \
  -cf - -C "$stage" "$pkg" | gzip -9n > "$tarball" || {
    echo "make-dist: tar/gzip failed" >&2
    rm -rf "$stage"
    exit 1
  }
[ -s "$tarball" ] || {
  echo "make-dist: tarball is empty" >&2
  rm -rf "$stage"
  exit 1
}

rm -rf "$stage"

# --- checksums --------------------------------------------------------------
# Run from $outdir so the recorded names are bare filenames: this makes
# `sha256sum -c SHA256SUMS` work from any directory that holds the artifacts.
if command -v sha256sum >/dev/null 2>&1; then
  ( cd "$outdir" && sha256sum "$pkg.tar.gz" > SHA256SUMS ) || {
    echo "make-dist: sha256sum failed" >&2
    exit 1
  }
elif command -v shasum >/dev/null 2>&1; then
  ( cd "$outdir" && shasum -a 256 "$pkg.tar.gz" > SHA256SUMS ) || {
    echo "make-dist: shasum failed" >&2
    exit 1
  }
else
  echo "make-dist: neither sha256sum nor shasum is available" >&2
  exit 1
fi

# Verify our own output before claiming success.
( cd "$outdir" && sha256sum -c SHA256SUMS >/dev/null 2>&1 ) || {
  echo "make-dist: SHA256SUMS does not verify against the tarball" >&2
  exit 1
}

say "make-dist: wrote $tarball"
say "make-dist: wrote $outdir/SHA256SUMS"
cat "$outdir/SHA256SUMS"
exit 0
