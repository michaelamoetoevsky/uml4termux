# Architecture

Status: describes the reference device and the two docker-capable released
kernels. Measurements and traps belong in [FORENSICS.md](FORENSICS.md); what does
not work is in [KNOWN-LIMITS.md](KNOWN-LIMITS.md).

## 1. The whole picture

One Android app process, one kernel, one container runtime, and two userspace
TCP/IP endpoints talking over a UNIX socket.

```
 Android userspace (unprivileged, no root, no KVM, CapEff=0)
 ┌─────────────────────────────────────────────────────────────────────────────┐
 │ Termux app process — UID untrusted_app, app seccomp filter active            │
 │                                                                             │
 │  ┌───────────────────────────────────────────────────────────────────────┐  │
 │  │ UML process = ELF `linux-bionic-smp`. The kernel IS this process.     │  │
 │  │                                                                       │  │
 │  │  host kernel view:  mmap()s for the guest, ptrace/seccomp for syscalls│  │
 │  │                                                                       │  │
 │  │  ┌─────────────────────────────────────────────────────────────────┐  │  │
 │  │  │ GUEST KERNEL  7.2.0-rc4, aarch64, 16 KB pages                   │  │  │
 │  │  │                                                                 │  │  │
 │  │  │  syscall table ──► executed natively, intercepted, emulated     │  │  │
 │  │  │  namespaces  ──── PID/UTS/IPC/NET/USER/MOUNT (kernel-side)      │  │  │
 │  │  │  cgroup v2   ──── controllers: cpu io memory pids               │  │  │
 │  │  │  overlayfs   ──── Docker overlay2, Native Overlay Diff on extfs │  │  │
 │  │  │  net core    ──── bridge, veth, netfilter, NAT (docker0)        │  │  │
 │  │  │  block dev   ──── /dev/ubda  ←── debian-docker.ext4             │  │  │
 │  │  │  net dev     ──── vec0      ←── vector transport (BESS)         │  │  │
 │  │  │                                                                 │  │  │
 │  │  │   ┌───────────────┐   ┌──────────────┐   ┌──────────────────┐   │  │  │
 │  │  │   │ containerd    │◄──│ dockerd      │──►│ runc             │   │  │  │
 │  │  │   │ 1.6.20        │   │ 20.10.24     │   │ seccomp+cgroupns │   │  │  │
 │  │  │   └───────────────┘   └──────────────┘   └──────────────────┘   │  │  │
 │  │  │                              │                                  │  │  │
 │  │  │           containers on docker0 (172.17.0.2, veth + NAT)        │  │  │
 │  │  └──────────────────────────────┬──────────────────────────────────┘  │  │
 │  └─────────────────────────────────┼─────────────────────────────────────┘  │
 │                                    │ unixpacket $TMPDIR/bess.sock          │
 │                                    ▼                                        │
 │  ┌──────────────────────────────────────────────────────────────────────┐   │
 │  │ gvproxy v0.9.0 (linux-arm64) — userspace TCP/IP + DHCP + DNS          │   │
 │  │   guest lease 192.168.127.2/24   gateway/DNS 192.168.127.1            │   │
 │  │   control API on unix $TMPDIR/gvnet.sock  (HTTP)                      │   │
 │  │     POST /services/forwarder/expose                                   │   │
 │  └───────────────────────────┬──────────────────────────┬───────────────┘   │
 └──────────────────────────────┼──────────────────────────┼───────────────────┘
                                │                          │
                    outbound: Android network      inbound: 127.0.0.1:8123
                    (DNS, registry pulls, HTTP)    (phone loopback)
```

## 2. Process model

| Layer | Process | Privilege |
|---|---|---|
| Host kernel | Android/Linux 6.1.157-android14-11 | full, but grants the app nothing extra |
| App sandbox | Termux UID, app seccomp filter, `CapEff=0`, `/proc/sys` unreadable | unprivileged; no capabilities to hand out |
| UML process | `linux-bionic-smp` + `stub_exe`, one app process for the entire guest | unprivileged; its only leverage is being a normal ELF |
| Guest kernel | 7.2.0-rc4, inside that address space | root *inside the guest* — a guest concept, not a host privilege |
| Guest userspace | minimal init → containerd → dockerd → runc | guest root (real when viewed from inside) |
| Containers | runc containers | guest namespace/cgroup isolation |
| Network | gvproxy, a separate app process | unprivileged; plain UNIX sockets and TCP |

