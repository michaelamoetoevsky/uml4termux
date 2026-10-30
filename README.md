# uml4termux

## Bahasa Indonesia (ringkas)

`uml4termux` menjalankan kernel Linux asli sebagai proses biasa di dalam Termux —
tanpa root, tanpa KVM, tanpa hypervisor, tanpa tap device, tanpa capability.
Docker berjalan **di dalam kernel guest itu**, jadi namespace, cgroup, overlayfs
dan netfilter diimplementasikan oleh kernel guest sendiri, bukan oleh kernel
Android.

Yang sudah terbukti di device uji: UML arm64 boot tanpa root, `dockerd` 20.10.24
dengan storage driver `overlay2` (cgroup v2: `cpu io memory pids`), `docker pull`
/ `run` / `exec` / `logs`, ping antar-container lewat `docker0`, dan — ini yang
paling penting — **port container bisa diakses dari HP lewat `127.0.0.1`** memakai
`gvproxy` + transport BESS. Jaringan keluar (DNS, registry pull) dan masuk
(port-forward) hidup bersamaan.

Yang **belum** terbukti: bridge `passt` + `umnet` versi rilis tidak bisa
meneruskan koneksi masuk (outbound saja), `CONFIG_CPUSETS` tidak ada di guest,
tidak ada dukungan 32-bit, dan proyek ini bukan sandbox keamanan.

