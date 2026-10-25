# Forensics

The evidence-backed investigation behind every claim in this repository: what was
measured, how the three released kernels differ, how each failure was localised,
and the commands that reproduce each result. Read
[../evidence/README.md](../evidence/README.md) for how to record a run like these.

Reference device for everything below:

| | |
|---|---|
| Android | 16 — API level well above the API 30 build floor (Android 11+ in practice) |
| Host kernel | `6.1.157-android14-11` |
| Arch | aarch64, Armv9 (`paca pacg sve sve2 bti sha3`) |
| Termux app | `untrusted_app` UID, `CapEff=0000000000000000`, `CapBnd=0` |
| App seccomp | filter active (mode 2) |
| `/proc/sys/*` | unreadable (`Permission denied`) for every entry |
| Guest RAM used in tests | `mem=1024M` |

---

## 1. Boot: does the gate actually pass unprivileged?

```
Linux version 7.2.0-rc4-g856737c31142 (um@arm64) (Android ... clang 21.0.0, LLD 21.0.0)
Address space: host top 0x8000000000, stub at 0x7fffff4000, guest TASK_SIZE 0x7fc0000000
Checking that ptrace can change system call numbers...OK
Checking syscall emulation for ptrace...OK
Userspace mode: ptrace
```

Points that matter:

- The kernel is a normal ELF run from the Termux shell. No root, no `/dev/kvm`, no
  module, no capability.
- `/proc/sys` being unreadable is not fatal: the stub lands at `0x7fffff4000`,
  i.e. the port does not need low addresses, so it does not need to read or write
  `mmap_min_addr`.
- `PTRACE_SYSEMU` works (arm64 since Linux 5.3; host is 6.1), so the fast path
  exists and no `nosysemu`/`nocancel` fallback is needed.
- `stub_exe=<path>` **must** be passed. Executing the stub from memfd is refused
  by the sandbox, so it has to be a file on disk.
- `con=null con0=null,fd:1` **must** be passed. With a regular-file descriptor
  the console's `epoll_ctl` returns `EPERM` and the console dies silently.

## 2. Three released kernels, three different configurations

This is the single most expensive trap in the whole project: two of the three
shipped binaries can run Docker and one cannot, and they are not distinguishable
by name or size.

| | `Raymer.../linux-bionic` (v0.3.0, non-SMP) | `Raymer.../linux-bionic-smp` | `zalexdev/linux` (prebuilt-20260816) |
|---|---|---|---|
| `uname -v` banner | `7.2.0-rc4-g856737c31142` | `7.2.0-rc4-opt ... #1 SMP` | `7.2.0-rc4-g8d984326036a-dirty` |
| `CONFIG_SMP` | **not set** | `=y`, `CONFIG_NR_CPUS=16` | not set, `CONFIG_NR_CPUS=1` |
| `CONFIG_OVERLAY_FS` | **absent** | `=y` | `=y` |
| `CONFIG_VETH` | **absent** | `=y` | `=y` |
| `CONFIG_BRIDGE` | **absent** | `=y` | `=y` |
| `CONFIG_BRIDGE_NETFILTER` | **absent** | `=y` | `=y` |
| `CONFIG_NETFILTER` | **absent** | `=y` | `=y` |
| `CONFIG_NETFILTER_XT_MATCH_CONNTRACK` | **absent** | `=y` | `=y` |
| `CONFIG_PID_NS` / `CONFIG_USER_NS` | **absent** | `=y` / `=y` | `=y` / `=y` |
| `CONFIG_MEMCG` / `CONFIG_CGROUP_PIDS` | **absent** | `=y` / `=y` | `=y` / `=y` |
| `CONFIG_NAMESPACES`, `CONFIG_NET_NS`, `CONFIG_UTS_NS`, `CONFIG_IPC_NS` | `=y` | `=y` | `=y` |
| `CONFIG_CGROUPS`, `CONFIG_CGROUP_SCHED` | `=y` | `=y` | `=y` |
| `CONFIG_PAGE_SIZE_16KB` | `=y` | `=y` | `=y` |
| `CONFIG_PAGE_SIZE_4KB` | absent | absent | absent |
| `CONFIG_SECCOMP` | `=y` | `=y` | `=y` |
| `CONFIG_COMPAT` | **absent** | **absent** | **absent** |
| `CONFIG_CPUSETS` | **absent** | **absent** | **absent** |
| `CONFIG_KALLSYMS`, `CONFIG_DEVTMPFS`, `CONFIG_EXT4_FS`, `CONFIG_BINFMT_ELF` | `=y` | `=y` | `=y` |
| cgroup2 controllers exposed in guest | `cpu io` | `cpu io memory pids` | `cpu io memory pids` |
| Linux namespaces usable | **no** | yes | yes |
| **Docker** | **no** | **yes** | **yes** |