Consequence worth stating out loud: **root inside the guest is not root on the
phone.** `dockerd` runs as guest root, binds guest port 80, calls `mount()`,
creates bridges and writes iptables rules — all of it implemented by the guest
kernel against host syscalls that the app is allowed to make. The host sees an
unprivileged process doing `mmap`, `read`, `write` and sockets.

## 3. Where the privilege boundaries are

1. **Host ⇄ app sandbox.** The hard wall. `CapEff=0`; no `CAP_NET_ADMIN`, no
   `/dev/net/tun`, no `/dev/kvm`, no writable `/proc/sys`. Everything the project
   does has to be expressible with ordinary syscalls.
2. **App process ⇄ UML process.** No boundary; the UML process *is* the app
   process (plus `stub_exe`, which only holds a guest address space so that the
   guest's own address layout does not collide with the host process's).
3. **Guest kernel ⇄ host kernel.** The syscall boundary — and the only place
   where guest intent becomes host action. This is the security-relevant seam:
   the guest kernel validates a guest syscall, then issues host syscalls on the
   guest's behalf. Everything the guest is allowed to do on the host is
   constrained by what an unprivileged app may do.
4. **Guest kernel ⇄ guest userspace.** Full kernel boundary, as on any Linux
   box: namespaces, cgroups, capabilities inside the guest, seccomp, LSM hooks.
   This is the boundary Docker relies on, and it is genuinely present.
5. **Guest ⇄ container.** runc containers in their own namespaces/cgroups, with
   Docker's default seccomp profile applied.
6. **App ⇄ gvproxy.** A UNIX-socket API on the host side. Anything that can talk
   to `$TMPDIR/gvnet.sock` can create listeners on the phone's loopback — see
   "Trust model" below.

```
   boundary 1   boundary 3        boundary 4        boundary 5
   ==========   ==========        ==========        ==========
   Android ├── app sandbox ├── UML/guest kernel ├── guest userspace ├── containers
           │             │  (syscall seam)   │                  │
      hardening:      interception:      namespaces,       seccomp, cgroups,
      CapEff=0        ptrace/seccomp     cgroups,           userns (guest)
      seccomp filter  PTRACE_SYSEMU      overlayfs,
      /proc/sys deny                     netfilter
```

## 4. Why unprivileged works

Because **the guest kernel implements the features Docker needs, itself.** Docker
is not asking Android for namespaces, cgroups, overlayfs or netfilter — it is
asking *the guest kernel*, which is a normal Linux kernel running as a program.
Android only ever sees the syscalls the guest kernel chooses to make for itself,
and an unprivileged app may make all of those.

Concretely, from the guest kernel's point of view:

- `mount -t overlay` is satisfied inside the guest; the guest kernel performs it
  against a real block device (`/dev/ubda`, a file on the host).
- `unshare`, `setns`, and every `CLONE_NEW*` flag are guest-kernel operations.
- `ip link add ... type veth` / `type bridge` are guest-kernel network objects;
  the only host-visible network I/O is the vector transport's byte stream.
- `iptables` touches the guest kernel's netfilter; the guest's packets leave as
  bytes on a UNIX socket, not as host packets.
- cgroup v2 is a guest filesystem (`cpu io memory pids`), with no host cgroup
  access at all.

What is *not* available therefore has to come from somewhere else or be dropped:
the guest has no cpuset controller (`CONFIG_CPUSETS` unset) and no swap limit
support, and `CONFIG_COMPAT` is off, so 32-bit userspace does not run — see
[KNOWN-LIMITS.md](KNOWN-LIMITS.md).

Two things genuinely must happen on the host side, and both are done without
privilege:

- **`stub_exe`** — memfd exec is refused by the Termux sandbox, so the tiny
  helper UML execs must be a real file on disk. Hence `stub_exe=<path>` is
  mandatory on the kernel command line.
- **Networking** — implemented by a second unprivileged process (gvproxy) instead
  of a tap device or `CAP_NET_ADMIN`.

## 5. Syscall interception

