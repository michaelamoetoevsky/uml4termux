# CI, evidence and releases

The organising constraint: **the interesting claims cannot be checked by GitHub
Actions.** A GitHub runner is x86_64 Linux in a container; this project's claims
are about booting an arm64 kernel inside the Termux sandbox on an Android device
with an app seccomp filter and `CapEff=0`. No runner has any of that. So CI is
split in two, and the split is explicit rather than pretending a runner proves
something it cannot.

| | Runs on | Proves |
|---|---|---|
| **CI checks** | GitHub runners (x86_64 Linux) | the repo is well-formed: static checks, packaging sanity, evidence schema validation, release manifest integrity |
| **Device gate** | a real Android/Termux phone, run by a human or a self-hosted runner | the kernel boots, Docker runs, ports forward — i.e. every claim in [../README.md](../README.md) |

> Naming note: the workflow files themselves (under `.github/`), the launcher and
> the probe scripts are owned by the harness side of the project. This document
> specifies the *contract* those pieces must satisfy; it does not define their
> contents or their exact flags.

---

## 1. What runs in CI

### 1.1 Static checks

Cheap, offline, deterministic — they must never need a device, a network or a
kernel binary.

- **Markdown link check** over `README.md`, `docs/**` and `evidence/**`: every
  local markdown link and every relative file reference resolves to a file that
  exists in the tree. Links to files owned by other parts of the project
  (`bin/`, `lib/`, `scripts/`, `packaging/`, `.github/`) are written as code spans,
  not links, precisely so this check can stay strict.
- **Documentation claim hygiene.** Docs are supposed to separate measured fact
  from everything else. The check that enforces the convention is a grep for the
  headings and markers the docs use: `## Verified / not verified` must exist in
  `README.md`, and no doc may contain a bare "verified" claim outside a
  verified-context section. (This is a convention check, not a truth check — see
  §2.)
- **Shell static analysis** over `bin/`, `lib/` and `scripts/` (`shellcheck`,
  `sh -n` for POSIX parsing).
- **JSON/YAML validation** for `evidence/schema.json` (must itself be valid JSON
  Schema) and for any workflow/manifest files.
- **Forbidden-construct scan.** The traps in
  [FORENSICS.md](FORENSICS.md) are cheap to grep for and expensive to hit on a
  phone: a bare `exit` in a guest script, a missing `poweroff -f`, a missing
  `stub_exe=`, a console spec other than `con=null con0=null,fd:1` or
  `con=null con0=fd:0,fd:1`, and an unconditional
  `ip addr add 127.0.0.1/8 dev lo`. CI should fail on these patterns.
- **Spelling/structure sweep** on docs (heading levels, no duplicate top-level
  headings, table pipe escaping).

### 1.2 Packaging checks

- The packaging definition parses and its declared API level matches the project
  floor (API 30 — the bionic builds need `statx(30)`/`getrandom(28)`, so
  Android 11+ is the practical floor).
- Any vendored patch series applies cleanly against its declared baseline (a dry
  `git apply --check`), so a broken series is caught before a device run.
- **Architecture assertion:** every asset declared as `aarch64` really is
  aarch64, and every asset declared static really is static. An x86_64 binary
  under an arm64 tag is useless and has happened in this space; the check is
  cheap and worth enforcing.
- **Kernel-shaped assertion:** an asset declared as the kernel must actually be a
  kernel (the expected ELF plus a recognisable kernel banner), not, say, a
  `stub_exe` or a helper that got renamed.

### 1.3 Evidence schema validation

Every committed device run must validate against
[../evidence/schema.json](../evidence/schema.json):

- JSON parses; `schema_version` is `"1.0"`.
- Required fields present: `device`, `kernel`, `capabilities`, `verdict`.
- Each capability probe is an object with `ok` (boolean) and `evidence` (string).
  The `evidence` string **is the marker** — a verbatim line from the logs that
  justifies `ok: true`. The rule remains: **the verdict is the marker string,
  never the exit status** (see [../evidence/README.md](../evidence/README.md)).
- The log files referenced by the run directory exist alongside it, are non-empty,
  and changed the same commit (a summary pointing at a log that is not in the tree
  is how evidence rots).