Titik awal: [60-second quickstart](#60-second-quickstart), lalu
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) dan [docs/FORENSICS.md](docs/FORENSICS.md).
Daftar lengkap yang terbukti vs tidak terbukti ada di
[Verified / not verified](#verified--not-verified) di bawah.

---

Run a real Linux kernel — and real Docker — as an ordinary unprivileged app
process inside Termux on Android. No root, no `/dev/kvm`, no hypervisor, no tap
device, no Linux capability.

`uml4termux` is a **userland UX and packaging layer**: it wraps the downstream
arm64 User-Mode Linux port with prebuilt kernels, an unprivileged launcher,
userspace networking that also does inbound port forwarding, a Docker-in-guest
runbook, and device-evidence recording. It is **not a kernel fork** and it does
not carry kernel patches of its own (see [docs/UPSTREAM.md](docs/UPSTREAM.md)).

## How it works (one paragraph)

You run one ordinary aarch64 executable. That executable *is* the kernel: it
maps a guest address space, executes guest instructions natively at host speed,
and intercepts the guest's system calls, emulating each one against the host
kernel. Because that guest kernel is a complete Linux kernel, it implements
namespaces, cgroups, overlayfs, bridges, veth and netfilter **itself** — which is
exactly what Docker needs and exactly what an unprivileged Termux process cannot
get from Android. The guest's ethernet device is a vector transport speaking
BESS over a UNIX socket to `gvproxy`, a userspace TCP/IP stack; that gives the
guest DHCP, DNS and outbound TCP *and* lets container ports be forwarded back on
to the phone's own loopback.

```
                         Termux app process (CapEff=0, app seccomp filter active)
 ┌──────────────────────────────────────────────────────────────────────────────────┐
 │                                                                                  │
 │   linux-bionic-smp  ──── is ────►  aarch64 ELF that IS the guest kernel          │
 │        │                                     │                                   │
 │        │ maps guest address space            │ guest syscall intercepted         │
 │        │ (stub_exe holds it)                 │ (seccomp, else ptrace)            │
 │        │                                     ▼                                   │
 │        │                            emulated against the HOST kernel             │
 │        ▼                                                                         │
 │   guest kernel 7.2.0-rc4 (16 KB guest pages on a 4 KB host)                      │
 │        ├── namespaces / cgroup v2 / overlayfs / bridge+veth / netfilter          │
 │        ├── /dev/ubda  ←── debian-docker.ext4   (guest rootfs)                     │
 │        └── vec0  ──── BESS over unixpacket ────►  gvproxy v0.9.0 (userspace TCP/IP)│
 │                DHCP 192.168.127.2/24, gw+DNS 192.168.127.1                      │
 │                                                     │                            │
 │   dockerd 20.10.24 + containerd 1.6.20 + runc ──────┼── outbound: pull, DNS, HTTP │
 │        └── containers on docker0 (172.17.0.2)       │                            │
 │                                                     ▼                            │
 │                                            $TMPDIR/gvnet.sock  (HTTP API)        │
 │                                            POST /services/forwarder/expose      │
 │                                                     │                            │
 └─────────────────────────────────────────────────────┼────────────────────────────┘
                                                       ▼
                                    127.0.0.1:8123  →  guest 192.168.127.2:8123
                                    (reachable from the phone, any app or browser)
```

Networking is **entirely in userspace on both ends**: no `/dev/net/tun`, no
`CAP_NET_ADMIN`, no root.

## 60-second quickstart

Everything below is a real, verified command sequence on the reference device.
Paths assume you are in a directory holding the release assets: the kernel
(`linux-bionic-smp`), `stub_exe`, an Alpine initramfs, the Debian+Docker disk
image (`debian-docker.ext4`) and `gvproxy`. Adapt names to the assets you have.

**0. Check the gate before you believe anything.**

```sh
chmod +x linux-bionic-smp stub_exe gvproxy
uname -m                      # must be aarch64
```

**1. Get a shell in a real kernel (no networking, no root, no Docker).**

```sh
./linux-bionic-smp mem=512M \
  initrd=initramfs-alpine.cpio.gz rdinit=/bin/sh \
  stub_exe=$PWD/stub_exe panic=-1 \
  con=null con0=fd:0,fd:1
```

You should see the kernel banner (`Linux version 7.2.0-rc4-...`) and a shell
prompt **inside the guest**. Leave with `poweroff -f` — never `exit`, which hangs
the UML process.

**2. Docker + working networking in the guest.**

```sh
# host: gvproxy needs /etc/resolv.conf, which Android does not have
proot -b $PREFIX/etc:/etc ./gvproxy -debug \
  -listen unix://$TMPDIR/gvnet.sock \
  -listen-bess unixpacket://$TMPDIR/bess.sock \
  -log-file gvproxy.log &

# host: boot the guest, seccomp mode (multi-CPU) + BESS transport
./linux-bionic-smp mem=1024M ncpus=4 seccomp=on \
  ubd0=./debian-docker.ext4 root=/dev/ubda rw \
  init=/umarm-init stub_exe=$PWD/stub_exe panic=-1 \
  con=null con0=fd:0,fd:1 \
  vec0:transport=bess,dst=$TMPDIR/bess.sock,depth=128,gro=1,mac=5a:94:ef:e4:0c:ee
```

Inside the guest: `dhclient -1 -v vec0` (lease `192.168.127.2/24`, gateway and DNS
`192.168.127.1`), then start containerd + dockerd and check:

```sh
zcat /proc/config.gz | grep -E 'CONFIG_OVERLAY_FS|CONFIG_VETH|CONFIG_MEMCG'
cat /sys/fs/cgroup/cgroup.controllers        # expect: cpu io memory pids
docker info | grep -E 'Storage Driver|Backing Filesystem'
docker run --rm hello-world
```

**3. Reach the container from the phone.**

```sh
# host: publish the container port onto the phone's loopback
curl --unix-socket $TMPDIR/gvnet.sock -X POST \
  -d '{"local":"127.0.0.1:8123","remote":"192.168.127.2:8123"}' \
  http://unix/services/forwarder/expose

curl -i http://127.0.0.1:8123/          # served by the container, from the phone
```

The packaged entrypoint that automates steps 1–3 (launcher, gvproxy lifecycle,
expose, verdict) lives in `bin/`; run it with `--help` for its flags. The raw
sequence above is the verified mechanics that entrypoint wraps.

## Daemon quickstart (v0.5.0: one binary, three commands)

Since v0.4.0 the recommended user flow is the daemon, not the raw UML command
line. One binary, `uml4termuxd`, is both supervisor and client; a runit service
keeps it alive (see `packaging/service/`).

```sh
# 1. configure (once): paths to the release assets
cp packaging/service/daemon.conf.example ~/.uml4termux/daemon.conf
$EDITOR ~/.uml4termux/daemon.conf        # kernel/stub/image/initramfs/gvproxy

# 2. run the daemon (runit runs this on boot; foreground here for a first try)
UML4TERMUX_RUNTIME=~/.uml4termux/runtime ./bin/uml4termuxd daemon

# 3. drive it from another shell (or via the runit service)
./bin/uml4termuxd status                 # supervisor state (JSON)
./bin/uml4termuxd exec "uname -a"        # run a command inside the guest
./bin/uml4termuxd exec "docker run -d -p 8123:80 nginx"
./bin/uml4termuxd expose 8123 8123       # guest port -> phone loopback
./bin/uml4termuxd console 30             # tail the guest console
./bin/uml4termuxd stop                   # clean poweroff via console channel
```

## Launcher without runit (`up` / `down` / `status` / `logs` / `ls` / `rotate` / `snapshot` / `snapshots`)

`lib/launch.sh` + `lib/registry.sh` give the daemon a portable front end. Nothing
in that path calls runit: readiness is *polled* (the socket answers `protocol`
**and** reports `phase=running`), not assumed, and each instance gets a registry
record under `$UML4TERMUX_STATE_DIR/instances/<name>.env`.

```sh
./bin/uml4termux up --name dev --image ~/uml/debian-docker.ext4
./bin/uml4termux status --name dev      # phase, pid, ssh port, log size
./bin/uml4termux logs --name dev --console -f
./bin/uml4termux rotate --name dev      # or --all, from a supervisor tick/cron
./bin/uml4termux ls                     # every registered instance + liveness
./bin/uml4termux down --name dev
```

Three invariants are **refused**, not merely warned about, because each of them
was a silent failure once already: one guest per backing image (UML holds an
exclusive `F_SETLK`), one gvproxy per host ssh port (`2222` is taken once; the
next instance needs `UML4TERMUXD_GVPROXY_SSH_PORT`), one runtime directory per
instance.

Any supervisor can drive it -- every adapter execs the same hook,
`uml4termux up --foreground` (exit 0 = deliberate stop, non-zero = crash):

| Supervisor | Adapter |
|---|---|
| systemd | `packaging/adapters/systemd/uml4termux@.service` |
| s6 | `packaging/adapters/s6/{run,finish}` |
| plain shell / CI | `packaging/adapters/plain/supervise.sh` |
| runit | `packaging/adapters/runit/run` |

The contract behind all of it -- exit codes, state file, log layout and rotation,
phase vocabulary -- is `docs/RUNTIME-CONTRACT.md`, enforced by
`tests/test-runtime-contract.sh`, `tests/test-launcher.sh`,
`tests/test-log-rotation.sh` and `tests/test-adapters.sh`.

### Snapshot & resume (direction C)

A snapshot is **cold state**: the guest is stopped cleanly, its COW -- the only
file that holds guest writes -- is copied aside together with a record of what it
was taken against, and `up --from <label>` copies that back as the working COW.

```sh
./bin/uml4termux snapshot before-upgrade --name dev    # stop cleanly, copy, record
./bin/uml4termux snapshots --name dev                  # label, time, sizes, guest kernel
./bin/uml4termux up --from before-upgrade --name dev   # resume (costs one boot)
./bin/uml4termux snapshot --rm before-upgrade
```

Snapshots are **immutable**: every resume copies, so the same label can be resumed
twice and the two guests never see each other's writes. What comes back is the
filesystem, **not RAM** -- processes that were running do not come back, and
resuming costs one boot. This port has no RAM save/restore, so do not read
"resume" as "instant".

A resume is also refused when the instance is **still live** -- `up` would otherwise
adopt the running daemon and report success without resuming anything -- so stop it
first (`uml4termux down`), which is what the error message tells you to do.

A resume is refused **before anything is staged** when the backing image no longer
matches the snapshot's record (size + mtime always; `sha256` as well when
`UML4TERMUX_SNAPSHOT_VERIFY_DIGEST=1`), and the message names both numbers.
Rotation keeps the newest `UML4TERMUX_SNAPSHOT_KEEP` (default 5) by mtime.