Why the difference exists: a bare `defconfig`-derived config enables essentially
none of the container prerequisites. Docker needs a config fragment (the
packaging PR ships a 142-line `docker.config`, derived from
`moby/contrib/check-config.sh`) on top of the base config. The non-SMP fork build
does not use it, so `dockerd` there would fall back to the `vfs` driver and would
have no namespaces to create containers with.

Practical rule: **check the config, not the filename.** Section 3 is how.

## 3. How to verify a kernel is docker-capable

Do this *inside the guest*, from the compiled-in config — never from a README.

```sh
# 1. the guest must expose its config
zcat /proc/config.gz | grep -E \
  'CONFIG_OVERLAY_FS|CONFIG_VETH|CONFIG_BRIDGE|CONFIG_NETFILTER=|CONFIG_PID_NS|CONFIG_USER_NS|CONFIG_MEMCG|CONFIG_CGROUP_PIDS'
```

Required to see every one of these as `=y`:

```
CONFIG_OVERLAY_FS=y
CONFIG_VETH=y
CONFIG_BRIDGE=y
CONFIG_NETFILTER=y
CONFIG_PID_NS=y
CONFIG_USER_NS=y
CONFIG_MEMCG=y
CONFIG_CGROUP_PIDS=y
```

```sh
# 2. cgroup2 must be mounted and expose controllers
mount -t cgroup2 none /sys/fs/cgroup
cat /sys/fs/cgroup/cgroup.controllers
#   expected: cpu io memory pids
#   non-SMP linux-bionic: cpu io            <-- insufficient
```

```sh
# 3. confirm with the daemon itself
docker info | grep -E 'Storage Driver|Backing Filesystem|Cgroup Version|Security Options'
docker info 2>&1 | grep -iE 'cpuset|swap limit'     # expected warnings, see below
```

Expected output on a docker-capable kernel:

```
SERVER=20.10.24+dfsg1 DRIVER=overlay2 CGROUPV=2
Storage Driver: overlay2
 Backing Filesystem: extfs
 Supports d_type: true
 Native Overlay Diff: true
Security Options: seccomp cgroupns
```

Expected *warnings* on all three kernels (guest kernel gaps, not host problems):

```
WARNING: No cpuset support          # CONFIG_CPUSETS unset
WARNING: No swap limit support
```

Fully negative check, in one line — this is the fast triage:

```sh
for s in OVERLAY_FS VETH BRIDGE PID_NS USER_NS MEMCG CGROUP_PIDS; do
  printf '%-14s ' "$s"; zcat /proc/config.gz | grep -m1 "^CONFIG_$s=" || echo ABSENT
done
```

## 4. Interception mode and CPU count

| Mode | How it is selected | Boot log line | Syscall cost | Guest CPUs |
|---|---|---|---|---|
| `ptrace` | **default inside the Termux app sandbox** | `Userspace mode: ptrace` | ~25 µs (upstream) | **1** |
| `seccomp` | `seccomp=on` on the kernel command line | `Userspace mode: SECCOMP` | ~2.7 µs (upstream), **~2.0 µs measured in-app** | `ncpus=4` → 4 |

The ptrace log line is explicit about the CPU cost:

```
SMP is not supported with ptrace userspace; running on 1 CPU instead of the 7 requested
```

with `seccomp=on` and `ncpus=4`, the guest reports 4 CPUs.

Design consequence, stated as a recommendation rather than a measurement: **force
`seccomp=on`** for anything container-shaped. The default inside the sandbox is
the slow, single-CPU mode.

Reproduce:

```sh
# ptrace (default): expect "Userspace mode: ptrace" and 1 CPU
./linux-bionic-smp mem=512M stub_exe=$PWD/stub_exe panic=-1 \
  initrd=initramfs-alpine.cpio.gz rdinit=/bin/sh con=null con0=fd:0,fd:1

# seccomp, 4 CPUs: expect "Userspace mode: SECCOMP"
./linux-bionic-smp mem=1024M ncpus=4 seccomp=on stub_exe=$PWD/stub_exe panic=-1 \
  ubd0=./debian-docker.ext4 root=/dev/ubda rw init=/umarm-init \
  con=null con0=fd:0,fd:1
```

