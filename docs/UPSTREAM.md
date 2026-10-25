# Upstream

The single most important thing to get right: **`uml4termux` is a userland UX and
packaging layer. It is not a kernel fork, and it carries no kernel patches of its
own.**

That means:

- The kernel that actually runs is downstream work by **other people**
  ([§2](#2-the-two-github-projects)).
- The patches that make the arm64 port exist live in those downstream trees, not
  here.
- Kernel bugs belong upstream or in those trees. Packaging and UX belong here.

```
        upstream UML (kernel.org, x86-centric)
                     │
                     │  generic UML fixes, reviewed on linux-um@
                     ▼
        zalexdev/linux-um-arm64  ── arm64 downstream port (38 commits, Linux 7.2-rc4)
                     │
                     │  bionic/Android build + harness
                     ▼
        Raymer8639/linux-um-arm64 ── packaging fork (release assets, docs, harness)
                     │
                     │  prebuilt kernels, stub_exe, images, helper binaries
                     ▼
   ┌──────────────────────────────────────────────────────────────┐
   │  uml4termux — THIS PROJECT                                     │
   │  launcher, gvproxy/BESS wiring, runbooks, evidence, docs       │
   │  (no kernel source, no kernel patches)                         │
   └──────────────────────────────────────────────────────────────┘
```

## 1. Upstream UML

The ARM64 port is **not** UML upstream. The official tree is:

| | |
|---|---|
| Repository | <https://git.kernel.org/pub/scm/linux/kernel/git/uml/linux.git> |
| Development branch | `next` |
| Integrated branch | `master` |
| Urgent fixes | `fixes` |
| Mainline integration | <https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git> |
| Mailing list | `linux-um@lists.infradead.org` |
| Patchwork | <https://patchwork.ozlabs.org/project/linux-um/list/> |

Maintainers of record for UML are **Richard Weinberger, Anton Ivanov and Johannes
Berg**; the maintained areas are generic UML, x86/x86_64 UML, `hostfs` and the UML
documentation. The architecture reference upstream is `arch/x86/um`.

The upstream author of the arm64 effort is explicit about its status — from that
port's own README: *no 32-bit compat, the cpuset controller is impossible without
SMP, the guest vDSO time is not merged, single CPU unless built with SMP, page
faults cost ~7.6× native per page (1.77× per byte at 16 KB guest pages)*, and — the
sentence that matters most for anyone planning to depend on this — *"I am not
maintaining this and I am not planning to shepherd it through review."*

Read that as: the arm64 port exists, it works, and it does not have a maintainer
committed to pushing it into mainline. Plan accordingly.

## 2. The two GitHub projects

| | `zalexdev/linux-um-arm64` | `Raymer8639/linux-um-arm64` |
|---|---|---|
| Role | the **downstream port** — where the arm64 kernel work lives | **packaging fork** — bionic builds plus a harness |
| Branch | `um-arm64` (38 commits on Linux 7.2-rc4, i.e. `next`) | builds on top of the port |
| Stars | 103 (27 forks) | small (a fork) |
| Releases | `prebuilt-20260816` (bionic binary + `debian-docker.ext4.gz`) | `um-arm64-v0.1.0` … `v0.3.0` (24 Oct) |
| Artifacts | kernel binary, Debian+Docker image | `linux-bionic`, `linux-bionic-smp`, `stub_exe`, `passt-bionic`, `umnet`, harness, docs |
| Docs | port README, architecture notes | `docs/` (BUILD, TESTING, RELEASE, SECURITY, UPSTREAM), `harness/` |
| Why you care | this is the port being used | this is where the prebuilt, docker-capable binaries and the release discipline come from |

Both are worth reading before filing anything. In particular, the fork's
`SECURITY.md` is the honest statement of the trust boundary that this project
repeats in [KNOWN-LIMITS.md](KNOWN-LIMITS.md#hostfs-and-integrity): `hostfs`
exposes host storage and must not be used with untrusted guest code, and the
bionic build "avoids root and KVM requirements but does not make the host process
a security sandbox".

The fork also keeps upstream as a **fetch-only** remote (its push URL is disabled
by design) and tracks a recorded upstream baseline; that is the pattern to copy if
you work on the kernel side.

## 3. termux-packages PR #32700

<https://github.com/termux/termux-packages/pull/32700> — **open, not merged.**

What it proposes:

- `packages/linux-kernel-um` — **56 aarch64 patches** (plus 6 x86_64) and a
  `docker.config` fragment (142 lines, derived from the Docker project's
  `check-config.sh` reasoning), `TERMUX_PKG_VERSION=7.2.11`.
- `packages/passt` — **13 Android patches**.
- `API_LEVEL=30` → **Android 11+ in practice**.

Why it matters to this project: it is the path from "you downloaded binaries" to
"`pkg install` gives you a supported kernel". Until it lands, this project is not
a Termux package and `pkg install` will not install it.

Known gaps in that PR as of the evidence gathered here: the `umnet` bridge helper
is **not** included (so a script expecting `umnet` fails with "missing umnet"), and
the inbound-forwarding property does not follow from `passt` as released — see
[FORENSICS.md §7](FORENSICS.md#7-the-passt-inbound-failure).

## 4. Discussion #8555 — the historical position

<https://github.com/termux/termux-packages/discussions/8555> (2022) is the "UML is
x86-only" / "porting UML is wontfix" position, on the grounds that UML needed
SysV IPC facilities in the same way proot did. It is the reason there was no
official path for roughly four years, and PR #32700 is the answer to it.

Worth reading before arguing about the packaging PR: it sets out exactly which
objections have to be answered, and "it works on my phone" answers only some of
them.

## 5. How to contribute a patch series upstream

If you have a fix that is genuinely **generic UML** (not Android-specific, not
arm64-specific-by-necessity), a kernel-quality patch series is the right
contribution, and the reviewers are the UML maintainers on `linux-um@`.

Workflow:

1. **Fix the baseline first.** Work against the official tree
   (`uml/linux.git`, branch `next` for development), not against a downstream
   branch. A patch that does not apply to upstream is not a contribution yet.
2. **Split the series** into reviewable commits: one logical change each, each
   with a commit message that states the problem, the reasoning and the
   observable effect. Big-bang patches get ignored.
3. **Build and test on x86 UML too**, because that is the architecture upstream
   actually runs in CI and in maintainer testing. A change that only compiles on
   arm64 will not be reviewed as generic.
4. **Describe the failing case concretely:** a command sequence, a config, an
   observed-versus-expected pair. "It breaks" is not a bug report.
5. **Send with `git send-format-patch` / `git send-email`-style formatting** to
   `linux-um@lists.infradead.org`, with a cover letter for series of more than
   one patch, and check Patchwork to see it landed.
6. **Mark the Android/arm64-specific parts clearly** as downstream-only, so a
   reviewer can tell what they are being asked to take and what they are not.

Follow the kernel's own submission rules (`Documentation/process/submitting-patches.rst`)
for the mechanics: sign-off, subject prefixes, no HTML, no attachments, plain text.

What is *not* upstreamable from here, and should stay downstream: the bionic/NDK
build glue, the symbol-redefinition shims needed per bionic version, Android
API-level workarounds, and the packaging. Those are the port's business.

## 6. Where this project's changes belong

| Change | Where it goes |
|---|---|
| Kernel behaviour, `arch/um` code, UML drivers, hostfs | upstream (`linux-um@`), or the arm64 downstream tree first if it is arm64-only |
| Building the kernel for bionic/Android, config fragments, release asset discipline | the packaging fork (`Raymer8639/linux-um-arm64`) |
| Termux packaging, API-level handling | termux-packages PR #32700 (or its successor) |
| Launcher, gvproxy/BESS wiring, port-forward orchestration, runbooks, evidence format, documentation | **this project** |

## 7. Imported artefacts and their licences

This project redistributes, or documents how to obtain, artefacts it did **not**
write. Their licences and terms are their own, and they are unaffected by this
project's licence.

| Artefact | Origin | Licence / terms |
|---|---|---|
| Kernel binaries (`linux-bionic`, `linux-bionic-smp`, `linux`) | downstream arm64 UML trees (`zalexdev`, packaging fork) | GPL-2.0 (Linux kernel) plus those trees' terms |
| `stub_exe` | the port | GPL-2.0 (part of the UML build) |
| `passt`, `umnet` helpers | passt project + the packaging fork | as declared by those projects |
| `gvproxy` v0.9.0 (`linux-arm64`) | gvisor-tap-vsock project | as declared by that project |
| Debian 12 + Docker disk image | Debian + Docker | Debian's own licences; Docker's own terms |
| Alpine initramfs | Alpine Linux | Alpine's own licences |
| Initramfs images built here | this project | GPL-2.0-only |

Nothing in this repository renumbers, supersedes or re-licenses those. The
project's own notice in [LICENSE](../LICENSE) says the same thing, and it claims
no copyright over the imported artefacts.

If you redistribute a bundle, keep the upstream notices with it — and keep
`SHA256SUMS` intact, because the point of the checksums is that a third party can
verify the bytes they received.
