# packaging/termux/build.sh
# termux-packages build script for uml4termux (scripts/UX layer).
# This is a script-only package (no compilation). It installs the same file set
# as scripts/install.sh into $TERMUX_PREFIX.
#
# Kernel + passt packaging already exists upstream in termux-packages PR #32700
# (packages/linux-kernel-um + packages/passt). This package is the CLI/UX layer
# that will later depend on them:
#   TERMUX_PKG_DEPENDS="linux-kernel-um, passt"
# Once linux-kernel-um and passt are merged and published, uncomment the above.

TERMUX_PKG_HOMEPAGE=https://github.com/michaelamoetoevsky/uml4termux
TERMUX_PKG_DESCRIPTION="Run UML (User-Mode Linux) arm64 + rootless Docker on Termux/Android"
TERMUX_PKG_LICENSE="GPL-2.0-only"
TERMUX_PKG_MAINTAINER="uml4termux maintainers <michaelamoetoevsky@users.noreply.github.com>"
TERMUX_PKG_VERSION="0.3.0"
# TERMUX_PKG_VERSION is normally a literal for the package index.
# The source of truth is the VERSION file in the repo root.
# When submitting to termux-packages, update this to match the release tag.
# The SRCURL uses this version for the GitHub release tarball.

# GitHub release tarball (update owner/repo if the canonical location changes)
TERMUX_PKG_SRCURL=https://github.com/michaelamoetoevsky/uml4termux/archive/refs/tags/v${TERMUX_PKG_VERSION}.tar.gz
# SHA256 placeholder — MUST be filled after the first release!
# Run: sha256sum <tarball> after creating the GitHub release, then update this line.
TERMUX_PKG_SHA256=PLACEHOLDER_FILL_AFTER_FIRST_RELEASE

# Architecture: aarch64 only (UML arm64 + bionic stub requires arm64 host)
TERMUX_PKG_EXCLUDED_ARCHES="arm, i686, x86_64"

# No build dependencies (script-only package)
TERMUX_PKG_BUILD_DEPENDS=""
# Runtime dependencies: will depend on linux-kernel-um and passt once they land
# TERMUX_PKG_DEPENDS="linux-kernel-um, passt"
TERMUX_PKG_DEPENDS=""

# Build in source dir (the tarball extracts to uml4termux-<version>)
TERMUX_PKG_BUILD_IN_SRC=true

# Skip the default configure/make steps — we only install
termux_step_configure() {
  return 0
}

termux_step_make() {
  return 0
}

termux_step_make_install() {
  # Install the same file set as scripts/install.sh --no-symlink
  # The source is in $TERMUX_PKG_SRCDIR (tarball extracted with --strip-components=1)
  local SRCDIR="${TERMUX_PKG_SRCDIR}"
  local DEST_BIN="${TERMUX_PREFIX}/bin"
  local DEST_SHARE="${TERMUX_PREFIX}/share/uml4termux"

  install -Dm755 "${SRCDIR}/bin/uml4termux" "${DEST_SHARE}/bin/uml4termux"
  install -Dm755 "${SRCDIR}/bin/uml4termux" "${DEST_BIN}/uml4termux" || true
  # The bin in $TERMUX_PREFIX/bin should be a symlink into share so the CLI
  # self-locates its libs at ../lib. The install above copies; fix it:
  rm -f "${DEST_BIN}/uml4termux"
  ln -sf "${DEST_SHARE}/bin/uml4termux" "${DEST_BIN}/uml4termux"

  # libs
  for f in "${SRCDIR}/lib"/*.sh; do
    [ -f "${f}" ] && install -Dm644 "${f}" "${DEST_SHARE}/lib/$(basename "${f}")"
  done

  # scripts (python generator + guest scripts)
  [ -f "${SRCDIR}/scripts/build-initramfs.py" ] && \
    install -Dm755 "${SRCDIR}/scripts/build-initramfs.py" "${DEST_SHARE}/scripts/build-initramfs.py"
  for f in "${SRCDIR}/scripts/guest"/*; do
    [ -f "${f}" ] && install -Dm755 "${f}" "${DEST_SHARE}/scripts/guest/$(basename "${f}")"
  done

  # Ensure directories exist (install -D does this)
}

termux_step_post_make_install() {
  # Print the next step for the user after `pkg install uml4termux`
  cat <<'EOF'

======================================================================
uml4termux installed successfully.

Next step: fetch the runtime assets (kernel, disk image, initramfs, gvproxy)

  uml4termux fetch

This downloads ~1.5 GB of verified binaries into ~/.local/share/uml4termux/
(or $UML4TERMUX_HOME). Then run the full Docker test:

  uml4termux docker

See 'uml4termux help' for all commands.
======================================================================
EOF
}

# No license file to install (GPL-2.0-only is in the source repo; termux-packages
# will handle SPDX). If a LICENSE file is added, uncomment:
# termux_step_install_license() {
#   install -Dm644 "${TERMUX_PKG_SRCDIR}/LICENSE" \
#     "${TERMUX_PREFIX}/share/doc/uml4termux/LICENSE"
# }