Inside the guest, count CPUs with `grep -c ^processor /proc/cpuinfo` (or `nproc`).

## 5. Docker inside the guest

```
SERVER=20.10.24+dfsg1 DRIVER=overlay2 CGROUPV=2
cgroup2_controllers=cpu io memory pids
Storage Driver: overlay2   Backing Filesystem: extfs   Supports d_type: true   Native Overlay Diff: true
Runtimes: io.containerd.runc.v2 ... runc    Security Options: seccomp, cgroupns
Status: Downloaded newer image for hello-world:latest
```

and, while containers are alive, the guest kernel log shows the plumbing is real
(not a shim):

```
docker0: port 1(veth93292f1) entered disabled state
veth625ece4: renamed from eth0
```

Verified docker operations:

| Operation | Result |
|---|---|
| `docker pull` (hello-world, alpine, busybox) | through the NAT; DNS + registry reachable |
| `docker run`, `docker exec`, `docker logs` | working |
| container → container ping on `docker0` | `172.17.0.2`, 2 packets transmitted, 2 received, **0% packet loss** |
| DNS + HTTP from *inside* a container | `<!doctype html>...` from `example.com`; `nslookup registry-1.docker.io` |
| published port, checked inside the guest | `docker ps` shows the container `Up 13 seconds` with `0.0.0.0:8123->80/tcp`; fetching it from inside the guest returns `HTTP/1.1 200 OK ... bridge-ok` |

Versions measured: Docker server `20.10.24+dfsg1`, containerd `1.6.20`, runc,
cgroup v2.

## 6. Network bring-up and the "Address already assigned" trap

With the **`fd` transport + `passt`** bridge, the bridge helper announces the
addressing the guest must use:

```
DHCP: assign 10.0.2.15  mask 255.255.255.0  router 10.0.2.2
DNS : 10.0.2.3 (upstream 1.1.1.1)   NAT to host 127.0.0.1: 10.0.2.2
```

Working static configuration (no DHCP client needed):

```sh
ip link set lo up
ip link set vec0 up
ip addr add 10.0.2.15/24 dev vec0
ip route add default via 10.0.2.2 dev vec0
printf 'nameserver 10.0.2.3\nnameserver 1.1.1.1\n' > /etc/resolv.conf
```

Result: DNS resolution works, `TCP_443_OK`, `TCP_REGISTRY_OK`, `docker pull`
succeeds.

### The trap

```
Error: ipv4: Address already assigned.
```

`ip addr add 127.0.0.1/8 dev lo` fails because the loopback address is **already**
assigned by the kernel. Any bring-up script that adds it unconditionally dies
right there — and because the failure is an early line in the script, the script
never reaches the `vec0` configuration, and the visible symptom is the much more
misleading *"network is unreachable"* inside the guest. Two lessons:

1. `127.0.0.1/8` is already on `lo`; only `ip link set lo up` is needed.
2. Treat bring-up as a marked sequence — a failure at line 3 must not present as
   "no network".

### The *other* trap in the same area

The Debian disk image from the release ships **no** `udhcpc`, `busybox`, `wget`
or `curl` — only `ip` and `dhclient`. So a DHCP-dependent script appears to fail
for "no network" when in truth there is no DHCP client. Either install one in the
image, or configure statically (or use `dhclient`, which is present), or move to
the gvproxy path where `dhclient -1 -v vec0` does work.

## 7. The `passt` inbound failure

`passt` is not broken in general; the released bridge cannot forward inbound, and
this section is the reasoning that isolates it.

Step 1 — read the source. The bridge helper hardcodes no forwarding in its call
to `passt`, with a comment that states the intent: no inbound port forwarding, the
guest gets outbound connectivity and nothing on the phone's network can reach into
it. So the default is *by design* outbound-only. Nothing is "broken" yet.

Step 2 — patch it. Changing that argument to
`-t 127.0.0.1/8123,8124` and rebuilding the helper makes `passt` accept the
connection. Result from the phone:

| Test | Result | What it rules out |
|---|---|---|
| host `connect()` → `127.0.0.1:8123` | **timeout**, not refused | there *is* a listener (a refused connection would mean nothing bound), the socket is accepted, and then no data ever comes back |
| host-network container listening directly on the guest's `8124`, no DNAT involved | **timeout as well** | Docker's netfilter/NAT is **not** the cause — with `--network host` there is no DNAT path at all, and it fails identically |
| guest → `127.0.0.1:8123` (inside the guest) | `bridge-ok` | the container and the in-guest publish are fine; only the host→guest direction fails |
| guest `FORWARD` policy | initially `DROP` (set by Docker); after `iptables -P FORWARD ACCEPT` it still times out | the guest's forward chain is **not** the cause either |

