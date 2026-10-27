# Upstream findings for zalexdev/linux-um-arm64

> **POSTED**: https://github.com/zalexdev/linux-um-arm64/issues/4 (28 Okt 2026,
> dengan persetujuan owner). Teks di bawah = isi issue.

Context: we package the UML arm64 port for Termux (rootless Docker) in
[michaelamoetoevsky/uml4termux](https://github.com/michaelamoetoevsky/uml4termux).
While building our own kernel in CI and probing capabilities on an Android 16
device (aarch64, unprivileged app sandbox), we collected findings that may be
useful upstream.

## 1. Branch HEAD does not compile (kernel-side)

At `32e5e10b` (um-arm64 branch HEAD, Oct 2026) the kernel side fails:

```
include/linux/sched/signal.h:430: error: call to undeclared function 'user_mode'
```

`arch/arm64/um/asm/ptrace.h:21` defines `user_mode`, but the include path the
um build sets up does not reach it when `include/linux/sched/signal.h` is
compiled from `arch/um/kernel/asm-offsets.c`. Reproduced identically on-device
(Termux clang) and on a GitHub arm64 runner (NDK clang) — a source regression,
not a toolchain issue.

## 2. `prebuilt-20260816` commitish silently drops CONFIG_SMP

The release's `target_commitish` (`8d984326`) does not carry
`UML_SUBARCH_SUPPORTS_SMP` in `arch/arm64/um/Kconfig`, so `CONFIG_SMP` (which
`depends on UML_SUBARCH_SUPPORTS_SMP`) is dropped by `olddefconfig` together
with everything depending on it (`CONFIG_CPUSETS`, ...). The released binaries
must have been built from a different tree state than the release tag points
at. Suggestion: tag the exact build commit.

## 3. On-device (bionic host) build fixes — scripts/mod macro cycle

Building the port natively on Android/Termux (bionic `<elf.h>`) dies in
modpost:

```
modpost.h:52: #define ELF_ST_TYPE ELF64_ST_TYPE
bionic linux/elf.h:113: #define ELF64_ST_TYPE(x) ELF_ST_TYPE(x)
file2alias.c: error: 'ELF64_ST_TYPE' undeclared
```

The per-class alias in `modpost.h` forms a macro cycle with bionic's elf.h
(glibc's does not, because it defines the primitives directly). Replacing both
alias blocks in `modpost.h` with self-contained primitives fixes it:

```c
#define ELF_ST_BIND(val)	((val) >> 4)
#define ELF_ST_TYPE(val)	((val) & 0xf)
```

(Identical to what glibc provides; safe cross-platform.) After this, modpost
and file2alias compile on-device with the NDK.

## 4. Kernel capability gaps in the released configs — and a closed set

The released kernels lack `CONFIG_CPUSETS` ("No cpuset support" from Docker),
and expose cgroup2 `cpu io memory pids` only. We build with the extracted
guest config plus:

```
CONFIG_CPUSETS=y CONFIG_BLK_CGROUP=y CONFIG_BLK_DEV_THROTTLING=y CONFIG_MODULES=y
```

result (device-verified, cgroup v2): `cpuset cpu io memory pids`, Docker's
cpuset warning gone, everything else unchanged (Docker 20.10.24 / overlay2 /
cgroup v2, pull + run + inbound published port). Remaining gap in our config:
`CONFIG_MEMCG_KMEM` (tmpfs/page cache uncharged — `memory.current` unchanged
after an 80 MB tmpfs write inside a 64 MB group). Suggest enabling CPUSETS
(+ MEMCG_KMEM?) in the released configs; the cost is small and Docker warns
without it.

## 5. IPv6 container networking works (refuting the old claim)

The IPv6 claim floating in earlier discussions ("does not work") is wrong.
With `docker network create --ipv6`, containers get `fd00:9::N` addresses and
a default route, and ping each other with 0% loss. The daemon logs a cosmetic
`network is down` route error at creation time because the bridge is `state
DOWN` until the first container attaches — do not trust a daemon error
observed only at network-creation time; test with containers running.

## 6. The stub is toolchain-sensitive

The kernel loads `stub_exe` into guest processes; its layout assumptions are
tied to the toolchain that built it. A stub built with NDK r27c (vs the
harness's NDK 29.0.14206865) lacks `.rela.dyn`, differs in 156 disassembly
lines, and SIGSEGVs the first exec'd process — the same kernel boots fully
with the matching stub. With the matching NDK the stub reproduces
byte-identical. Recommendation: build and ship stub_exe from the same
toolchain/CI run as the kernel (our workflow now does exactly that, see
`.github/workflows/kernel-build.yml`).

## Build recipe (CI, no device needed)

`.github/workflows/kernel-build.yml` in our repo builds the bionic kernel on
`ubuntu-latest` (x86_64 runner — the official NDK ships linux-x86_64 host
tools, and nothing executes the aarch64 output): NDK r29, config from the
running guest's `/proc/config.gz` + the symbols above, kconfig stages with the
host gcc (`scripts/cc-version.sh` cannot parse the NDK clang's "Android (...)
based on clang r... clang version" string), compile with
`clang --target=aarch64-linux-android30` + lld. Artifacts: `linux-bionic`
(~15 MB) + `stub_exe`, verified on-device.

---
*Prepared by the uml4termux project — evidence: `evidence/20261027-ci-kernel-round3.json`,
boot logs under `workspace/uml-forensics/cap7-cap10/` (device), CI runs
40422375396/40428906952/40434424692/40438127489/40535091305.*