The daemon side of that promise is one rule: the boot path writes a COW header only
when the file is missing or is not a valid v3 header, so a COW the launcher staged
is what the guest boots from. A fresh `up` deletes the working COW first, which
keeps the fresh-vs-resume decision in exactly one place (`lib/launch.sh`) instead
of duplicating it in C and Rust -- and the `cow-ensure` parity gate in CI checks
that both implementations reach the same decision.

Enforced by `tests/test-snapshot.sh` (file level, no daemon), the `cow-ensure`
parity gate, and `soak/snapshot-check.sh` on a device with real boots.

Useful daemon knobs (env, all per-instance):

| knob | effect |
| --- | --- |
| `UML4TERMUXD_COW=<path>` | UML copy-on-write file for guest writes; the backing image stays pristine. A header is written only when the file is missing or invalid, so a staged snapshot (`up --from`) is resumed rather than reset -- a fresh `up` deletes the file first |
| `UML4TERMUXD_HTTP=127.0.0.1:9110` | optional loopback HTTP health endpoint, `GET /status` → JSON |
| `UML4TERMUXD_MEM=512M` / `UML4TERMUXD_NCPUS=4` | guest memory / vCPU budget |
| `UML4TERMUX_RUNTIME=<dir>` | control socket + state + console log (one dir per guest instance) |

