# packaging/termux/README.md

This directory contains the **termux-packages build recipe** for `uml4termux`.

## Package status

- **Package name**: `uml4termux`
- **Type**: script-only (no compilation)
- **Architecture**: `aarch64` only (UML arm64 requires arm64 host)
- **License**: GPL-2.0-only
- **Dependencies**: *pending* — will depend on `linux-kernel-um` and `passt`
  from termux-packages PR #32700 once merged.

The kernel (`linux-kernel-um`) and userspace networking (`passt`) packaging
already exists upstream in termux-packages PR #32700. This package provides the
CLI/UX layer (`uml4termux` command, initramfs builder, guest scripts) that
orchestrates them.

## Building locally (termux-packages workflow)

```sh
# 1. Clone termux-packages
git clone https://github.com/termux/termux-packages
cd termux-packages

# 2. Copy this package directory into the repo
cp -r /path/to/uml4termux/packaging/termux packages/uml4termux

# 3. Fill in the SHA256 in packages/uml4termux/build.sh
#    (after creating a GitHub release tarball and running sha256sum on it)

# 4. Build
./build-package.sh uml4termux

# 5. Install the resulting .deb
pkg install ./uml4termux_*_aarch64.deb
```

## For termux-packages maintainers

When merging this into termux-packages:

1. Place `build.sh` at `packages/uml4termux/build.sh`
2. Update `TERMUX_PKG_VERSION` to the release tag (e.g., `0.1.0`)
3. Replace `TERMUX_PKG_SHA256` with the actual checksum of the GitHub release tarball
4. Once `linux-kernel-um` and `passt` are in the main repo, uncomment:
   ```sh
   TERMUX_PKG_DEPENDS="linux-kernel-um, passt"
   ```
5. Run the standard review/build pipeline.

## Versioning

The source of truth for version is the `VERSION` file in the uml4termux repo root.
Keep `TERMUX_PKG_VERSION` in sync when cutting a release.