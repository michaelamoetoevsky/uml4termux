# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2026-10-26
### Verified
- **32-bit (i386) container images**: `qemu-user-static` + binfmt_misc inside the guest runs `i386/alpine` (`uname -m` → `i686`); binfmt_misc is mountable in the guest kernel, the handler registers with `PF` flags. The kernel still has no native 32-bit support (`CONFIG_COMPAT` off) — this is user-mode emulation.
- **Docker Compose v2.29.7 (aarch64)**: a two-service stack with `depends_on` came up (`stack-web-1`, `stack-worker-1`), the web service logged its expected output, and `down -v` removed everything cleanly.
- **BuildKit**: `DOCKER_BUILDKIT=1 docker build` completes against the in-guest dockerd.
- **Cgroup memory limit with a real OOM kill**: `--memory 64m` sets `memory.max=67108864` on the container's cgroup (`/sys/fs/cgroup/docker/<id>`), and an anonymous-RSS workload is OOM-killed (`OOMKilled=true`, exit 137). Without a limit the same allocator peaks at 146 MB and survives.
- **Cgroup cpu limit**: `--cpus 0.5` yields `cpu.max` = `50000 100000` read from inside the container.
- **IPv6 container networking works** (corrects 0.1.0): two containers on a user-defined `--ipv6` network ping each other over `fd00:9::/64` with 0% packet loss both ways (avg 1.8 / 3.8 ms). The bridge is DOWN at `docker network create` time — when dockerd logs its `network is down` route error — and comes UP when the first container attaches; the daemon error is cosmetic.
- **60-minute stability soak**: dockerd up the whole hour, 43 container cycles, 87 guest samples + 121 phone-side samples, **zero `BUG:`/`Oops`/`WARNING:` lines in guest dmesg**, guest `MemAvailable` ≈ 0.9 GB at the end.
- **gvproxy supervisor + persistent port exposures**: gvproxy is restarted automatically for the lifetime of the UML instance and every recorded forward is re-applied after a restart (previously each BESS EOF dropped all forwards until they were re-issued by hand).
- **`--wake-lock` flag**: `uml4termux boot|docker --wake-lock` holds a Termux wake lock for the lifetime of the instance (released by `uml4termux stop`) so the screen being off does not freeze the VM.

### Known Limits (new or corrected)
- **Cgroup io limits are absent**: the io controller exposes `io.stat` only — `io.max` does not exist, so `--device-*-bps` cannot be enforced.
- **tmpfs and page cache are not charged to the cgroup** (`CONFIG_MEMCG=y`, no `CONFIG_MEMCG_KMEM`): a 200 MB tmpfs write inside a 64 MB-limited container left `memory.current` at ~5 MB. Memory limits cap anonymous RSS only.
- **IPv6 correction**: the 0.1.0 "does not work" claim is retracted; see above.

## [0.1.0] - 2026-10-26
### Verified
- **UML arm64 boot in Termux**: User-Mode Linux (arch/um, SUBARCH=arm64) built from the downstream port (zalexdev/Raymer8639) boots as an unprivileged userspace process on Android/Termux (Android 16, aarch64). No root, no KVM, no tap device.
- **Docker 20.10.24 with overlay2 on cgroup v2**: the guest runs `dockerd` 20.10.24 with the `overlay2` storage driver (native overlay diff) over the **guest kernel's own** cgroup v2 hierarchy (`cpu io memory pids`), with runc + containerd; verified with `docker pull`, `run`, `exec`, `logs`, a volume, a user-defined bridge with embedded DNS, and a nested `docker build` performed inside the guest.
- **seccomp fast path with 4 vCPUs**: inside the Termux app sandbox UML defaults to `ptrace`, which forces 1 CPU; forcing `seccomp=on` selects `Userspace mode: SECCOMP` and `ncpus=4` yields 4 guest CPUs. Measured on the test device (same guest, same workloads): 4.44 µs vs 81.07 µs per cheap syscall (`getppid`) and 237 µs vs 575 µs per `open`, while fork/exec, `ls -R` and `docker run` completed within ~10–25% of each other.
- **gvproxy + BESS networking**: userspace TCP/IP stack (gvproxy v0.9.0) attached to UML's BESS transport (`vec0:transport=bess,dst=…`); the guest gets DHCP (`192.168.127.2/24`, gateway/DNS `192.168.127.1`) and the port-forwarding HTTP API exposes guest services on the phone's loopback.
- **Container port reachable on the phone's 127.0.0.1 via the forwarding API**: a bridge-published container and a `--network host` container were both served to `127.0.0.1:8123` / `:8124` from the Termux shell, in the same run in which outbound DNS and registry pulls worked.
- **Stability under repetition**: 30 container create/run/remove cycles in one boot left guest `MemAvailable` and process count flat, shrank `/var/lib/docker` after removal, produced no `BUG:`/`WARNING:`/`Oops` in the guest `dmesg`, and the guest was still serving its published port afterwards; an externally SIGKILLed guest left a cleanly recovering ext4 image (`EXT4-fs (ubda): recovery complete` on the next boot).

### Known Limits
- **No cpuset controller**: the **guest kernel** has `CONFIG_CPUSETS` unset, so `docker info` warns "No cpuset support" and `--cpuset-cpus` cannot be enforced.
- **No swap-limit support**: the guest kernel has no swap accounting, so `--memory-swap` warns and the swap limit is not enforced.
- **No kernel modules**: the released bionic kernel was built with `# CONFIG_MODULES is not set`, so `modprobe`/`rmmod`, out-of-tree drivers and firmware loading do not work with that binary (the downstream source supports modules; this build does not enable them).
- **IPv6 container networking fails**: `docker network create --ipv6` creates the network object, but `dockerd` logs `Could not add route to IPv6 network fd00:1::1/64 via device br-…: network is down`. The guest kernel does have `CONFIG_IPV6`, `CONFIG_NF_TABLES_IPV6`, `CONFIG_IP6_NF_IPTABLES` and `CONFIG_IP6_NF_NAT`, so this is a bridge/daemon-level gap rather than a missing kernel symbol.
- **OOM-kill enforcement untested**: `--memory` limits are applied (`memory.max` observed at `67108864` for `--memory=64m`) and `--pids-limit` is enforced (hit at 14 of 16), but the probe never actually exceeded the memory limit, so an in-guest OOM kill remains unverified.
- **No 32-bit compat**: the arm64 UML port is built with `CONFIG_COMPAT` off; 32-bit ELF binaries (armv7/i386) do not execute.
- **Phantom-process risk (Android)**: keep the app in the foreground and/or disable child-process restrictions; the guest, `dockerd`, `containerd` and every container are host processes, and Android 12+ trims background children past ~32 system-wide. Stop a guest through the PID the CLI records (`uml4termux stop`), never with a pattern kill — a pattern kill also kills unrelated runs.
- **UML is not a VM-grade isolation boundary**: `hostfs` was verified to mount a host directory inside the guest and read host files as the invoking user. Do not use hostfs with untrusted guest code (see SECURITY.md).