Multi-guest: run one daemon per guest with distinct `UML4TERMUX_RUNTIME`,
`UML4TERMUXD_BESS` and (optionally) `UML4TERMUXD_COW` — all data-plane sockets
are unix, so instances cannot collide on TCP (verified with 2 × 256M guests;
see `docs/ROADMAP-0.4.md` §B3 and `packaging/service/daemon.conf.example`).

## Verified capability table

All rows were measured on the reference device (Android 16, host kernel
`6.1.157-android14-11`, aarch64 Armv9 with PAC/SVE2, Termux app sandbox,
`CapEff=0`, app seccomp filter active). "Verified" means observed here, not
quoted from an upstream README.

| Capability | Status | Evidence |
|---|---|---|
| Boot UML arm64 unprivileged, inside the Termux sandbox | **verified** | boot gate marker; `Userspace mode: ptrace` then `Userspace mode: SECCOMP`; guest banner `Linux version 7.2.0-rc4` |
| `PTRACE_SYSEMU` available (fast-path prereq) | **verified** | host 6.1 ≥ 5.3; boot-time check passes |
| Guest page size 16 KB on a 4 KB host | **verified** | `CONFIG_PAGE_SIZE_16KB=y` in all three released kernels |
| seccomp interception mode + 4 guest CPUs | **verified** | `seccomp=on ncpus=4` → guest reports 4 CPUs |
| ptrace mode forces a single CPU | **verified** | `SMP is not supported with ptrace userspace` |
| `dockerd` in the guest | **verified** | server `20.10.24+dfsg1`, storage driver `overlay2`, cgroup v2, controllers `cpu io memory pids` |
| overlay2 uses Native Overlay Diff on extfs backing | **verified** | `docker info`: `Native Overlay Diff: true`, `Backing Filesystem: extfs` |
| `docker pull`, `run`, `exec`, `logs` | **verified** | hello-world, alpine, busybox pulled through the NAT and run |
| Container-to-container networking | **verified** | ping `172.17.0.2` on `docker0`, 0% packet loss |
| Docker published port reachable inside the guest | **verified** | `0.0.0.0:8123->80/tcp` |
| Container port reachable from the **phone** on `127.0.0.1` | **verified** | `gvproxy` + BESS; `POST /services/forwarder/expose`; `HTTP/1.1 200 OK` — for a bridge-published container *and* a `--network host` container |
| Guest outbound: DHCP, external DNS, registry pulls | **verified** | lease `192.168.127.2/24`, gw/DNS `192.168.127.1`, DNS resolution and image pulls succeed |
| Inbound forwarding via released `passt` + `umnet` | **fails (outbound only)** | `umnet` hardcodes `-t none -u none`; patched to `-t 127.0.0.1/8123` it still accepts without forwarding |
| Multi-CPU with ptrace | **not supported** | 1 CPU only |
| Run all three released kernels with Docker | **only two of three** | the non-SMP `linux-bionic` lacks `OVERLAY_FS`/`VETH`/`BRIDGE`/`NETFILTER`/`PID_NS`/`USER_NS`/`MEMCG`/`CGROUP_PIDS` |
| cpuset controller | **absent** | `CONFIG_CPUSETS` not set; `docker info` warns "No cpuset support" |
| swap limit support | **absent** | guest kernel gap |
| 32-bit (i386 / armv7) userspace | **via qemu-user emulation** | native: `CONFIG_COMPAT` off; emulated: `qemu-user-static` + binfmt_misc inside the guest runs `i386/alpine` (`uname -m` → `i686`) |
| IPv6 container networking | **verified** | two containers on `--ipv6` network ping each other over `fd00:9::/64`, 0% loss both ways (avg 1.8/3.8 ms) |
| Compose (v2.29.7, aarch64 binary) | **verified** | two-service stack (web + `depends_on` worker) `up -d` → both running, `down -v` clean |
| BuildKit build | **verified** | `DOCKER_BUILDKIT=1 docker build` completes (`#6 DONE`) |
| cgroup memory limit + OOM kill | **verified** | `--memory 64m`: `memory.max=67108864` set; an anonymous-RSS workload is OOM-killed (`OOMKilled=true`, exit 137); without a limit the same allocator peaks at 146 MB and survives |
| cgroup cpu limit | **verified** | `--cpus 0.5` → `cpu.max` = `50000 100000` read from inside the container |
| cgroup io limit (`io.max`) | **absent** | cgroup v2 exposes `io.stat` only — `--device-*-bps` cannot be enforced |
| tmpfs / page-cache charging | **absent** | `CONFIG_MEMCG_KMEM` unset: a 200 MB tmpfs write inside a 64 MB-limited container never approached the limit (`memory.current` ≈ 5 MB) |
| `stub_exe` mandatory | **verified** | memfd exec is refused by the sandbox |
| `con=null con0=null,fd:1` mandatory | **verified** | a regular-file fd fails `epoll_ctl` with `EPERM` and the console dies silently |
| OpenRC as PID 1 | **hangs** | minimal init + `switch_root` used instead |
| `poweroff -f` instead of `exit` | **required** | `exit` hangs the guest |

