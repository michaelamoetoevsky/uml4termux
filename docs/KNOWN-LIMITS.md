# Known limits

What this does not do, stated plainly. Nothing here is a bug report and nothing
here is expected to be fixed by a configuration change: these are properties of
running a Linux kernel as an unprivileged Android app process. Where a limit is a
missing kernel config symbol, the symbol is named so you can check your own
kernel.

See also [README.md § Verified / not verified](../README.md#verified--not-verified)
— the inverse list, i.e. what *is* established and on what evidence.

---

## Kernel configuration gaps

Checked with `zcat /proc/config.gz` inside the guest; all three released kernels
share these.

| Gap | Symbol | Effect |
|---|---|---|
| **No cpuset controller** | `CONFIG_CPUSETS` unset | `docker info` warns "No cpuset support"; `--cpuset-cpus` is not available. Also impossible without SMP, per the upstream author. |
| **No swap limit support** | — | `docker info` warns; `--memory-swap`, swap accounting and OOM-kill-by-swap behaviour are absent. |
| **No 32-bit userspace natively** | `CONFIG_COMPAT` off | i386 / armv7 images do
  not run natively. They **do** run through user-mode emulation: install
  `qemu-user-static` in the guest and register the handler in binfmt_misc
  (mountable in the guest kernel), after which `docker run --platform linux/386
  i386/alpine` works (`uname -m` → `i686`). Emulation on top of an already
  emulated syscall path — expect it to be slow. |
| **No cgroup v1** | — | cgroup v2 only. Old tooling that expects `/sys/fs/cgroup/<controller>` v1 layouts will not find it. |
| **No kernel modules** | `CONFIG_MODULES` unset (released bionic build) | `modprobe`/`rmmod`, out-of-tree drivers and firmware loading do not work with that binary. The downstream source supports modules — this build does not enable them, so check your own kernel before assuming. |
| **Guest vDSO time not merged** | — | Flagged as unmerged by the upstream author; guest time-related paths are not the same as a native kernel's. |

Fragile operations that live outside the gap list but behave differently because
they are guest-side emulations of kernel services: anything doing heavy
`ptrace()` nesting (debuggers inside the guest, gdb on a containerised process),
and anything relying on kernel-level crypto/accelerated paths that the guest
kernel has to provide for itself.

## CPU and scheduling

- **One CPU under the default interception mode.** Inside the Termux app sandbox
  the default is `ptrace`, and ptrace mode does not support SMP:
  `SMP is not supported with ptrace userspace`. You get one guest CPU until you
  pass `seccomp=on`.
- **Multi-CPU requires seccomp, and seccomp must be permitted by the sandbox.** It
  works on the reference device; on a device whose seccomp policy refuses to let
  UML install a filter, you are back to one CPU.
- **No CPU pinning, no clock boost, no scheduling preference.** All of that needs
  root. The guest competes for CPU as an ordinary app.
- **No control over host CPU-frequency scaling** for the same reason, so run-to-run
  timing on a phone is inherently noisy.

## Performance characteristics

Directions, not promises — only the ~2.0 µs/syscall seccomp figure was measured by
this project.

- Guest **instructions run natively**; syscalls are emulated. Upstream figures:
  ~2.7 µs/syscall (seccomp) versus ~25 µs (ptrace); ~2.0 µs/syscall for seccomp was
  measured in-app. Native is ~0.08 µs (community-reported, not reproduced here).
- **Page faults are expensive:** ~7.6× native per page, 1.77× per byte at 16 KB
  guest pages (upstream). Memory-heavy workloads pay this repeatedly.
- **Syscall-heavy workloads pay most.** A build that makes millions of syscalls is
  the worst case; a compute-bound loop is close to native.
- **ptrace mode is roughly an order of magnitude worse per syscall** than seccomp
  and additionally pins you to one CPU. Booting without `seccomp=on` and then
  complaining about speed is the most common self-inflicted problem here.

## Networking

- **The released `passt` + `umnet` path cannot forward inbound.** `umnet` hardcodes
  `-t none -u none` (by design); patched to `-t 127.0.0.1/8123`, passt accepts and
  never forwards. Outbound only. Use gvproxy + BESS — see
  [FORENSICS.md §8](FORENSICS.md#8-the-solution-gvproxy-over-the-bess-transport).
- **gvproxy must be restarted for every guest run.** It exits when the BESS peer
  disconnects (`cannot receive packets from @ ... EOF`). Not a daemon.
  (The daemon supervises this automatically: it spawns gvproxy per guest
  session and re-applies the persisted exposures from `exposures.jsonl`.)
- **Port forwards do not persist.** After each gvproxy restart, every
  `POST /services/forwarder/expose` must be re-issued.
- **Forwards are one-to-one, by hand.** Expose the exact guest port a container
  published. There is no "expose all published ports" and no port-range syntax in
  this workflow.
- **Multi-guest works as N daemon instances (B3, device-verified).** All
  data-plane sockets are unix (BESS + control + gvproxy API), so two guests
  never collide on TCP; verified with 2 × 256M guests completing the 27-point
  matrix simultaneously. Budgets stay per-instance: RAM (kernel `mem=` +
  dockerd), and exposed HOST loopback ports must be distinct across instances.
- **gvproxy needs `/etc/resolv.conf`**, which Android lacks; it must run under
  `proot -b $PREFIX/etc:/etc` or DNS resolution is dead.
- **Handover is untested.** WiFi↔cellular roaming was not exercised; do not assume
  a NAT'd connection survives it ([MOBILITY.md §6](MOBILITY.md#6-network-handover-and-why-gvproxys-exit-is-the-real-mobility-hazard)).
- **IPv6 container networking works** (this corrects the earlier claim that it
  does not, from the 0.1.0 evidence). Two containers on a user-defined
  `--ipv6` network ping each other over `fd00:9::/64` with 0% packet loss in
  both directions (avg 1.8 ms and 3.8 ms). The confusion came from dockerd
  logging `Could not add route to IPv6 network … network is down` at
  `docker network create` time: at that moment the bridge really is DOWN, and
  it comes UP when the first container attaches — which is when addresses and
  the default route are handed out. The daemon error is cosmetic. The guest
  kernel has `CONFIG_IPV6`, `CONFIG_IP6_NF_IPTABLES` and `CONFIG_IP6_NF_NAT`.
- **Cgroup io limits WORK on the v0.4.0+ CI kernel** (corrects the 0.3.0-era
  claim that they were absent): `io.max` exists and accepts writes when keyed
  by device — `echo "98:0 rbps=1048576" > io.max` reads back
  `98:0 rbps=1048576 wbps=max riops=max wiops=max`. The earlier
  `io_limit_run=fail` came from a kernel without the throttle symbols *and*
  from writing a bare `rbps=` line (EINVAL without a `MAJ:MIN` prefix).
  Evidence: `evidence/20261029-cap11-c1-c2.json`.
- **Memory limits charge tmpfs and page cache too on the v0.4.0+ CI kernel**
  (corrects the 0.3.0-era "anonymous RSS only" claim): a 20 MiB tmpfs write
  inside a child cgroup raises `memory.current` by ~20.9 MB and shows up as
  `file` in `memory.stat`. `CONFIG_MEMCG_KMEM` no longer exists upstream
  since v5.14 — kmem charging was folded into `CONFIG_MEMCG` and is now
  unconditional. Anonymous memory is still enforced as before (OOM at the
  limit, exit 137). Evidence: `evidence/20261029-cap11-c1-c2.json`.
- **hostfs exposes host storage.** Never mount it for untrusted guest code. This
  was verified, not assumed: `mount -t hostfs none /mnt/host -o <host-dir>` inside
  the guest listed and read the host's files as the app user.
- **IPv6: works, with a cosmetic daemon error at network creation.** The 0.1.0
  evidence recorded "IPv6 container networking does not work"; capability round
  2 refuted that. Two containers on `--ipv6` ping each other over `fd00:9::/64`
  with 0% loss both ways. dockerd's `Could not add route … network is down`
  log line fires only while the bridge is still DOWN (before the first
  container attaches) and does not prevent addressing or routing.

## Guest and container runtime

- **Docker runs as root INSIDE the guest.** This is not Docker "Rootless
  Mode": `dockerd` runs as guest-root, and the guest kernel is the isolation
  layer. That never grants Android host root (the UML process runs as the
  Termux app uid), but it is a different threat model from a rootless Docker
  daemon — do not describe it as rootless Docker to users.
- **systemd / OpenRC as PID 1 are out.** OpenRC as PID 1 hangs under this port.
  Distributions that require a systemd PID 1 (Fedora/RHEL-family defaults, many
  desktop-oriented images) need their own init or are simply not usable. A minimal
  init plus `switch_root` is the supported shape.
- **`exit` hangs the guest.** Always `poweroff -f`.
- **The console spec is fixed.** `con=null con0=null,fd:1`; a regular-file fd makes
  the console die silently with `EPERM`.
- **`stub_exe=<path>` is mandatory** — memfd exec is refused by the sandbox, so the
  stub must be a file on disk.
- **Restarting `dockerd` in a live guest requires cleanup** (`/run/containerd`,
  `/run/docker`, `/var/run/docker.pid`), or the second start trips over stale
  state.
- **Docker surface verified so far:** Compose v2.29.7 (two-service stack,
  `depends_on`, `up`/`down -v`), BuildKit builds, 32-bit images via qemu-user.
- **Still untested Docker surface:** swarm, volumes with unusual
  drivers, user-defined networks beyond the basics (IPv6 user-defined networks
  are verified), rootless-in-guest mode, Kubernetes. Do not assume they work
  because `docker run` does.

## Host and Android

- **Android 11+ in practice (API 30).** The bionic builds need `statx(30)` and
  `getrandom(28)`; a report exists of Android 10 failing with `SIGSYS`
  ("Bad system call"). `API_LEVEL=30` is the packaging floor.
- **Phantom process killer (Android 12+).** 32 child processes *system-wide* for a
  background app. Container workloads hit this. Mitigation requires a one-time
  Developer-options toggle or adb. See
  [MOBILITY.md §2](MOBILITY.md#2-phantom-process-killer-android-12).
- **Excessive-CPU kill and LMK.** The guest is one app process; it cannot raise its
  own priority. A background CPU-heavy guest can be killed outright.
- **Doze / screen-off.** Without a wakelock, expect the guest to be frozen when the
  screen is off.
- **`/proc/sys` is unreadable** in this sandbox. The port does not need it, but
  tooling that assumes `randomize_va_space` or `mmap_min_addr` are readable will
  misbehave.
- **Exactly one device has been tested.** Every measurement in this repository
  comes from a single Android 16 / aarch64 phone. Other devices are unverified,
  including whether seccomp mode is permitted at all.

## Device resources

- **RAM:** the guest is one app process, so guest RAM is phone RAM. `mem=1024M`
  with ~2.1 GB free was the working point; that is roughly 1 GB of phone RAM while
  the app is foreground. Overcommitting triggers LMK, which kills the whole VM.
- **Disk:** the Debian+Docker image alone is ~1.2 GiB as shipped, and can be
  grown in the guest (truncate the file on the host, then `resize2fs` inside).
  Images pulled into it and build output consume the same file. Budget several
  gigabytes of fast free storage.
- **Battery:** a wakelock plus sustained CPU plus a full Docker daemon is a serious
  drain; this is a laptop-shaped workload running on a phone.

## Project and ecosystem

- **Not a security sandbox.** UML runs a kernel as a host process; it is not a
  hypervisor isolation boundary. A guest-kernel escape is an escape into the app's
  own process. `hostfs` publishes host storage into the guest.
- **The guest kernel is a release candidate** (Linux 7.2-rc4 lineage) on a
  downstream branch.
- **Upstream does not maintain it.** The port's own README says it is not
  maintained and will not be shepherded through kernel review.
- **Not packaged.** termux-packages PR #32700 is open, not merged; this is not a
  Termux package, and `pkg install` does not install it.
- **Redistributed binaries carry their own licences** (GPL-2.0 and their own
  terms). See [LICENSE](../LICENSE) and
  [UPSTREAM.md](UPSTREAM.md#imported-artefacts-and-their-licences).
- **This documentation set is a UX/packaging layer's docs, not kernel
  documentation.** Anything about kernel internals belongs upstream.

## hostfs and integrity

`hostfs` gives the guest a window onto host storage: the guest can read and write
files as the app user. That is a convenience feature and a strong reason never to
run untrusted code in a guest configured with it. Prefer a rootfs image
(`ubd0=<image>`), which the guest cannot use to reach outside itself.

Corollary for evidence handling: a guest that has hostfs mounted can modify host
files, including the tooling that judges the run. Do not treat a run as evidence
if the guest under test had hostfs access to the host's own workspace.

## Not a limitation, but worth knowing

- The guest **is** a real kernel: `uname -r`, `/proc`, `/sys`, namespaces, cgroups,
  iptables, modules (subject to config) and container isolation all behave as on a
  Linux box. That is the entire reason this project exists rather than shipping
  proot.
- Root **inside** the guest is real from the guest's point of view. It is not root
  on the phone and gives no host privileges.
