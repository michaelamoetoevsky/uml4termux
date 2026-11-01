# uml4termux — build summary and verification log

Project: run a real Linux kernel (User-Mode Linux, `ARCH=um SUBARCH=arm64`) as an
ordinary unprivileged aarch64 process inside Termux/Android, so Docker and
containers run without root, `/dev/kvm`, a hypervisor, a tap device or any
capability. Networking uses **gvproxy** (userspace TCP/IP + port-forwarding HTTP
API) over UML's **BESS** transport.

## Layout delivered

| Path | What it is |
|---|---|
| `bin/uml4termux` | the CLI: `up down exec expose status doctor fetch init-image boot bundle dist-info version help` (+ global `--dry-run`) |
| `bin/ulter` | short wrapper alias for `uml4termux` |
| `src/uml4termuxd.c`, `rust/uml4termux-rs` | supervisor daemons (C and Rust implementations) |
| `lib/{common,fetch,net,guest,doctor,launch,registry,bundle}.sh` | libraries the CLI sources |
| `scripts/build-initramfs.py` | pure-python `newc` cpio generator (no `cpio` needed on device) |
| `scripts/guest/{init,docker-init.sh,forensic.sh}` | guest payload: switch_root init, dockerd autostart, probe suite |
| `scripts/{install.sh,uninstall.sh}` | prefix installer / remover (idempotent, `--dry-run`, verification built in) |
| `packaging/termux/build.sh` | termux-packages-style script-only package skeleton |
| `packaging/check-install.sh` | install → verify → uninstall → assert-clean gate |
| `ci/{local-ci.sh,lib.sh,list-shell-files.sh,no-boot-guard.sh,make-dist.sh,changelog-extract.sh,yamlcheck.py,check-evidence.py,procstat.py}` | CI implementation (works offline) |
| `.github/workflows/{ci,release,device-evidence}.yml` | GitHub Actions: static checks + packaging, tag → release, evidence schema validation |
| `tests/*` | unit test suite (31 tests in `local-ci.sh`) |
| `docs/*` | architecture, forensics, mobility, CI-CD, FAQ, known limits, upstream, directions |
| `evidence/*.json`, `evidence/logs/` | in-tree empirical evidence records and sanitised device logs |
| `Makefile`, `VERSION`, `CHANGELOG.md`, `LICENSE`, `README.md` | build/version/licence/docs |

## Verification actually executed (on this device: Android 16, kernel 6.1.157, aarch64, no root)

| Command | Result |
|---|---|
| `bash -n` on every shell file (incl. `bin/uml4termux`) | all pass |
| `python3 -m py_compile` on every `.py` | all pass |
| `./bin/uml4termux version` | `uml4termux 0.5.0 (GPL-2.0-only)` |
| `./bin/uml4termux help` | lists all 13 commands + global `--dry-run` |
| `./bin/uml4termux doctor` | non-destructive report; verifies environment, storage, assets and dependencies |
| `./bin/uml4termux docker --dry-run` | prints runbook without executing: `proot -b $PREFIX/etc:/etc gvproxy …`, initramfs built, boot line `1024M, 4 cpus, seccomp=on` |
| `bash packaging/check-install.sh` | installs into a temp prefix, verifies, uninstalls, asserts clean → `VERDICT=PASS` |
| `make dist` (via CI helper) | `dist/uml4termux-0.5.0.tar.gz` + `dist/SHA256SUMS` |

Device-gate evidence for runtime claims is stored directly in `evidence/*.json` (with logs in `evidence/logs/`):
verified Docker 20.10.24 with overlay2 on cgroup v2, `docker pull/run/exec/logs`, container-to-container
networking, published ports reachable on the phone's `127.0.0.1` through the gvproxy forwarding API,
repeat-boot reliability (10/10), 60-minute stability soak (43 cycles 0 kernel bug lines), 20/20 console
channel soak (`evidence/20261101-soak-console-channel.json`), `seccomp=on ncpus=4` giving 4 vCPUs and ~2.0 µs
syscall overhead, IPv6 container networking over `fd00:9::/64` (`evidence/20261026-capability-round-2.json`),
BuildKit builds, 32-bit images via `qemu-user-static` + binfmt_misc, hostfs security isolation
(`evidence/20261031-security-isolation.json`), and kernel modules enabled in v0.4.0+ pinned kernel
(`CONFIG_MODULES=y`).

## Not verified here (stated, not implied)

- Any non-reference device or Android version < 11.
- Network handover (WiFi ↔ cellular) and screen-off/doze behaviour without wakelock.
- Docker Swarm, unusual volume drivers, or Kubernetes.
- Multi-hour stability beyond 60 minutes / 20 consecutive PTY console cycles.
- Anything requiring host root, `/dev/kvm` or host capabilities.
