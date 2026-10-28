# Packaging — how to install uml4termux on Termux

This document describes the three ways to install `uml4termux`:

1. **From a GitHub release tarball** (today's recommended method)
2. **From source** (git clone + install)
3. **From the official Termux repository** (future — via termux-packages PR / TUR)

---

## 1. Install from a GitHub release (one command)

Pick the latest release from: https://github.com/michaelamoetoevsky/uml4termux/releases

```sh
# Download the release tarball + checksums
curl -L -O https://github.com/michaelamoetoevsky/uml4termux/releases/download/v0.1.0/uml4termux-0.1.0.tar.gz
curl -L -O https://github.com/michaelamoetoevsky/uml4termux/releases/download/v0.1.0/SHA256SUMS

# Verify the tarball
sha256sum -c SHA256SUMS 2>&1 | grep uml4termux-0.1.0.tar.gz

# Extract and install (copy mode = self-contained)
tar -xzf uml4termux-0.1.0.tar.gz
cd uml4termux-0.1.0
./scripts/install.sh --no-symlink

# Verify
uml4termux help
uml4termux doctor --no-assets
```

**What this does:**
- Installs `uml4termux` into `$PREFIX/bin` (default `/data/data/com.termux/files/usr/bin`)
- Installs libraries and scripts into `$PREFIX/share/uml4termux/`
- Does **not** touch your user data directory (`~/.local/share/uml4termux`)

---

## 2. Install from source (git clone)

```sh
git clone https://github.com/michaelamoetoevsky/uml4termux
cd uml4termux

# Development install (symlinks into the repo — edits take effect immediately)
./scripts/install.sh

# Or production install (copies, self-contained)
./scripts/install.sh --no-symlink
```

**Uninstall:**
```sh
./scripts/uninstall.sh              # keeps your data directory
./scripts/uninstall.sh --purge-data # also removes ~/.local/share/uml4termux
```

---

## 3. Future: Install from the official Termux repository

Once the package lands in termux-packages (tracking PR #32700 for `linux-kernel-um` + `passt`):

### Via termux-packages (main repo)
```sh
pkg update
pkg install uml4termux
```

### Via TUR (third-party repo, if not yet in main)
```sh
pkg install tur-repo
pkg install uml4termux
```

Then fetch assets and run:
```sh
uml4termux fetch
uml4termux docker
```

---

## Verifying an installation

After any install method, run the packaging gate (same check CI runs):

```sh
# From the repo root (source install) or extracted tarball
bash packaging/check-install.sh
```

Expected output:
```
[info] Stage 1: Installing into temp prefix (copy mode)...
[ok] Install PASS
[info] Stage 2: Verifying installed file layout...
[ok] File layout verified
[info] Stage 3: Running CLI from temp prefix...
[ok] uml4termux help -> PASS
[ok] uml4termux doctor --no-assets -> PASS
[info] Stage 4: Uninstalling and verifying clean prefix...
[ok] Uninstall PASS — prefix is clean

VERDICT=PASS
```

If `VERDICT=SKIP` appears, the CLI (`bin/uml4termux`) isn't present in the source yet —
the install layout was verified but the CLI execution test was skipped.

---

## Environment variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `PREFIX` | `/data/data/com.termux/files/usr` | Install prefix (Termux default) |
| `UML4TERMUX_HOME` | `~/.local/share/uml4termux` | Runtime assets (kernel, disk, initramfs, gvproxy) |
| `UML4TERMUX_PREFIX` | (auto) | Override CLI's prefix detection |

The installer (`scripts/install.sh`) respects `PREFIX` and never touches `UML4TERMUX_HOME`.

---

## For packagers (termux-packages)

See `packaging/termux/build.sh` for the build recipe and `packaging/termux/README.md`
for maintainer notes. The key points:

- Script-only package, `TERMUX_PKG_BUILD_IN_SRC=true`
- Architecture: `aarch64` only (`TERMUX_PKG_EXCLUDED_ARCHES="arm, i686, x86_64"`)
- `TERMUX_PKG_LICENSE="GPL-2.0-only"`
- `TERMUX_PKG_VERSION` from the repo's `VERSION` file
- `TERMUX_PKG_SRCURL` = GitHub release tarball
- **SHA256 placeholder** — must be filled after the first release
- Depends on `linux-kernel-um` and `passt` (PR #32700) — add to `TERMUX_PKG_DEPENDS` once merged

The build installs the exact same file set as `scripts/install.sh --no-symlink`.