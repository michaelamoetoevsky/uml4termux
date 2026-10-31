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
- The phantom process killer (Android 12+) caps background child processes app-wide. A guest with
  dockerd + containerd + containers is a multi-process tree; the count inside our guest has never
  been recorded. Measuring it is cheap and turns a folklore risk into a number.

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
boot. What is missing is a **bundle**: one artifact carrying image + COW + a manifest of digests,
importable on another phone with the same pin, verified offline.

**Done looks like:** `ulter export` / `ulter import` round-trip on two work dirs (not two phones),
with the imported guest booting and `docker run alpine` answering, and the manifest's digests
checked before any boot. A guest that fails verification must refuse, not boot.

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

What is left is **regression pressure**: the guest script changed substantially (agent first, async
eval, pull-if-missing, log truncation, readiness markers) and the last full soak predates all of it.
A 90-cycle soak costs ~2 hours of device time, so it belongs in a bounded run, not in a working
session — but it must happen before the next release, because the boot path it exercises is new.

**Done looks like:** one soak with the new guest script (cycle count chosen to finish inside the
interruption horizon), 0 failed cycles, RSS trend recorded, and one deliberate mid-run `down` to
prove the clean halt holds under load.

## Order

1. **Stability soak** — it validates everything just changed, and it is the only axis that can
   invalidate the others.
2. **dockerd mode measurement** (capability) — one experiment, largest single number available
   (28.5 s), and it produces a documented trade-off rather than a silent default.
3. **Compatibility measurement** — `expose` under Android 16 backgrounding + guest process count;
   cheap, and it either protects or corrects a README claim.
4. **Mobility bundle** — the most code and the least urgency; it becomes urgent the moment someone
   asks "can I move this to my other phone", which is exactly what N2 is for.

## What this document is not

It is not a promise that these four axes will all be done, and it does not rank by ambition. Each
line above carries the number that would prove progress; a line without a number is a wish, and this
file is not for those.