Numbers, not adjectives: upstream reports ~2.7 µs/syscall (seccomp) versus ~25 µs
(ptrace); **~2.0 µs/syscall was measured in-app for seccomp**. Guest page faults
cost ~7.6× native per page (1.77× per byte at 16 KB guest pages).

## Project layout

```
uml4termux/
├── README.md              this file (bilingual)
├── LICENSE                GPL-2.0-only + project notice
├── docs/
│   ├── ARCHITECTURE.md    processes, privilege boundaries, interception, transport
│   ├── FORENSICS.md       the evidence-backed investigation + how to reproduce
│   ├── MOBILITY.md        Android lifecycle/stability: phantom killer, LMK, doze
│   ├── CI-CD.md           what CI can and cannot check; evidence and releases
│   ├── KNOWN-LIMITS.md    what does not work, stated plainly
│   ├── FAQ.md             short answers to the questions people actually ask
│   └── UPSTREAM.md        relationship to UML upstream, the forks, the packaging PR
├── evidence/
│   ├── README.md          how device evidence is recorded, named and validated
│   └── schema.json        schema for the run summary JSON (version 1)
├── bin/                   launcher + harness entrypoints          (harness-owned)
├── lib/                   shared shell helpers                     (harness-owned)
├── scripts/               device probe / verification scripts      (harness-owned)
└── packaging/             Termux-facing packaging glue             (harness-owned)
```

Directories marked *harness-owned* are implemented by the harness side of the
project; this documentation set does not define their contents.

## Documentation map

| Document | Read it when |
|---|---|
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | you want to know *why* unprivileged works and where the trust boundaries are |
| [docs/FORENSICS.md](docs/FORENSICS.md) | you want the measurements, the traps and the commands that reproduce them |
| [docs/MOBILITY.md](docs/MOBILITY.md) | you want it to survive Android's lifecycle on a real phone |
| [docs/CI-CD.md](docs/CI-CD.md) | you are changing CI, evidence or the release process |
| [docs/KNOWN-LIMITS.md](docs/KNOWN-LIMITS.md) | you are deciding whether this fits your use case |
| [docs/NEXT-STEPS.md](docs/NEXT-STEPS.md) | you want to know where the project is going next (seven directions, A–G) |
| [docs/RUNTIME-CONTRACT.md](docs/RUNTIME-CONTRACT.md) | you are integrating with the daemon (socket paths, protocol, exit codes, invariants — v1) |
| [docs/RUST-MIGRATION-AUDIT.md](docs/RUST-MIGRATION-AUDIT.md) | you are deciding which component (if any) should be written in Rust |
| [docs/FAQ.md](docs/FAQ.md) | you have a specific yes/no question |
| [docs/UPSTREAM.md](docs/UPSTREAM.md) | you want to contribute kernel patches upstream |
| [evidence/README.md](evidence/README.md) | you are recording or validating a device run |