Step 3 — conclusion. In the released Android build of `passt` behind this bridge,
the inbound path accepts and never forwards. Ruling out Docker's DNAT and the
guest's FORWARD policy leaves the helper side. The practical consequence: **the
released `passt` + `umnet` path is outbound-only, and inbound forwarding needs a
different transport.** Community claims of "container ports forwarded to the
phone's `127.0.0.1`" are achievable in that ecosystem, but with a different
bridge, not with the released `passt` binary plus its released helper.

Two in-guest findings that *look* like the same bug and are not, useful for
disambiguation: the loopback-add error (§6) and the published port being
perfectly reachable from inside the guest — which proves the publish itself is
correct.

## 8. The solution: `gvproxy` over the BESS transport

Replacing the helper with `gvproxy` v0.9.0 (`linux-arm64`, statically linked Go
binary) and switching the vector transport from `fd` to `bess` gives **both**
directions at once.

Host side — note the `proot` wrapper, and why:

```sh
# gvproxy needs /etc/resolv.conf, and Android has none. proot bind-mounts one in.
proot -b $PREFIX/etc:/etc ./gvproxy -debug \
  -listen unix://$TMPDIR/gvnet.sock \
  -listen-bess unixpacket://$TMPDIR/bess.sock \
  -log-file gvproxy.log &
```

Guest side — the transport is selected on the **kernel command line**, so no
bridge helper process is involved at all:

```
vec0:transport=bess,dst=$TMPDIR/bess.sock,depth=128,gro=1,mac=5a:94:ef:e4:0c:ee
```

Guest DHCP now works with the DHCP client that is present in the image:

```sh
dhclient -1 -v vec0
#   DHCPREQUEST for 192.168.127.2 on vec0 ...
```

Observed values:

```
ADDR:   vec0  inet 192.168.127.2/24  (dynamic, valid_lft 3600sec)
ROUTE:  default via 192.168.127.1 dev vec0
RESOLV: nameserver 192.168.127.1
DNS_TEST: 2600:1f18:... registry-1.docker.io        <- external DNS resolves
SERVER=20.10.24+dfsg1 DRIVER=overlay2 CGROUPV=2
Status: Downloaded newer image for busybox:latest    <- pull goes through the NAT
BUSYBOX_RUN_OK
```

Inbound — the exact API call:

```sh
curl --unix-socket $TMPDIR/gvnet.sock -X POST \
  -d '{"local":"127.0.0.1:8123","remote":"192.168.127.2:8123"}' \
  http://unix/services/forwarder/expose
```

From the phone, immediately afterwards:

```
127.0.0.1:8123 -> 'HTTP/1.1 200 OK\r\nContent-Length: 15\r\n\r\ngvproxy-bess-ok\n'   PASS
127.0.0.1:8124 -> 'HTTP/1.1 200 OK\r\nContent-Length: 11\r\n\r\nhostnet-ok\n'       PASS  (--network host container)
VERDICT=PASS (Docker container port reachable from the phone on 127.0.0.1)
```

Inbound and outbound are live **simultaneously** on this path.

Three traps on this path:

1. **`/etc/resolv.conf` missing on Android** → gvproxy fails with
   `open file error: open /etc/resolv.conf`; fix with
   `proot -b $PREFIX/etc:/etc`.
2. **gvproxy exits when the BESS peer disconnects**
   (`gvproxy exiting: cannot receive packets from @, disconnecting: ... EOF`).
   It is a per-run process: restart it for every UML boot. See
   [MOBILITY.md](MOBILITY.md) for why this is a mobility hazard, not just an
   inconvenience.
3. **Mapping is one-to-one.** If a container is published as `-p 8123:80` in the
   guest, expose `192.168.127.2:8123` (the guest-side port), not `:80`.

## 9. How to reproduce every claim

Run these in order. Each block yields an observable string; the verdict for each
is the **marker string**, never the exit status (see
[../evidence/README.md](../evidence/README.md)).

**R1 — unprivileged boot gate**

