# Contributing to uml4termux

Thank you for considering a contribution. This project is a deliberately small,
purpose-built tool: run a real Linux kernel (User-Mode Linux, SUBARCH=arm64,
downstream port) as an unprivileged userspace process inside Termux on Android,
so Docker/containers work without root, KVM or a tap device.

## Commit style

- **Conventional Commits** (`feat:`, `fix:`, `docs:`, `refactor:`, `test:`,
  `ci:`, `chore:`, `build:`) — every commit message starts with one of these.
- **One logical change per commit**. If a change touches unrelated files, split it.
- **DCO sign-off**: `git commit -s` adds `Signed-off-by: Name <email>`.
  We require it for every commit (the `git commit --signoff` flag is your friend).
- **Subject line** ≤ 50 chars, imperative mood ("Add …", not "Adds …").
- **Body** (optional but encouraged for non-trivial changes): explain *why*,
  not *what* — the diff shows what.

## Branching & workflow

1. Fork, branch from `main`, name it `type/short-description` (e.g. `feat/gvproxy-api`).
2. Make small, reviewable commits. Squash fixups *before* opening a PR.
3. Run `make ci` locally — it exercises every check the CI will run.
4. Open a PR against `main`. The CI pipeline must pass.
5. Respond to review feedback in new commits (no force-push after review starts).

## What CI validates

`make ci` (and `.github/workflows/ci.yml`) runs:

- `bash -n` on every shell file
- `shellcheck` (severity=warning, documented allowlist in `env` block)
- `python3 -m py_compile` on every `.py` file
- `ci/yamlcheck.py --mode strict --workflow` on every `.github/workflows/*.yml`
- The initramfs generator unit test (`tests/test_build_initramfs.py`) when present
- `make dist` (tarball + SHA256SUMS)
- Evidence schema check when `evidence/*.json` exists
- Metadata consistency (VERSION ↔ CHANGELOG, required files exist)

A green CI run **does not boot UML**. GitHub-hosted runners cannot run the arm64
UML port (see `ci.yml` header). Boot evidence comes from a device and is
validated by `.github/workflows/device-evidence.yml`.

## Asset policy — large binaries are never committed

| Asset | Size | How it arrives | Why not committed |
|-------|------|----------------|-------------------|
| UML kernel (`bin/linux-*`) | ~15–25 MB | CLI downloads from a signed release | Built from the downstream port; not reproducible on CI |
| gvproxy (`gvproxy`) | ~5 MB | CLI downloads from the project release | Platform-specific (aarch64 Android) |
| initramfs / rootfs images | ~10 MB+ | Generated on-device by the CLI | Device-specific, not source |
| Evidence raw logs | unbounded | Produced by device runs | Debug artefacts |

The `.gitignore` covers all of the above. Do not add exceptions.

## Running `ci/local-ci.sh`

```bash
cd uml4termux
bash ci/local-ci.sh
```

It prints a PASS/FAIL/SKIP table with a final verdict and exit code (77 if
everything that ran was SKIP, 1 if any FAIL). It uses only tools present on a
bare Termux device: bash, python3, tar, gzip, sha256sum, git (optional).

## Updating the schema / evidence format

If you add a required field to `evidence/schema.json`:

1. Bump `schema_version` in the schema (e.g. `1.0` → `1.1`).
2. Update `evidence/README.md` with the new field and a one-line description.
3. Run `make evidence-check` locally.
4. CI will validate the new schema in `device-evidence.yml`.

## Releasing

1. Update `VERSION` and `CHANGELOG.md` (Keep-a-Changelog, same day).
2. Commit, push, tag: `git tag v0.x.y`.
3. The `release.yml` workflow builds the tarball, verifies SHA256SUMS, and
   creates a GitHub Release with the CHANGELOG excerpt.

## Questions?

Open an issue or start a discussion. We value clarity over ceremony.