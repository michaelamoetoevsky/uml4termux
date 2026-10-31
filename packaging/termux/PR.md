# Submission notes for `termux-packages`

Prepared for a PR against [`termux/termux-packages`](https://github.com/termux/termux-packages);
**not submitted**. Opening the PR is an external, public action on someone else's
repository, so it waits for the repository owner's explicit go-ahead. Everything a
reviewer needs is in this directory.

## What the package is

A **script-only** package: it installs the CLI, the shell library, the guest scripts
and the status panel into `$PREFIX/share/uml4termux`, plus the `uml4termux` symlink
in `$PREFIX/bin`. It compiles nothing.

The binaries it needs at runtime are **release assets**, not package files: the UML
kernel, `stub_exe`, the Debian+Docker disk image, the base initramfs, gvproxy and
`uml4termuxd`. `uml4termux fetch` downloads them and verifies each digest against
the pins compiled into the CLI (fail-closed; a `SHA256SUMS` whose signature does not
validate against `packaging/keys/release.pub.pem` is rejected rather than trusted).
Shipping multi-hundred-megabyte assets inside a Termux package would be the wrong
trade; shipping them as verified release assets keeps the package small and the
update path honest.

The kernel and `passt` packaging already exists upstream in
[`termux-packages` PR #32700](https://github.com/termux/termux-packages/pull/32700)
(`packages/linux-kernel-um`, `packages/passt`). Once those land and are published,
`TERMUX_PKG_DEPENDS` can name them and the fetch step for the kernel can be
dropped. Until then this package depends on nothing and says so.

## Fields a reviewer will check

| Field | Value | Where it comes from |
|---|---|---|
| `TERMUX_PKG_VERSION` | `0.5.0` | the repo's `VERSION` file, via the release tag |
| `TERMUX_PKG_SRCURL` | `.../archive/refs/tags/v0.5.0.tar.gz` | the GitHub release |
| `TERMUX_PKG_SHA256` | `c8e7820b7630e40ef2278cfee5c4d1dd959f8c772a0611c88447833ed5d12ee2` | the release asset's own digest; `make dist` is byte-reproducible, so the tarball is not a moving target |
| `TERMUX_PKG_EXCLUDED_ARCHES` | `arm, i686, x86_64` | UML arm64 plus the bionic stub require an aarch64 host |
| `TERMUX_PKG_DEPENDS` | *(empty, deliberately)* | see above |
| `TERMUX_PKG_BUILD_IN_SRC` | `true` | the tarball extracts to `uml4termux-<version>` |

`termux_step_make_install` delegates to this repository's own installer
(`scripts/install.sh --prefix "$TERMUX_PREFIX" --no-symlink`) instead of repeating a
file list. The list it used to carry had already drifted from the installer's, and a
second list is a second thing to forget.

## How it was verified before asking

* `scripts/install.sh --prefix "$PWD/prefix" --no-symlink` installs and verifies the
  same file set the package installs: CLI, 15 library files, the initramfs builder,
  the guest scripts, and the panel.
* `ci/local-ci.sh` (22 gates) and the GitHub workflows (`ci`, `device-evidence`) are
  green on the tagged tree.
* `uml4termux doctor` and `uml4termux fetch` were run end to end on Termux aarch64
  (Android 16): the pinned assets verify, and a guest boots with Docker inside.
* Reproducibility: `make dist` produces a byte-identical tarball, which is what
  makes a fixed `TERMUX_PKG_SHA256` reasonable.

## What the reviewer should run

```sh
# in the package directory of a termux-packages checkout
./build-package.sh -a aarch64 uml4termux
# then, in Termux:
pkg install ./output/uml4termux_0.5.0_aarch64.deb
uml4termux doctor      # reports host capabilities, assets and risks; never boots
uml4termux fetch       # downloads and verifies the pinned assets
uml4termux up --name demo --image "$HOME/.local/share/uml4termux/debian-docker.ext4"
uml4termux status --name demo
```

## Honest limits to state in the PR body

* The guest runs Docker as **guest root inside the guest**. Guest root is not Android
  root (the UML process is an ordinary Termux app process), but it is not Docker
  "rootless mode" either; `docs/THREAT-MODEL.md` says so in the same table as the
  things the project does protect.
* 32-bit container images need qemu-user + binfmt emulation (`CONFIG_COMPAT` is off).
* First boot pulls the container images it needs; expect the first `docker run` in a
  fresh guest to be network-bound.
* The status panel is read-only by design: the daemon's HTTP endpoint is
  unauthenticated, so the page shows state and prints the command to run.