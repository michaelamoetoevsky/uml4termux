# uml4termux — build summary and verification log

Project: run a real Linux kernel (User-Mode Linux, `ARCH=um SUBARCH=arm64`) as an
ordinary unprivileged aarch64 process inside Termux/Android, so Docker and
containers run without root, `/dev/kvm`, a hypervisor, a tap device or any
capability. Networking uses **gvproxy** (userspace TCP/IP + port-forwarding HTTP
API) over UML's **BESS** transport.

## Layout delivered

| Path | What it is |
|---|---|
| `bin/uml4termux` | the CLI: `doctor fetch init-image boot docker expose stop dist-info version help` (+ global `--dry-run`) |
| `lib/{common,fetch,net,guest,doctor}.sh` | libraries the CLI sources |
| `scripts/build-initramfs.py` | pure-python `newc` cpio generator (no `cpio` needed on device) |
| `scripts/guest/{init,docker-init.sh,forensic.sh}` | guest payload: switch_root init, dockerd autostart, probe suite |
| `scripts/{install.sh,uninstall.sh}` | prefix installer / remover (idempotent, `--dry-run`, verification built in) |
| `packaging/termux/build.sh` | termux-packages-style script-only package skeleton |
| `packaging/check-install.sh` | install → verify → uninstall → assert-clean gate |
| `ci/{local-ci.sh,lib.sh,list-shell-files.sh,no-boot-guard.sh,make-dist.sh,changelog-extract.sh,yamlcheck.py,check-evidence.py}` | CI implementation (works offline) |
| `.github/workflows/{ci,release,device-evidence}.yml` | GitHub Actions: static checks + packaging, tag → release, evidence schema validation |
| `tests/{self-test.sh,ci-checks.sh,test_build_initramfs.py}` | device-free tests |
| `docs/*` | architecture, forensics, mobility, CI-CD, FAQ, known limits, upstream |
| `evidence/schema.json` | schema for phone-side evidence uploads |
| `Makefile`, `VERSION`, `CHANGELOG.md`, `LICENSE`, `README.md` | build/version/licence/docs |

## Verification actually executed (on this device: Android 16, kernel 6.1.157, aarch64, no root)

| Command | Result |
|---|---|
| `bash -n` on every shell file (incl. `bin/uml4termux`) | all pass |
| `python3 -m py_compile` on every `.py` | all pass |
| `./bin/uml4termux version` | `uml4termux 0.1.0 (GPL-2.0-only)` |
| `./bin/uml4termux help` | lists all 9 commands + global `--dry-run` |
| `./bin/uml4termux doctor` | non-destructive report; asset checks SKIP with `run 'uml4termux fetch'`; phantom-process risk AMBER (sdk 36, 81 visible processes); verdict `SKIP: 5 asset(s) missing` |
| `./bin/uml4termux docker --dry-run` | prints the whole runbook without executing: `proot -b $PREFIX/etc:/etc gvproxy …`, initramfs built (`4 entries: init, docker-init.sh, forensic.sh, TRAILER!!!`), boot line `1024M, 4 cpus, seccomp=on` |
| `bash packaging/check-install.sh` | installs into a temp prefix, verifies, uninstalls, asserts clean → `VERDICT=PASS` |
| `make dist` (via CI helper) | `dist/uml4termux-0.1.0.tar.gz` + `dist/SHA256SUMS` |

Device-gate evidence for the runtime claims (kernel/guest level) lives outside the
repo in `~/workspace/uml-forensics/` (`REPORT-uml-docker-termux.md`, `adv/*.log`,
`evidence/*.host.json`): verified Docker 20.10.24 with overlay2 on cgroup v2,
`docker pull/run/exec/logs`, container-to-container networking, published ports
reachable on the phone's `127.0.0.1` through the gvproxy forwarding API, 30
container cycles with no leak and no kernel `BUG:`/`WARNING:`, `seccomp=on
ncpus=4` giving 4 vCPUs and ~18x cheaper cheap-syscalls than the `ptrace` default.

## Not verified here (stated, not implied)

- IPv6 container networking (dockerd fails to add the IPv6 bridge route; the
  kernel symbols are present, so it is a daemon/bridge-level issue).
- Nested `docker build` inside the guest (run was cut short by an external kill).
- `hostfs` mount behaviour and module loading (`# CONFIG_MODULES is not set` in
  the released bionic-smp kernel, so `modprobe`/out-of-tree drivers cannot work).
- Network handover (WiFi ↔ cellular) and screen-off/doze behaviour.
- Anything requiring root, `/dev/kvm` or non-Termux Android versions < 11.