### 1.4 Release manifest integrity

For a released tag: `SHA256SUMS` covers exactly the published assets, the digests
match the bytes, and the manifest's recorded tag/commit match the git tag and
`HEAD`. Verification must be runnable offline against a downloaded release, since
that is the only way a third party can check what they received.

## 2. What CI deliberately does not check

Be explicit about this, because the temptation to overclaim is real:

- **It does not run the kernel.** A runner cannot execute an arm64 UML kernel
  meaningfully, and it cannot reproduce the app sandbox at all.
- **It does not prove any capability.** "Boots Docker" is only ever asserted by a
  device run.
- **It does not check documentation *truth*.** Link and structure checks are
  mechanical. Whether a sentence matches a measurement is a review question; the
  mitigation is that every factual claim must cite a device run under
  `evidence/`.
- **It does not test unprivileged-ness.** A container runner would happily run
  many things a Termux app cannot.
- **It cannot see Android lifecycle behaviour** (phantom killer, LMK, doze,
  screen-off) — see [MOBILITY.md](MOBILITY.md).

## 3. Why device gates cannot run on GitHub-hosted runners

Concretely, a device gate needs all of:

1. an **aarch64 Android device** (or emulator with a 16 KB-capable guest) where an
   app can boot the kernel;
2. the **app sandbox's exact shape** — unprivileged UID, `CapEff=0`, app seccomp
   filter active — because that is what the project's central claim is about;
3. a **Termux environment** with the release assets, a Debian+Docker ext4 image
   (over a gigabyte) and a gvproxy binary;
4. the ability to run for minutes without Android's lifecycle killing the run
   (§2 of [MOBILITY.md](MOBILITY.md));
5. `proot -b $PREFIX/etc:/etc` for gvproxy, which needs `/etc/resolv.conf`.

A GitHub-hosted runner is an x86_64 VM: wrong architecture, wrong sandbox, no
Android. An **Android emulator** on a runner is the closest approximation and is
still not the claim — the emulator does not reproduce the app sandbox, the
phantom-process budget, doze, or the device's page size. So the honest options
are:

- **Self-hosted runner on a phone** (Termux), optionally; and
- **manual device runs recorded as evidence**, which is what this project does by
  default.

## 4. How a phone run is recorded and validated

### 4.1 The flow

```
  ┌─────────────────────── device (phone) ──────────────────────────┐
  │ 1. run the launcher / probe script                              │
  │ 2. capture: boot log, gvproxy log, guest checks output          │
  │ 3. sanitise: strip serials, hostnames, IMEI-ish IDs, usernames,  │
  │              local paths, MAC addresses, IPs of the phone        │
  │ 4. write evidence.json per evidence/schema.json                   │
  │ 5. checksum the pair                                             │
  └───────────────────────────┬─────────────────────────────────────┘
                              │ git add evidence/<run-id>/
                              ▼
  ┌──────────────────────── pull request ───────────────────────────┐
  │ CI: schema validation + log-existence + evidence/ok check        │
  │ CI: link check, forbidden-construct scan                          │
  │ Reviewer: is the evidence string the one the claim needs?         │
  └───────────────────────────┬─────────────────────────────────────┘
                              ▼
                        merged, and now citable
```

### 4.2 The contract

- One directory per run: `evidence/<run-id>/` containing `evidence.json` plus the
  sanitised logs it names. The naming scheme is fixed in
  [../evidence/README.md](../evidence/README.md).
- `evidence.json` must validate against [../evidence/schema.json](../evidence/schema.json).
- **The verdict is the marker string, never the exit status.** A run whose script
  exited 0 but whose `evidence` string never appeared is a **FAIL**. A run whose
  script exited non-zero but whose `evidence` appeared is a PASS *with a note*.
  This rule exists because a userland success can be reported by a process that
  then dies badly (gvproxy exiting on BESS EOF is exactly that shape), and because
  a timeout wrapper can turn a live guest into a non-zero exit.
- Every capability probe declares an `ok` boolean and an `evidence` string; the
  log file that contains the evidence is part of the run directory.