Guest code runs **natively** on the same CPU architecture; only syscalls are
emulated. Two mechanisms, and the choice of mechanism decides both speed and CPU
count.

### seccomp mode (fast, multi-CPU)

The UML process installs a BPF seccomp filter; the guest kernel traps guest
syscalls with `SECCOMP_RET_TRAP`-style handling and services them in-process.
Cost is on the order of a normal trap: upstream ~2.7 µs/syscall, **~2.0 µs
measured in-app**. `Userspace mode: SECCOMP` appears in the boot log. This is the
only mode in which `ncpus=4` yields 4 guest CPUs.

### ptrace mode (slow, single CPU)

The supervisor uses `PTRACE_SYSEMU`: the tracee is stopped *before* entering the
syscall, so no real host syscall happens for the guest's syscall, and the number
is emulated. Upstream ~25 µs/syscall — roughly 10× more expensive. Inside the
Termux app sandbox this is the **default**, and it prints:

```
SMP is not supported with ptrace userspace; running on 1 CPU instead of the 7 requested
```

Hence, in practice: **force `seccomp=on` if you want Docker to be usable, and
expect one CPU if you leave it on the default.**

### Prerequisites, cancellation and substitution fallbacks

`PTRACE_SYSEMU` was added on arm64 in Linux 5.3; this host is 6.1, so the fast
path exists and the boot-time checks pass. Where it does not exist, UML falls
back to older schemes — exposing the syscall by *cancelling* it (`-ENOSYS` and
rewriting the number, `nosysemu`) or by *substituting* the syscall with a benign
one and acting on the return path (`nocancel`). Both cost more per syscall and
have known corner cases around restartable syscalls and cancellation of
partially-visible effects.

The `nosysemu` / `nocancel` knobs were **not exercised on this device** (they are
unnecessary here), so their behaviour under this port is unverified. Treat them
as debug switches, not as a supported configuration.

### What is *not* intercepted

- Ordinary computation, memory access and page faults: native instruction
  execution, with page faults costing ~7.6× native per page (1.77× per byte at
  16 KB guest pages).
- Interrupts, timers and scheduling inside the guest: guest-kernel constructs
  built on host `timerfd`/`signal` facilities.
- The guest's vDSO time is *not* merged with the host's — upstream flags this as
  unmerged work in this port.

## 6. Transport stack

The guest's `vec0` net device is a **vector transport**: a userspace backend,
selected on the kernel command line, so no host network interface is created.

### Two backends

| Backend | Selection | What is on the other end | Status |
|---|---|---|---|
| `fd` | `vec0:transport=fd,...` | a userspace TCP/IP helper (`passt`) started by a bridge helper (`umnet`) | outbound works; **inbound does not** |
| `bess` | `vec0:transport=bess,dst=<unix socket>,depth=128,gro=1,mac=...` | `gvproxy`'s tap-over-BESS listener | **used by this project**; outbound *and* inbound work |

`bess` is native in this arm64 port (`TRANS_BESS` in the vector backend,
connecting to a UNIX socket as an instance of the BESS protocol).

### Why gvproxy rather than passt

`passt` is a capable userspace TCP/IP stack and it *does* give the guest DHCP,
DNS and outbound TCP without a tap device or `CAP_NET_ADMIN`. The reason this
project does not ship it is narrower and purely empirical:

- The released bridge helper hardcodes `-t none -u none` into `passt` — its own
  comment states that the guest gets outbound connectivity and nothing on the
  phone's network can reach into it. So inbound forwarding is off by design.
- Patching that to `-t 127.0.0.1/8123` makes `passt` **accept** the connection and
  then never forward a byte (host-side `connect()` times out rather than being
  refused). The same happens for a guest container on `--network host`, which
  rules out Docker's netfilter/NAT as the cause: there is no DNAT in that path.

