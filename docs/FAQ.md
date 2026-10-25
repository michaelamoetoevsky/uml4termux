# FAQ

Short answers, with the evidence basis attached. Tags used throughout:

- **[verified here]** — measured on the reference device (Android 16, host kernel
  `6.1.157-android14-11`, aarch64, Termux app sandbox, `CapEff=0`).
- **[upstream]** — a figure or statement from the port's own documentation.
- **[community]** — reported by others in the ecosystem; **not reproduced here**.
- **[unverified]** — not established by anyone in this repository. Do not rely on it.

---

## Does it need root?

**No. [verified here]** That is the point of the whole project. The reference
device has `CapEff=0000000000000000`, `CapBnd=0`, and a full UML kernel boot plus
Docker runs inside an ordinary Termux app process.

There is no root-only step hidden in the workflow: no `su`, no `sudo`, no
capability, no `/dev/kvm` access, no tap device, no writable `/proc/sys`.

Two caveats:

- **Root inside the guest is real** (from the guest's point of view). `dockerd`
  runs as guest root and does root-like things — but those are guest-kernel
  operations, not host privileges.
- Some *Android lifecycle settings* that improve reliability (the phantom-process
  toggle, battery exemption) are device settings. They are reachable through
  Developer options, or through `adb` from a computer — see
  [MOBILITY.md](MOBILITY.md). The guest boots and runs without them.

## Does it need KVM?

**No. [verified here]** There is no `/dev/kvm` access anywhere in this design, and
none is needed: UML is a userspace kernel, not a virtual machine. Guest
instructions execute **natively** on the CPU (same architecture), and only
syscalls are intercepted and emulated.

KVM would be the "normal" way to give a guest a CPU, and Android apps cannot have
it. Avoiding that requirement is the entire reason UML is used here.

## How fast is it compared to proot and QEMU?

**Architecture [verified here], numbers [upstream] / [community] — nothing
measured here against proot or QEMU.**

Qualitatively, and why:

- **vs QEMU (full system emulation, on a different architecture): much faster in
  principle.** QEMU-user/system on a foreign architecture interprets or JITs every
  guest *instruction*. Here, instructions run natively — same ISA — and only
  syscalls are emulated. There is no translation layer for compute.
- **vs proot: not a straight win, and it depends on the workload.** proot is
  syscall *rewriting* with no kernel layer at all, so it is lighter. This project
  adds a kernel boundary per syscall. If your workload is syscall-heavy and does
  not need a real kernel, proot is the more economical choice — and this project
  has no measurements to argue otherwise.
- **The real difference is capability, not speed:** proot does not give you a real
  kernel, so it does not give you Docker.

Measured and quoted figures:

| Figure | Value | Basis |
|---|---|---|
| seccomp interception, in-app | **~2.0 µs/syscall** | [verified here] |
| seccomp interception | ~2.7 µs/syscall | [upstream] |
| ptrace interception | ~25 µs/syscall | [upstream] |
| native host syscall | ~0.08 µs | [community] |
| guest page fault | ~7.6× native per page (1.77× per byte at 16 KB guest pages) | [upstream] |

Consequences that follow directly:

- **Force `seccomp=on`.** The default inside the Termux sandbox is ptrace, roughly
  an order of magnitude worse per syscall *and* limited to one CPU.
- **Syscall-heavy work is the worst case**, memory-touching work next, pure
  compute closest to native.
- Any micro-benchmark you read comparing proot/UML/QEMU on someone else's phone is
  **[community]** and does not transfer to yours — phone CPUs, thermals and page
  sizes differ.

See [KNOWN-LIMITS.md § Performance characteristics](KNOWN-LIMITS.md#performance-characteristics).

## Can I run systemd?

**Effectively no. [verified here for OpenRC as PID 1]** OpenRC as PID 1 hangs
under this port, and the working design is a minimal init (`/umarm-init`) reached
via `switch_root` from a tiny initramfs. A full init system that expects
to own PID 1, mount its own hierarchies and manage services in the usual way is
not a supported target.

Practical alternatives:

- Use a container image and let Docker's own entrypoint/CMD be your init — i.e.
  avoid needing a system in the guest at all beyond `containerd` + `dockerd`.
- Use a distribution whose default is not systemd (Alpine, Devuan, Void,
  Artix-style), then run services directly.
- If you specifically need systemd *inside a container*, that is a different
  question from guest PID 1 — and it is **[unverified]** here; systemd in a
  container wants cgroup delegation and a writable cgroup hierarchy, and this
  guest has no cpuset controller (`CONFIG_CPUSETS` unset) and no swap limit
  support, both of which systemd-related tooling tends to complain about.

Also note the ground rules if you try: never `exit` the guest (`poweroff -f`), and
`con=null con0=null,fd:1` is mandatory.

## Why is Docker port forwarding done through gvproxy?

Because it is the only path that was found to work in **both** directions, and the
reason is a specific failure on the other path. **[verified here]**

Short version:

1. The "obvious" userspace networking path for this port is `passt` behind the
   `umnet` bridge helper (`vec0:transport=fd`). It gives the guest DHCP, DNS and
   outbound TCP with no tap device and no `CAP_NET_ADMIN`.
2. But the released `umnet` **hardcodes no inbound forwarding into `passt`** — by
   design; its own source comment says the guest gets outbound connectivity and
   nothing on the phone's network can reach into it.
3. Patching it to forward (`-t 127.0.0.1/8123`) makes `passt` **accept** the
   connection and then never forward a byte: the host's `connect()` **times out**
   (not refused — so something *is* listening). A container on `--network host`
   in the guest, which involves no DNAT at all, times out identically — which
   rules out Docker's netfilter/NAT as the cause. Setting the guest's `FORWARD`
   policy to `ACCEPT` also changes nothing.
4. So that path is outbound-only, and for "reach my container from the phone"
   you need a different userspace stack. Switching the vector transport from `fd`
   to `bess` and putting `gvproxy` on the other end of the UNIX socket gives DHCP,
   DNS, outbound TCP **and** a forwarder API:

   ```sh
   curl --unix-socket $TMPDIR/gvnet.sock -X POST \
     -d '{"local":"127.0.0.1:8123","remote":"192.168.127.2:8123"}' \
     http://unix/services/forwarder/expose
   ```

   After which `curl -i http://127.0.0.1:8123/` from the phone is served by the
   container — verified for both a bridge-published container and a
   `--network host` container.

Consequences to accept: gvproxy is a per-run process (it exits when the BESS peer
disconnects), its forward mappings do not persist, it needs `/etc/resolv.conf` so
it must run under `proot -b $PREFIX/etc:/etc`, and mappings are one-to-one.

Full reasoning: [FORENSICS.md §7–§8](FORENSICS.md#7-the-passt-inbound-failure).

## Is it a security sandbox?

**No.** **[verified here that the app is unprivileged; the rest is architecture]**

UML runs a Linux kernel as an ordinary host process. It does not provide the
isolation boundary of a virtual machine or a hypervisor: a guest-kernel
vulnerability that reaches the host through the syscall-emulation seam is a
vulnerability in the app's own process, not a contained VM escape.

Concrete warnings:

- **`hostfs` exposes host storage to the guest.** Never use it with untrusted
  guest code; use a rootfs image instead.
- **Anything that can reach `$TMPDIR/gvnet.sock` can create listeners on the
  phone's loopback.** Treat that socket as a trusted control channel and do not
  hand it to other apps.
- **`dockerd` in the guest runs as guest root**, and containers are isolated by the
  *guest* kernel, not by Android.
- **A run with hostfs access is not trustworthy evidence**: the guest could have
  modified the tooling that judges it.

What it *does* give you: real kernel-level container isolation, the same kind you
would get on a Linux server, provided you keep host storage out of the guest.

## What about 32-bit images?

**They do not run. [verified here]** `CONFIG_COMPAT` is **off** in all three
released kernels, so there is no 32-bit (i386, armv7) userspace support.

What that means in practice:

- A multi-arch image whose manifest expects an armv7 or i386 layer will fail.
- The workaround is qemu-user + binfmt_misc **inside the guest**, i.e. emulation
  layered on top of an already-emulated syscall path — slow, and **[unverified]**
  here (it was not tested).
- 64-bit (aarch64, x86_64-via-emulation is a separate matter) images are the
  supported case.

If your use case is specifically "run old 32-bit binaries", this is the wrong tool.

## Will it work on my Android version / device?

**Honest answer: one device is verified, and your mileage is [unverified].**

Requirements and floor **[verified here / packaging facts]**:

- **Android 11+ (API level 30) in practice.** The bionic builds need `statx(30)`
  and `getrandom(28)`. A report exists of Android 10 failing with `SIGSYS` ("Bad
  system call"). Check `getprop ro.build.version.sdk`.
- **aarch64.** This is an arm64 port of an arm64-only downstream tree.
- **Termux app sandbox** with a seccomp policy that permits UML to install its own
  filter if you want seccomp mode (that is what gives you multiple CPUs).
- **16 KB-capable guest pages**: the guest is built for 16 KB pages, which works on
  both 4 KB and 16 KB hosts (a guest page is a host `mmap()`, so it may be larger
  than the host's, never smaller). Android 15+ devices shipping 16 KB hosts are
  expected to be fine.

What has actually been measured: **Android 16, kernel `6.1.157-android14-11`,
aarch64 Armv9 (PAC/SVE2), Termux app sandbox, `CapEff=0`.** Nothing else.

If you want to know whether *your* device works, run the checklist in
[MOBILITY.md §8](MOBILITY.md#8-what-to-measure-on-a-new-device-before-trusting-it)
and record it under `evidence/`. Please do not generalise results from your phone
to other phones in either direction.

## How much RAM and disk does it need?

**[verified here on one device]** — treat as a starting point, not a specification.

| Resource | Value | Note |
|---|---|---|
| Guest RAM in tests | `mem=1024M` | with ~2.1 GB free on the phone |
| Phone RAM consumed | roughly 1 GB | the guest is one app process; guest RAM *is* phone RAM |
| Disk, base Docker image | ~1.2 GiB | Debian 12 + Docker as shipped; can be grown (truncate the file, then `resize2fs` in the guest) |
| Plus | pulled images + build output | they live in the same ext4 image |
| Practical disk budget | several GiB | on reasonably fast storage |

Rules of thumb:

- Budget the guest at about **half** of the RAM you can reliably free. Overcommit
  and the low-memory killer takes the whole VM, not one container.
- The guest is a single Android process and cannot raise its own priority, so
  there is no "nice it down" escape hatch.
- Remember the phantom-process budget (**32 child processes system-wide** for a
  background app on Android 12+) — a container density that would be trivial on a
  server can trip it.

## Why is Docker's storage driver overlay2 — do I need to configure anything?

No. **[verified here]** On a docker-capable kernel it is automatic:
`Storage Driver: overlay2`, `Backing Filesystem: extfs`,
`Native Overlay Diff: true`, cgroup v2 with controllers `cpu io memory pids`.

The one thing to check is that your kernel *is* docker-capable — one of the three
shipped binaries is not. Verify with
[FORENSICS.md §3](FORENSICS.md#3-how-to-verify-a-kernel-is-docker-capable).

## Can I use my own kernel or rootfs instead of the packaged assets?

Yes, with two conditions:

1. **The guest kernel must implement what you need.** It needs at least
   `OVERLAY_FS`, `VETH`, `BRIDGE`, `NETFILTER`, `PID_NS`, `USER_NS`, `MEMCG` and
   `CGROUP_PIDS` for Docker. A default `defconfig` enables none of these; the
   packaging ships a Docker config fragment for exactly this reason.
2. **The rootfs must not need a distribution init as PID 1.** A minimal init plus
   `switch_root` from an initramfs is the shape that works.

Remember the fixed command-line requirements regardless of what you boot:
`stub_exe=<path>` (mandatory — memfd exec is refused by the sandbox) and
`con=null con0=null,fd:1` (a regular-file fd makes the console die silently).

If you build your own kernel, note that the project's own README says it is not
maintained and will not be shepherded through kernel review — plan accordingly
(see [UPSTREAM.md](UPSTREAM.md)).

## Why does `exit` hang the guest, and why is there an "Address already assigned" error?

Both are real traps, both **[verified here]**, both documented with reproduction
in [FORENSICS.md](FORENSICS.md):

- **`exit`** hangs the UML process. Use `poweroff -f` to end a guest cleanly.
- **`ip addr add 127.0.0.1/8 dev lo`** fails with `Error: ipv4: Address already
  assigned.` — the loopback address is already there, so only
  `ip link set lo up` is needed. The nastier version of this trap is that a script
  which adds it blindly aborts early and presents as *"network is unreachable"*
  instead, sending you off to debug the wrong thing.

Also in the same family: `stub_exe` must be a real file, the console spec is fixed,
and a Debian image may ship no `udhcpc`/`curl`/`wget` at all.

## Does it need internet access?

For booting and running local containers: **no**. You need the assets on disk
(kernel, `stub_exe`, initramfs/rootfs image, gvproxy).

For `docker pull` and anything DNS-dependent: **yes**, and that is where the
networking stack comes in — gvproxy provides DHCP (`192.168.127.2/24`), a gateway
and DNS (`192.168.127.1`), and the NAT carries registry traffic. **[verified here]**:
external DNS resolution and pulls of hello-world, alpine and busybox all succeed
through that path.

## Is there a Termux package? Can I `pkg install` it?

**Not yet.** **[verified here as an ecosystem fact]** termux-packages PR #32700
(open, not merged) would add `linux-kernel-um` (56 aarch64 patches plus a Docker
config fragment) and `passt` (13 Android patches), at API level 30. Until it is
merged, this is not a Termux package and `pkg install` will not install it.

The historical position in that repository — "UML is x86-only, wontfix" — is
recorded in Discussion #8555 (2022); the PR is the answer to it. See
[UPSTREAM.md](UPSTREAM.md).

## What licence is this, and what about the binaries I download?

The project's own tooling and documentation are **GPL-2.0-only** — see
[LICENSE](../LICENSE).

Redistributed kernel binaries, initramfs images and disk images are **not** this
project's work: they remain under their upstream licences and terms (GPL-2.0 for
the kernel and UML helpers; the respective distribution licences for the userspace
inside the images). The project claims no copyright over them. Provenance is in
[UPSTREAM.md](UPSTREAM.md#imported-artefacts-and-their-licences).

## How do I report a bug, or contribute?

Record a **device run** first: a sanitised log plus a summary JSON per
[../evidence/README.md](../evidence/README.md) and
[../evidence/schema.json](../evidence/schema.json). A report without the marker
string, the device, the kernel and the exact commands is not reproducible, and
non-reproducible reports cannot be acted on.

Include at minimum: device + Android version + host kernel, the exact kernel
binary and its `uname`, the full kernel command line, the interception mode
(`Userspace mode: ...`) and CPU count, and the marker output that failed.

For **kernel** bugs, this is the wrong repository — go upstream
([UPSTREAM.md](UPSTREAM.md)). For packaging, termux-packages PR #32700 is the
venue.