## Verified / not verified

This is the section to read before repeating any claim from this repository
elsewhere. **Anything not listed under "verified" is unverified.**

### Verified — measured on the reference device

Host: Android 16, kernel `6.1.157-android14-11`, aarch64 Armv9
(`paca pacg sve sve2 bti sha3`), Termux app sandbox, `CapEff=0`, app seccomp
filter active, `/proc/sys` not readable.

- Unprivileged boot of the downstream arm64 UML port; `PTRACE_SYSEMU` available
  (host 6.1 ≥ 5.3), so no `nosysemu` fallback is needed.
- Interception modes: `ptrace` is the default inside the sandbox and forces one
  CPU; `seccomp=on` reports `Userspace mode: SECCOMP` and with `ncpus=4` the
  guest reports 4 CPUs. ~2.0 µs/syscall measured in-app for seccomp;
  upstream figures are ~2.7 µs (seccomp) and ~25 µs (ptrace).
- Docker inside the guest: 20.10.24+dfsg1, overlay2 (Native Overlay Diff on
  extfs), cgroup v2 with `cpu io memory pids`, runc + containerd 1.6.20, seccomp
  default profile, cgroupns; pull/run/exec/logs; container-to-container ping on
  `docker0` (0% loss); published port reachable inside the guest.
- Networking: gvproxy v0.9.0 (linux-arm64) over
  `vec0:transport=bess,dst=$TMPDIR/bess.sock,depth=128,gro=1,mac=...`; DHCP lease
  `192.168.127.2/24`, gateway/DNS `192.168.127.1`; external DNS and registry
  pulls work; container ports exposed to the phone's loopback via the
  `services/forwarder/expose` API (verified for a bridge-published container and
  a `--network host` container); gvproxy also serves `127.0.0.1:2222` → guest:22
  by default.
- Networking limitation: released `passt` + `umnet` cannot forward inbound
  (`umnet` hardcodes `-t none -u none`; patched to `-t 127.0.0.1/8123`, passt
  accepts but never forwards, and a host-network container in the guest times out
  too). Outbound only.
- Host/kernel traps: gvproxy needs `/etc/resolv.conf` (run it under
  `proot -b $PREFIX/etc:/etc`) and exits when the BESS peer disconnects
  (`cannot receive packets from @ ... EOF`) so it must be restarted per run;
  `con=null con0=null,fd:1` is required; never `exit` in the guest; `stub_exe=`
  is mandatory; OpenRC as PID 1 hangs; `ip addr add 127.0.0.1/8 dev lo` fails
  with `Address already assigned`.
- Guest kernel gaps: no `CONFIG_CPUSETS`, no swap limit support, `CONFIG_COMPAT`
  off (native 32-bit), hostfs exposes host storage.
- Capability round 2 (evidence `20261026-capability-round-2.json`): 32-bit
  images run through `qemu-user-static` + binfmt_misc (`i386/alpine` →
  `uname -m` = `i686`); Docker Compose v2.29.7 runs a two-service stack
  (`up -d` → both containers, `down -v` clean); BuildKit builds; cgroup limits
  proven — `memory.max` set and an anonymous-RSS workload OOM-killed
  (`OOMKilled=true`, exit 137) while the same allocator without a limit peaks
  at 146 MB; `cpu.max` enforced (`50000 100000`); **io.max absent** (only
  `io.stat`) and **tmpfs/page cache not charged** (`CONFIG_MEMCG_KMEM` unset,
  so memory limits cap anonymous RSS only).
- IPv6 container networking **works** (refines the 0.1.0 finding): two
  containers on a user-defined `--ipv6` network ping each other over
  `fd00:9::/64` with 0% loss both ways. The bridge is `state DOWN` at
  `docker network create` time — which is when dockerd logs its
  `Could not add route … network is down` error — and comes UP when the first
  container attaches, which is when addresses are handed out. The daemon
  error is cosmetic.