So: outbound-only for `passt`+`umnet` as released; `gvproxy` is what makes
container ports reachable from the phone. Full reasoning in
[FORENSICS.md](FORENSICS.md#7-the-passt-inbound-failure).

### gvproxy details that matter

- Needs `/etc/resolv.conf`, which Android does not have → run it under
  `proot -b $PREFIX/etc:/etc`. Without that it fails to start DNS resolution.
- Serves the forwarder API over UNIX socket `$TMPDIR/gvnet.sock`; exposes
  `127.0.0.1:2222 → guest:22` by default.
- **Dies when the BESS peer disconnects** (`cannot receive packets from @ ...
  EOF`), so it must be started once per UML run. This is a mobility hazard — see
  [MOBILITY.md](MOBILITY.md).
- Port mapping is one-to-one: `expose` the exact guest port a container
  published (`-p 8123:80` in the guest ⇒ expose `192.168.127.2:8123`).

### Address plan

| Who | Address |
|---|---|
| guest `vec0` | `192.168.127.2/24` (DHCP lease, 3600 s) |
| guest gateway and DNS | `192.168.127.1` |
| containers | `172.17.0.2` and up on guest `docker0` |
| phone-side listener | `127.0.0.1:<port>` created by the forwarder API |

## 7. Console and init

### Console

The kernel command line **must** be:

```
con=null con0=null,fd:1
```

Rationale, measured: if the console is given a regular-file descriptor, the
`epoll_ctl` that the console path performs fails with `EPERM` and the console
dies **silently** — no error, no output. `con=null con0=null,fd:1` keeps the
console off the kernel's logging path while still giving guest output a usable
descriptor, which is why the forensics boot logs exist at all. `console=tty0` is
only relevant if you want a getty prompt from a distribution init.

### Init

The guest does **not** boot a distribution init as PID 1:

- **OpenRC as PID 1 hangs** under this port.
- The console cannot be typed into from a pipe, so an interactive first boot is
  not a reliable automation target.
- `exit` in the guest hangs the UML process; the guest must **power itself off**
  (`poweroff -f`).

The working design is a small self-built cpio `newc` initramfs whose `/init`
runs a script, then hands over to the real root filesystem:

```
guest kernel boots
  └─ /init  (from initramfs: minimal, non-interactive, deterministic)
       ├─ mount /dev/ubda  →  /newroot        (the Debian/Docker disk image)
       ├─ copy the run script into the image   (so the run is reproducible)
       ├─ mount cgroup2, mount tmpfs
       └─ switch_root /newroot /umarm-init
            └─ /umarm-init  (PID 1 in the real root; minimal)
                 ├─ bring up lo and vec0 (DHCP)
                 ├─ start containerd, then dockerd
                 ├─ run the checks that print the marker strings
                 └─ poweroff -f        (never `exit`)
```

Why `switch_root` + a minimal init rather than a full init system:

1. **Determinism.** The sequence is fixed and prints marker strings, which is what
   makes a run judgeable (see [../evidence/README.md](../evidence/README.md)).
2. **No dependency on a distribution init working under UML**, which it does not.
3. **It cannot hang on interactive input**, because nothing reads the console.
4. **Shutdown is explicit** (`poweroff -f`), avoiding the `exit`-hangs-guest trap.

The guest keeps running until it powers itself off; the host side waits for
markers, not for a process exit code.

Two guest-side details that bite:

- `mount -t cgroup2 none /sys/fs/cgroup` is required before dockerd, else the
  guest's cgroup v2 hierarchy is not mounted.
- Before restarting dockerd in the same guest, clear `/run/containerd`,
  `/run/docker` and `/var/run/docker.pid`, or the second start fails on stale
  state.
- `ip addr add 127.0.0.1/8 dev lo` returns `Address already assigned` — the loopback
  address is already there. Scripts that add it unconditionally abort before ever
  configuring `vec0`; that exact failure was observed and is documented in
  [FORENSICS.md](FORENSICS.md#6-network-bring-up-and-the-address-already-assigned-trap).

## 8. Trust model

State this where users will read it: **UML is not a security sandbox.**

- The guest kernel is a large attack surface running with the app's privileges.
  A guest-kernel bug that reaches the host through the syscall emulation seam is
  a bug in the app's process, not in a hypervisor.
- `hostfs` publishes host storage into the guest. Never use it with untrusted
  guest code; use a rootfs image.
- Anything that can reach `$TMPDIR/gvnet.sock` can create listeners on the phone's
  loopback. Treat that socket as a trusted control channel and do not hand it to
  other apps.
- `dockerd` in the guest runs as guest root. Containers are isolated by the guest
  kernel, not by Android.

See also [KNOWN-LIMITS.md](KNOWN-LIMITS.md#hostfs-and-integrity).
