# Upstream PR 1 — prepared, not submitted

**Target:** [`Raymer8639/linux-um-arm64`](https://github.com/Raymer8639/linux-um-arm64)
(the packaging fork this project pins), branch `um-arm64`.
**Why there and not `zalexdev/linux-um-arm64`:** the fork is active (PRs #18–#25, last
push 2026-10-31) and takes `harness:`/`evidence:` PRs; the kernel port has taken no PR
at all and has not answered [issue #4](https://github.com/zalexdev/linux-um-arm64/issues/4)
since 27 Oct. The kernel-side contribution path (linux-um@, per `docs/UPSTREAM.md`)
stays open and unchanged — F1 (fork + pinned release) remains the fallback, not a bet.

**Status:** patch and body are ready. Opening the PR is a public action on someone
else's repository, so it waits for the repository owner's go-ahead. Everything needed
to send it is in this repository: the diff, the test that proves the guard, and the
device evidence below.

**Patch:** `ci/upstream/0001-harness-refuse-a-second-boot-on-a-held-backing-image.patch`
**Guard test:** `ci/upstream/image-lock-probe.py`

---

## Title

```
harness: refuse a second boot on a backing image another UML holds
```

## Body

> `harness/boot.py` boots one guest with `ubd0=<rootfs> root=/dev/ubda`. That is fine
> until two boots share an image — and when they do, the second one does not fail. UML
> takes an **exclusive `F_SETLK`** on the backing image, so the second guest comes up
> with **no disk at all**: the console reports `NO_DISK`, the boot marker still
> appears, and every write is silently discarded. A harness gate that only reads the
> marker passes, and the user loses data into a guest that looks healthy.
>
> This patch adds one check before the boot. The lock *is* the condition, so the guard
> simply tries to take it: if another process holds it, the harness stops with a
> message that names the image and says what to do (copy the image, or stop the other
> guest).
>
> ```python
> if not args.hostfs and image_is_held(root):
>     parser.error("another guest already holds " + root + ": UML takes an exclusive "
>                  "lock on the backing image, and a second boot would run diskless and "
>                  "lose every write. Copy the image, or stop the other guest first.")
> ```
>
> `image_is_held()` opens the image, tries `fcntl.lockf(fd, LOCK_EX | LOCK_NB)`, and
> releases it again. It is deliberately *not* a `/proc` scan for `linux` processes:
> matching by name misses a renamed kernel binary, matches unrelated guests, and does
> not answer the question the kernel is actually asking.
>
> **Measurements, not theory.** These come from the packaging work in
> `michaelamoetoevsky/uml4termux`, which runs this kernel with an ephemeral COW overlay
> per cycle: two guests on one image gave a booted console with `NO_DISK` and writes
> that vanished, while the *same* cycles with a private copy per guest were clean over
> 90/90 and 80/80 cycles (`evidence/20261031-soak-b1-clean.json` in that repository).
> That is why its launcher always copies the image, and why its daemon refuses a
> failed ubd attach (`UML4TERMUXD_STRICT_UBD=1`) instead of continuing.
>
> **Verification of this patch**
>
> - applies to `harness/boot.py` at `umarm64` HEAD (`patch -p1 --dry-run`, 3 hunks);
> - with another process holding the image: exit 2, message names the image;
> - with the image free: unchanged behaviour (the guard is one `open`/`lockf` pair);
> - the probe itself is tested, including the trap that makes naive tests lie: POSIX
>   record locks are **per-process**, so a test that locks the image in the same
>   process that probes it reports "free" no matter who holds it. `image-lock-probe.py`
>   forks a holder for exactly that reason.
>
> **Notes for the reviewer**
>
> - `--hostfs` is skipped: there is no backing image to lock.
> - When COW support lands (`ubd0=<cow>,<backing>`, which this repository's launcher
>   already uses), the lock should be taken on the **backing** image, not the overlay —
>   the overlay is per-guest by construction, the backing is the shared thing.
> - No new dependency: `fcntl` is in the standard library on every platform this
>   harness runs on.

---

## What I would send, in order

1. Fork `Raymer8639/linux-um-arm64` (public).
2. Branch `harness/image-lock` from `um-arm64`, commit the patch with the message
   above as the body (their commit prefixes are `harness:`, `evidence:`, `release:`).
3. Open the PR with the body above, and link `docs/ISSUES.md` item 6 here for context.
4. If no response in 30 days, record it and stay on F1 — the project already builds,
   pins and tests the kernel it ships, so nothing here blocks a release.