- Stability soak (evidence `20261026-soak-20261026.json`): 60 minutes with
  dockerd up, 43 container cycles, 87 guest samples and 121 phone-side
  samples, **zero `BUG:`/`Oops`/`WARNING:` lines in guest dmesg**, guest
  `MemAvailable` ≈ 0.9 GB at the end, phone memory in a stable band.
- Repeat-boot reliability (evidence `20261026-repeatboot-20261026.json`):
  10/10 independent boots (fresh gvproxy and sockets each time) reached the
  gate marker and powered off cleanly, 1–7 s per boot on a page-cache-warm
  image.

### Not verified — never repeat these as fact

- **Any other device or Android version.** Everything above is one phone. No
  other SoC, Android release, page size or kernel has been tested here.
- **Long-run stability beyond one hour.** A 60-minute soak (43 container
  cycles, 0 kernel bug lines) is now verified; multi-hour runs, restart loops
  over days and memory-leak measurement beyond that window are still not
  performed.
- **USB passthrough** (e.g. a RTL8811AU dongle over USB/IP) — community-reported,
  not measured here.
- **Benchmarks on this device** for the ptrace-vs-seccomp and 1-vs-4-CPU
  comparisons: only the in-app ~2.0 µs/syscall seccomp figure was measured. The
  upstream ratios are quoted, not re-measured.
- **Docker feature completeness.** swarm, `--cpuset-cpus`, swap limits and
  anything requiring the cgroup cpuset controller remain unexercised. Compose,
  BuildKit, 32-bit-via-qemu and the memory-limit OOM path *are* now verified
  (see capability round 2); io limits and tmpfs charging are verified gaps.
- **Any performance claim against proot or QEMU.** Comparative micro-benchmarks
  used for this device were not run by this project; community numbers exist and
  are not reproduced here.
- **The packaging path.** termux-packages PR #32700 is open, not merged; the
  project is not a Termux package and `pkg install` does not install it.
- **Version, tag and commit conventions** in [docs/CI-CD.md](docs/CI-CD.md) are
  project policy, not measured facts.
- **The harness CLI surface** (subcommands, flags, file names under `bin/`,
  `lib/`, `scripts/`, `packaging/` and `.github/`) is owned by the harness side
  of the project and is not specified by this documentation set.

## Links

- Downstream port (upstream of the arm64 work you are running):
  <https://github.com/zalexdev/linux-um-arm64> — branch `um-arm64`,
  Linux 7.2-rc4.
- Packaging fork with bionic builds and a harness:
  <https://github.com/Raymer8639/linux-um-arm64> — the CI kernel source
  (pinned at commit `169b17ff3f66`, which is exactly what the released
  `linux-bionic` reports in `uname -r`).
- Termux packaging PR (open): <https://github.com/termux/termux-packages/pull/32700>
  — adds `linux-kernel-um` (56 aarch64 patches + `docker.config`) and `passt`
  (13 Android patches), API level 30.
- Historical "UML is x86-only, wontfix" position:
  <https://github.com/termux/termux-packages/discussions/8555>.
- Kernel-adjacent reference: gvproxy <https://github.com/containers/gvisor-tap-vsock>.
- UML upstream tree: <https://git.kernel.org/pub/scm/linux/kernel/git/uml/linux.git>
  (see [docs/UPSTREAM.md](docs/UPSTREAM.md)).

## Licence

GPL-2.0-only. See [LICENSE](LICENSE). Redistributed kernel binaries and disk
images remain under their upstream licences (GPL-2.0 and their own terms); see
the notice in [LICENSE](LICENSE) and
[docs/UPSTREAM.md](docs/UPSTREAM.md#imported-artefacts-and-their-licences).

## See also

- [docs/FORENSICS.md](docs/FORENSICS.md) — "how to reproduce every claim",
  including the exact commands behind each row of the table above.
- [docs/MOBILITY.md](docs/MOBILITY.md) — the mitigation checklist that keeps the
  guest alive on a real phone.
- [docs/KNOWN-LIMITS.md](docs/KNOWN-LIMITS.md) — what this cannot do.