# Security Policy

## Reporting a vulnerability

**Do not file a public issue.**  
Send the details to the project maintainer privately:

- **GitHub Security Advisories**: use the "Report a vulnerability" button on the
  repository's Security tab (private disclosure; no email channel is offered
  for security reports).

Include:

1. A clear description of the issue and its impact.
2. The exact steps or a minimal script to reproduce it.
3. The affected version(s) or commit(s).
4. Whether you have a fix or workaround.

We aim to acknowledge within 72 hours and to coordinate a fix and disclosure
timeline with you.

## Supported versions

Only the latest tagged release (`vX.Y.Z`) receives security fixes. The `main`
branch may contain incomplete work; do not run it on a device you care about.

## Threat model — what this project does and does not protect

### What uml4termux *is*

A userspace wrapper around a real Linux kernel (User-Mode Linux, SUBARCH=arm64,
downstream port by zalexdev/Raymer8639) that runs **entirely as an unprivileged
Termux process** on Android. It provides:

- A Linux kernel API surface for containers (cgroups v2, namespaces, overlayfs
  via FUSE/overlay2, seccomp).
- A userspace network stack (gvproxy) over UML's BESS transport, with an HTTP
  port-forwarding API that binds only to `127.0.0.1` on the host.
- A rootless container runtime (Docker 20.10+) that can pull images and run
  workloads inside the guest.

### What uml4termux is **not**

| Property | Statement |
|----------|-----------|
| VM-grade isolation | **No.** UML runs in the same UID/GID as the caller. A guest process that escapes the UML kernel (e.g. via a kernel bug) inherits the host Termux UID — the same as any other Android app you run. |
| Security boundary | **No.** The host kernel is Android's kernel; UML's system calls are forwarded to it. A malicious guest can attempt to exploit the host kernel through any syscall UML permits. |
| Hostfs safety | **No.** `hostfs` mount (the default way the guest sees host files) gives the guest **full read/write access to the host filesystem as your Termux user**. Do not enable `hostfs` with untrusted guest code. |
| Seccomp hardening | The "seccomp fast path" is a **compatibility shim** that filters guest syscalls before they reach the host. It is not a security layer — it reduces the attack surface but cannot stop a kernel exploit. |
| Network exposure | The gvproxy forwarding API binds to `127.0.0.1` by default. A port forwarded from a container is reachable **only from the same Android device**. No external network interface is opened. |
| cgroup limits | Some controllers (`cpuset`, `swap`) are unavailable on Android's cgroup v2. CPU/memory limits are advisory; a guest can exceed them. |

### Threats we *do* mitigate

- **No root, ever**: The entire stack runs as the Termux user. Android's SELinux policy and the app sandbox still apply.
- **No `/dev/kvm`, no `/dev/net/tun`, no tap device**: The transports (BESS + gvproxy) are pure userspace.
- **Artifact integrity**: Release tarballs ship with `SHA256SUMS`. The CLI verifies downloaded kernels/gvproxy against pinned hashes.

### Threats we **cannot** mitigate

- A kernel vulnerability in the downstream UML port (this is a Linux kernel).
- A malicious guest exploiting the host Android kernel via a permitted syscall.
- A compromised host (rooted phone, malicious app with the same UID).
- Physical device access (if an attacker has `adb`/physical access, the guest is the least of your worries).

## Hardening recommendations for users

1. **Never use `hostfs` with untrusted code.** If you must run untrusted workloads, mount a dedicated loopback image (ext4) instead of exposing the host filesystem.
2. **Keep Android updated.** The host kernel is Android's kernel — vendor patches matter.
3. **Run only signed/verified container images.** `docker pull` from untrusted registries brings untrusted userspace into the guest.
4. **Audit your evidence records.** `make evidence-check` validates what the device actually observed (boot, overlay2, seccomp, port forwarding). A missing or `fail` verdict is a signal.
5. **Treat the guest as "same UID, different PID namespace".** Any file the Termux user can read/write, the guest can read/write.

## Disclosure policy

When a fix is ready, we will:

1. Release a patch version (`vX.Y.Z+1`).
2. Publish a GitHub Security Advisory with CVE (if assigned).
3. Note the fix in `CHANGELOG.md` under a `Security` heading.

We do not use embargoes beyond the time needed to ship the patch.