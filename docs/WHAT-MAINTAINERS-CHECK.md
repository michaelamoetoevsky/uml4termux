# What a Termux maintainer actually weighs (sampled, not guessed)

Wayfinder ticket [#2](https://github.com/michaelamoetoevsky/uml4termux/issues/2). The policy
text says "active, well-known projects"; the automated job turns that into three numbers. This
file answers the question the numbers do not: **once the bot stops closing, what does a human
look at?**

Method: `GET /search/issues?q=repo:termux/termux-packages+is:pr+is:merged+in:title+"new package"`
— **890 merged "new package" PRs** exist. The 12 most recently updated were sampled, and for
each one: changed files, added lines, human comments (bots excluded), reviews, and the first
substantive human comment. Raw sample: `/data/data/com.termux/files/usr/tmp/maintainer-sample.json`
on the device that produced it; the table below is the whole of it.

| PR | files | +lines | human comments | reviews | package |
|---|---|---|---|---|---|
| #32763 | 11 | 1 099 | 0 | 0 | electron43 |
| #32738 | 104 | 29 323 | 2 | 0 | electron43-host-tools |
| #32343 | 11 | 908 | 0 | 0 | electron42 |
| #32334 | 119 | 85 518 | 0 | 0 | electron42-host-tools |
| #18985 | 4 | 18 | 0 | 1 | python-lxml |
| #11451 | 1 | 24 | 5 | 5 | libbullet |
| #29221 | 5 | 360 | 0 | 0 | ruffle |
| #15267 | 4 | 87 | 8 | 4 | vulkan-loader-generic |
| #10279 | 2 | 80 | 2 | 0 | glfw |
| #27403 | 1 | 17 | 0 | 0 | falkon |
| #27381 | 25 | 611 | 0 | 0 | qt6-{qtwebchannel,qtwebengine} |
| #25672 | 1 | 23 | 0 | 1 | gost |

## What the sample shows

1. **A clean PR merges quietly.** 8 of 12 had **zero** human comments: the automated gate plus
   the build is the filter, and a package that passes it does not need advocacy. This is the
   single most useful finding — it means the work that matters is *removing the reason the bot
   closes*, not writing a persuasive description.
2. **Size is not the bar.** Merged additions run from 17 lines (falkon) to 85 518
   (electron42-host-tools). Our 87-line `build.sh` is unremarkable in either direction.
3. **When a human comments, it is about these things, in this order of frequency:**
   - **`TERMUX_PKG_HOMEPAGE` must be HTTPS** (libbullet: "change `TERMUX_PKG_HOMEPAGE` to
     `https://…`" — the linter only says `NON-HTTPS (acceptable)`);
   - **relationship to what already exists** (electron43-host-tools: "will electron42 be
     removed after this?"; glfw: "Closes #10185" — an existing request);
   - **behaviour a user would trip over**, not code style (vulkan-loader-generic: "will
     installing this still make sure the system android vulkan library … is used").
4. **Nobody argued about licensing, disk size or architecture support** in this sample — the
   linter and the policy already handle those before a human arrives.

## What that means for this package, concretely

| Maintainer check (from the sample) | Our state | Evidence |
|---|---|---|
| HTTPS homepage | **met** | `TERMUX_PKG_HOMEPAGE=https://github.com/michaelamoetoevsky/uml4termux`; linter: `TERMUX_PKG_HOMEPAGE: PASS` |
| Does it duplicate an existing package? | **no** | `packages/uml`, `packages/user-mode-linux`, `packages/linux-um`, `packages/qemu-system-x86-64` all return **404** in their repo; `packages/proot-distro` exists (200) and is the one users compare it to — see the distinction below |
| Answers an existing request? | **not yet linked** | no equivalent request found in their tracker; the honest framing is "it does something `proot-distro` cannot", not "it is the answer to issue X" |
| Passes the build-script linter | **met** | `scripts/lint-packages.sh` → `Everything seems ok.` (15 checks, `docs/PACKAGING-POLICY.md` §3) |
| Version matches the release | **met, and newly gated** | `tests/test-version.sh`: CLI reports `0.5.0`, `TERMUX_PKG_VERSION` is `0.5.0` |

## The one substantive argument, ready before it is needed

`proot-distro` is in Termux and is the obvious "duplicate functionality" objection. The
difference is not marketing: `proot-distro` runs userspace under `ptrace` and **has no kernel
of its own**, so container runtimes that need kernel features — `overlay2`, cgroup v2, veth,
netfilter — cannot run inside it. This project boots a real Linux kernel (UML) inside the
Termux sandbox, which is why `dockerd` starts and `docker run` works. Both facts are measured,
not asserted: `docs/KNOWN-LIMITS.md`, `evidence/` records, and the soak runs.

## Consequence for the map

The re-submission ticket does not need a better pitch. It needs the gate inputs to change
(stars ≥ 10 or 2026-12-24) and the four mechanical items in
[`PACKAGING-POLICY.md`](PACKAGING-POLICY.md) §5. Everything a human would ask is already
answered above, with the command that answers it.