- Sanitisation is mandatory and recorded in `notes` (or `known_limits_observed`
  for limits), so a reviewer knows what was removed rather than trusting that
  nothing was.

### 4.3 Evidence quality bar

A run is citable when a stranger can (a) see which device and kernel it was,
(b) re-run the listed commands, and (c) find each probe's `evidence` string in
the attached log. Anything short of that is an anecdote.

## 5. Release process

Tags, downloads and checksums — the point is that a stranger can verify what they
received without trusting the repo.

```
  work merged ──► version decision ──► git tag ──► build/collect assets
                                                        │
                                                        ▼
                              tarball of the release assets  +  SHA256SUMS
                                                        │
                                                        ▼
                                          verify: digests match the published
                                          bytes, assets are aarch64, the kernel
                                          asset is a kernel
                                                        │
                                                        ▼
                                                   GitHub release
```

Steps:

1. **Freeze what is released.** Assets are the release: kernel binaries, helpers
   such as `stub_exe`, images, and the scripts needed to use them — not "the
   kernel source tarball".
2. **Tag.** `vX.Y.Z` per §6. The tag is the identity of the release.
3. **Produce the asset tarball and `SHA256SUMS`** (`sha256sum` output, one line per
   asset, generated from the bytes actually published).
4. **Verify before publishing, and make the same verification available to
   users**: record the asset list, sizes, digests and the commit the assets came
   from in the release; a consumer must be able to `sha256sum -c SHA256SUMS`
   after downloading and get a clean result.
5. **Publish the GitHub release** with the tarball, `SHA256SUMS`, and the
   provenance note (which kernel version, which upstream baseline, which device
   the gate ran on).
6. **Documentation-only changes get no tag and no release.** A tag means source,
   runtime behaviour or assets changed — never a docs edit.

### What blocks a release

| Condition | Blocks? |
|---|---|
| Docs-only change | no tag, no release |
| CI static/packaging/schema checks failing | yes |
| `SHA256SUMS` does not match the published bytes | yes |
| An asset is the wrong architecture, or "the kernel" is not a kernel | yes |
| A claimed capability with no device run under `evidence/` | yes — drop the claim or record the run |
| Device gate failing on the reference device | yes |
| Device gate passing on one device but a claim generalised to others | yes — the claim must be narrowed (see [../README.md](../README.md#verified--not-verified)) |

## 6. Versioning and commit conventions

> Project policy, not a measurement. These are the conventions this project
> adopts; they are not derived from any device run.

**Tags.** `vMAJOR.MINOR.PATCH`, prefixed `v`. Downstream releases **must not reuse
Linux kernel version tags** — `v7.2` would be actively harmful, since the kernel
version is an upstream fact and not this project's version. If the kernel version
needs to be recorded, put it in the release notes and in each run's evidence, not
in the tag.

- `MAJOR`: a change that breaks existing invocations, or that changes what the
  project claims to support.
- `MINOR`: a new verified capability, a new supported device, or a new transport
  backend.
- `PATCH`: fixes that do not change the interface or the claim set — including
  documentation corrections that accompany a code fix.

**Commit messages.** Imperative subject line, ≤ 72 characters, then a body that
says *why* and, when the change came from a device, which run's evidence backs it.

```
net: register forwards after each gvproxy restart

Expose mappings are not persisted by gvproxy, so a restarted run lost
127.0.0.1:8123 while the container stayed up. Re-register after every
start and assert the mapping before reporting PASS.

evidence: evidence/2026-10-26-android16-aarch64-runbook
```

**Commit body requirements for evidence-backed changes:**

- name the artefact directory (`evidence/<run-id>/`) that supports the change;
- state the marker string that decided the run;
- state the device and kernel, or say explicitly that the change is unverified.

**Branches.** Short-lived, one concern each (`net/bess-forwarding`,
`docs/forensics`). Nothing merges without either a device run or an explicit
"unverified" note in the pull request description.

**Never** rewrite a tag, and never move a tag to different bytes. If a release was
wrong, ship a new patch version: the `SHA256SUMS` a user already downloaded must
stay true.