```sh
uname -m; id -u; cat /proc/self/status | grep -E 'CapEff|CapBnd|Seccomp:'
./linux-bionic-smp mem=512M initrd=initramfs-alpine.cpio.gz rdinit=/bin/sh \
  stub_exe=$PWD/stub_exe panic=-1 con=null con0=fd:0,fd:1
# expect: "Linux version 7.2.0-rc4" ... "Userspace mode: ptrace"
```

**R2 — kernel config matrix**

```sh
for s in OVERLAY_FS VETH BRIDGE NETFILTER PID_NS USER_NS MEMCG CGROUP_PIDS CPUSETS COMPAT SMP; do
  printf '%-12s ' "$s"; zcat /proc/config.gz | grep -m1 "^CONFIG_$s=" || echo ABSENT
done
# note: the guest's zcat, run from inside the guest
```

**R3 — cgroup2 controllers**

```sh
mount -t cgroup2 none /sys/fs/cgroup
cat /sys/fs/cgroup/cgroup.controllers      # expect: cpu io memory pids
```

**R4 — interception mode and CPU count**

```sh
# host, two runs, two log lines:
#   no flag      -> "Userspace mode: ptrace"   (and the 1-CPU warning)
#   seccomp=on   -> "Userspace mode: SECCOMP"  (with ncpus=4)
grep -E 'Userspace mode|SMP is not supported' <boot log>
```

**R5 — Docker end to end**

```sh
mount -t tmpfs tmpfs /run; rm -rf /run/containerd /run/docker /var/run/docker.pid
containerd & dockerd >/var/log/dockerd.log 2>&1 &
docker info | grep -E 'Storage Driver|Backing Filesystem'
docker pull hello-world && docker run --rm hello-world
docker run -d --name c1 alpine sleep 300; docker run -d --name c2 alpine sleep 300
docker exec c1 ping -c2 -W2 "$(docker exec c2 ip -4 addr show eth0 | awk '/inet /{print $2}' | cut -d/ -f1)"
# expect: 0% packet loss
```

**R6 — published port, inside the guest**

```sh
docker run -d -p 8123:80 --name web <image-that-serves> ; docker ps
# expect: 0.0.0.0:8123->80/tcp ; then fetch 127.0.0.1:8123 from inside the guest
```

**R7 — the loopback trap**

```sh
ip addr add 127.0.0.1/8 dev lo        # expect: "Error: ipv4: Address already assigned."
```

**R8 — host-side inbound (gvproxy path)**

```sh
proot -b $PREFIX/etc:/etc ./gvproxy -debug \
  -listen unix://$TMPDIR/gvnet.sock -listen-bess unixpacket://$TMPDIR/bess.sock \
  -log-file gvproxy.log &
# boot UML with vec0:transport=bess,dst=$TMPDIR/bess.sock,depth=128,gro=1,mac=...
# guest: dhclient -1 -v vec0   -> 192.168.127.2/24
curl --unix-socket $TMPDIR/gvnet.sock -X POST \
  -d '{"local":"127.0.0.1:8123","remote":"192.168.127.2:8123"}' \
  http://unix/services/forwarder/expose
curl -i http://127.0.0.1:8123/         # expect: HTTP/1.1 200 OK from the container
```

**R9 — the passt negative result**

```sh
# 1. released helper, no forwarding:  inbound fails by design (-t none -u none)
# 2. patch the helper's passt argument to -t 127.0.0.1/8123, rebuild, retry:
#      host connect() to 127.0.0.1:8123            -> timeout
#      guest container on --network host, direct  -> timeout  (rules out Docker DNAT)
#      iptables -P FORWARD ACCEPT in guest, retry -> still timeout
# 3. conclusion: helper-side forwarding is broken/incomplete in the release
```

**R10 — gvproxy dies with the peer**

```sh
grep -i 'cannot receive packets' gvproxy.log
# expect a "... disconnecting: ... EOF" line after the UML process ends
```

**R11 — sans-`exit` shutdown**

```sh
# in the guest:
exit          # -> the UML process hangs
poweroff -f   # -> clean guest shutdown; the host sees the run end
```

### Claims that this section deliberately does **not** establish

- Anything on hardware other than the reference device.
- Anything about long-run stability, leakage or restart behaviour under load.
- Any comparison against `proot` or QEMU executed by this project.
- USB passthrough, 32-bit images, cpuset, swap limits, Compose, BuildKit, swarm.
- `nosysemu` / `nocancel` fallback behaviour (not exercised; unnecessary here).

Those are listed again, verbatim, under "not verified" in
[../README.md](../README.md#verified--not-verified).
