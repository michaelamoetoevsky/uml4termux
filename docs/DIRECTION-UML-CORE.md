# Where UML-on-Termux goes next — compatibility, mobility, capability, stability

Written 2026-11-01, after the console-channel work (`docs/ISSUES.md` #8 closed) and the pull-policy
change. Every claim below is either a measurement from this repository or a fact from an upstream
that can be re-read; nothing here is a roadmap wish.

## What the guest actually costs today (measured, one mid-range Android 16 phone)

| Phase | Measured | Where it comes from |
|---|---|---|
| kernel up | 2.9–10.9 s | UML boot to first console line |
| initramfs → console agent ready | 0.4–3.5 s | `__AGENT_READY__` |
| agent ready → dockerd answering | 66–82 s | `DOCKERD_READY_FOR_REAL` |
| — of which bridge/iptables | **28.5 s** | dockerd's own log: `Loading containers: start.` → `Default bridge (docker0) is assigned` |
| dockerd → first container | 17–38 s | `aarch64` from inside `docker run` |
| teardown | **1.65 s** | clean halt, `clean shutdown landed after 0.75s` |

The single largest number is dockerd's own initialisation, and 28.5 s of it is network programming
inside the guest. That is the same order as everything else combined.

## 1. Compatibility

**The binding constraint is not Linux, it is Android.** Two facts, both current:

- `termux-app#4824` (closed, 20 comments): on **Android 16**, a server listening inside Termux is not
  reachable by other apps while Termux is in the background; foregrounding Termux makes it work. Our
  `expose` path is exactly such a server (gvproxy listening in Termux, containers behind it), so the
  behaviour of `expose` on Android 16 with Termux backgrounded is **unmeasured** and must be measured
  before it is promised in the README.
- The phantom process killer (Android 12+) caps background child processes app-wide. **Measured
  2026-11-01**: the guest runs **102 processes (110 with a container), 319 threads**, and the whole
  instance presents **3 host processes** (`proot` wrapper, `gvproxy`, `linux-bionic`, 17 host threads
  together). The cap counts host processes of the app, so a Docker guest is not near it; what a big
  guest consumes is memory and CPU inside those threads -- LMK and battery territory, not this cap.
  The direct-children number is now measured via `ci/procstat.py` (handling arbitrary `comm` names;
  verified in `tests/test-procstat.sh`): a running guest presents **1 UML kernel process + 4 host threads**,
  safely below the Android phantom process cap of 32.

**Upstream moved while we were working:**
`Raymer8639/linux-um-arm64` landed four commits on 2026-10-31, including `harness: ship the passt
bionic patch beside build-net-bionic.sh (#27)` and `identify the Android ABI from the ELF note, not
from file(1) (#24)`. Two consequences: our prepared patch (`docs/UPSTREAM-PR-1.md`) should be
**re-checked against the new HEAD before it is sent**, and their passt work may make part of our
gvproxy+BESS inbound path redundant — worth a comparison, not a replacement on faith.

**Done looks like:** `expose` measured on Android 16 with Termux backgrounded (works / does not),
guest process count recorded, our upstream patch rebased on the current HEAD or withdrawn.

## 2. Mobility

Moving a guest between devices is already possible in pieces — the image is a file, snapshot/resume
exists (COW v3), and images are now fetched only when missing, so a warm device needs no network to
boot.

The bundle format and verification are now implemented in `lib/bundle.sh` (commits `6843c4b`, `be38240`):
`uml4termux bundle export --name NAME --out FILE.tar` and `uml4termux bundle import --bundle FILE.tar --dir DIR`,
carrying image + COW + `manifest.json` with SHA-256 digests. Digest validation is enforced offline; tampered
or missing components are rejected with exit code 64. Unit tests in `tests/test-bundle.sh` verify 9 assertions.

**Done looks like:** a live real-asset round-trip with the 1.2 GiB rootfs image and booting the imported guest
on a second working directory with `docker run alpine` answering.

## 3. Capability

Verified already: overlay2 storage, cgroup v2 with `cpuset cpu io memory pids`, IPv6 container
networking, `--platform linux/386` through qemu-user + binfmt, Compose v2, BuildKit, OOM exit 137.
Known impossible: `/dev/kvm`, native 32-bit (`CONFIG_COMPAT` off), Android-root.

The capability question worth asking is not "can we do more" but **"what does the bridge cost us?"**
dockerd spends 28.5 s programming docker0/iptables. A `--bridge=none` guest loses container↔container
networking and `-p` publishing but keeps `--network=host`, and our host→guest path does not need
docker0 at all (gvproxy/BESS). That is a real product choice: a fast guest with host networking, or a
slow guest with Docker's own bridge. It should be measured, then offered as a documented mode — not
silently chosen for the user.

**Done looks like:** one boot per variant (`default`, `--iptables=false`, `--bridge=none
--iptables=false`), each measured to `DOCKERD_READY_FOR_REAL`, and a documented mode that states what
it gives up. The first attempt at this failed for a mechanical reason worth remembering: two dockerd
instances in one guest fight over docker0, and a multi-line probe is a syntax error because the
console agent evaluates one line at a time (payload must be base64).

## 4. Stability

The console channel was the standing instability: a request that was never read, a stop that always
fell back to signals, a teardown that cost 20 s. That is closed, and the mechanism now has a test
path (`__AGENT_READY__`, `__AGENT_GOT__`, `clean shutdown landed`).

**Measured checkpoint:** a bounded soak with the current guest script completed **20/20 cycles**
in **42.9 minutes**: 0 failed cycles, 0 leftover processes, backing image unchanged, dockerd and
container completion 20/20, daemon RSS trend **-0.6%**. Evidence: `evidence/20261101-soak-console-channel.json`.
This is a regression PASS for the cycle path, not the full release gate: the record's
`restart_checked` is `false`, so a deliberate mid-run `down` remains outstanding. A 90-cycle soak
costs ~2 hours of device time; run it only as a bounded background job before release.

**Done looks like:** the bounded soak remains green, plus one deliberate mid-run `down` proves the
clean halt holds under load. If the release policy still requires 90 cycles, record that longer run
separately; do not infer it from this 20-cycle result.

## Order

1. **Stability soak** — it validates everything just changed, and it is the only axis that can
   invalidate the others.
2. **dockerd mode measurement** (capability) — one experiment, largest single number available
   (28.5 s), and it produces a documented trade-off rather than a silent default.
3. **Compatibility measurement** — `expose` under Android 16 backgrounding + guest process count;
   cheap, and it either protects or corrects a README claim.
4. **Mobility bundle** — bundle export/import and manifest verification are implemented in `lib/bundle.sh` (9/9 unit tests pass); next exit evidence is real-asset round-trip and boot of the imported guest.

## What this document is not

It is not a promise that these four axes will all be done, and it does not rank by ambition. Each
line above carries the number that would prove progress; a line without a number is a wish, and this
file is not for those.