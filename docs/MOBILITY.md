# Mobility and Android lifecycle

A guest that boots is not a guest that stays up. Android is built to reclaim
resources from background apps, and this project runs the *entire* Linux machine
as exactly one background app process. This document is about the ways Android
ends that, which ones were measured, and what to do about each.

Evidence basis: the reference device only (Android 16, kernel
`6.1.157-android14-11`, aarch64, Termux app sandbox, `CapEff=0`). Where a
statement is reasoning rather than a measurement, it says so.

---

## 1. The one structural disadvantage

The guest is a single app process. That has two consequences that cannot be
engineered away from userspace:

1. **Memory.** Every guest byte — kernel, page cache, dockerd, every container —
   is counted inside one Android app's memory footprint. `oom_score_adj` cannot be
   lowered without root, so the guest cannot ask Android to kill someone else
   first. The whole VM dies as a unit; one runaway container takes the machine
   with it.
2. **Process count.** Android counts *child processes system-wide*, not per app,
   and caps background apps. Container workloads are exactly the shape that hits
   the cap.

Neither is a bug in the port. They are the price of "runs as an ordinary app".

## 2. Phantom process killer (Android 12+)

**What it is.** Android limits how many child processes a background app may have
across the whole system: **32**. When the limit is hit, Android kills phantom
processes — typically the newest ones. Termux may be foregrounded and still lose
children, because the budget is system-wide, not app-local.

**Why it hits this project hardest.** `dockerd` + `containerd` + `runc` + the
processes inside every container + the guest's own `kthreadd` children (the guest
kernel has its own thread pool, and those threads are real host tasks) all consume
the budget. `docker compose up` on a multi-service file is a near-certain kill.

**Symptom.** Containers or `dockerd` vanish with no OOM message; the guest kernel
reports nothing unusual because from its point of view the processes were killed
by something outside it. If a container disappears and the host had no memory
pressure, suspect the phantom killer first.

**Mitigation — one-time, per device.**

- Android 14+: **Developer options → "Disable child process restrictions"**. This
  is the supported, persistent toggle; enable it once.
- Any Android 12+: via adb (resets on reboot / is not persistent across some
  updates, so re-check):

  ```sh
  adb shell device_config put activity_manager max_phantom_processes 2147483647
  ```

  Verify with:

  ```sh
  adb shell device_config get activity_manager max_phantom_processes
  ```

  And restore the platform default by deleting the key:

  ```sh
  adb shell device_config delete activity_manager max_phantom_processes
  ```

The developer-options toggle is the one to recommend to users; the adb route is
for testing and for devices without that toggle.

## 3. Excessive-CPU kill

Android's ActivityManager kills background app processes that burn excessive CPU
over a window. A guest that is compiling, running a busy loop, or serving traffic
is by definition a CPU-burner, and it is a background app as far as AMS is
concerned.

**Consequence.** Timing-sensitive or long-running work can be killed mid-flight
even with `termux-wake-lock` held — a wakelock keeps the CPU awake, it does not
exempt the app from CPU accounting.

**Mitigations that are in reach without root:**

- Run the workload with the Termux session visible (foreground) while it runs; a
  visible app is in a much better lifecycle state than a cached one.
- Acquire a wakelock for the duration: `termux-wake-lock` … `termux-wake-unlock`
  (Termux:API / the Termux notification action). It prevents sleep, not the AMS
  kill.
- Keep sustained CPU inside the guest low, or accept checkpoint-and-resume
  semantics: assume the guest can die at any point.

**Not available without root:** raising the process's `oom_score_adj`, pinning
CPUs, boosting clocks, or exempting the app from battery restrictions
programmatically.

## 4. LMK (low memory killer)

The guest cannot raise its priority, so the practical control is guest RAM size.
On the reference device with roughly 2.1 GB available, `mem=1024M` for the guest
plus Docker inside it was the working point — i.e. roughly 1 GB of phone RAM
consumed by the app while foreground.

Guidance:

- Budget the guest at about half of the RAM you can *reliably* free on the phone,
  and no more.
- Container images and build output live in the guest's ext4 image; the page cache
  for that file is also app memory. A large image plus active containers is the
  most common way to reach LMK pressure.
- Because the kill is arbitrary, treat the guest as stateful-but-disposable:
  prefer volume-backed data that survives a `poweroff -f`, and re-run rather than
  repair.

## 5. Doze, app standby and screen-off behaviour

**What was observed:** the guest runs as a normal app process. There is no
VPN-style network, no foreground service carved out by the port, and nothing that
tells Android "this is doing real work" beyond the ordinary mechanisms.

**Therefore, screen-off behaviour is the fragile part:**

- When the screen goes off and the device idles, the app moves toward cached /
  restricted states; doze will defer network and (in deeper states) restrict
  execution. A guest whose whole purpose is a long-lived network stack will stall
  or be frozen.
- Without a wakelock, the honest expectation is: **the guest may be frozen when the
  screen is off.** With `termux-wake-lock` held, sleep is prevented and the app
  stays runnable, subject to the excessive-CPU kill in §3.

**Practically:** hold a wakelock for any run that must survive screen-off, keep
the Termux notification visible (it is also how the user unlocks), and do not
assume a run that survived 30 minutes in the foreground survives 30 minutes in
your pocket.

**Marked as reasoning, not measurement:** the exact threshold at which this
device freezes a running guest was not measured; no screen-off duration sweep was
performed.

## 6. Network handover, and why gvproxy's exit is the real mobility hazard

### The measured fact

`gvproxy` **exits when its BESS peer disconnects.** The log line is:

```
gvproxy exiting: cannot receive packets from @, disconnecting: ... EOF
```

The BESS peer is the guest's vector transport, i.e. the UML process. So:

- Every guest shutdown/exit takes gvproxy with it — expected, but it means gvproxy
  is a **per-run** process, never a daemon you start once and forget.
- Every *involuntary* death of the UML process (phantom killer, AMS CPU kill, LMK)
  takes gvproxy with it, and the host-side port-forward mappings registered
  through `services/forwarder/expose` die with it. A user who loses the guest this
  way does not just lose the containers: the `127.0.0.1:8123` listener is gone
  too, and any other app on the phone holding that URL sees a connection refused.

That is the mobility hazard: the failure mode is silent, and it is a *network*
failure that looks like an application bug.

### Network handover

WiFi to cellular (or vice versa) changes the host's default route and the
addresses the host's own sockets are bound to. The guest's traffic reaches Android
through gvproxy's host-side sockets, so:

- **Reasoned, not measured here:** an established guest TCP connection is expected
  to break on handover, and gvproxy is expected to continue running but with stale
  host sockets until it re-establishes outbound connections. Nothing in this
  project was tested across an actual WiFi/cellular handover; treat any guarantee
  about it as unverified.
- A handover that drops the UML process (rather than just the sockets) is worse:
  it triggers the EOF cascade above.
- **Do not assume** a NAT'd container connection survives roaming. Short-lived,
  retried requests survive handovers well; long-lived streams should be treated as
  disposable.

### What to do about it

- Supervise the pair, not the parts. Treat "UML process alive **and** gvproxy
  alive **and** the forwarder mappings present" as one health condition; if any of
  the three is false, restart the whole run from a clean state.
- Do not reuse a guest across a network change; re-run it.
- Re-register forwards after every restart — `expose` is not persisted.
- Expect `127.0.0.1:2222 → guest:22` (gvproxy's default) to vanish on the same
  event.

## 7. Mitigation checklist

Copy this into a device setup note. Items marked *(one-time)* are done once per
device; the rest are per-run or per-charge-cycle.

- [ ] **(one-time)** Enable **Developer options → Disable child process restrictions**
      (Android 14+). On Android 12/13, use the adb `max_phantom_processes` route
      in §2 instead.
- [ ] **(one-time)** Verify the toggle stuck:
      `adb shell device_config get activity_manager max_phantom_processes` should
      read `2147483647` when set via adb.
- [ ] **(one-time)** Exempt Termux from battery optimization in Android settings
      (Apps → Termux → Battery → Unrestricted). Prevents the most aggressive
      background restrictions; it does not stop the phantom killer.
- [ ] **(per run)** Hold a wakelock: `termux-wake-lock` before boot, release after.
- [ ] **(per run)** Keep the Termux notification visible; do not let the app be
      swiped away — swiping kills the guest.
- [ ] **(per run)** Size the guest conservatively (`mem=1024M` was the working
      point at ~2.1 GB free) and keep the ext4 image on fast, free storage.
- [ ] **(per run)** Boot with `seccomp=on` and the CPU count you actually need:
      the default ptrace mode is both slower and single-CPU, so a workload that
      needs 4 CPUs will look "excessively CPU hungry" for far longer.
- [ ] **(per run)** Start gvproxy under `proot -b $PREFIX/etc:/etc` (it needs
      `/etc/resolv.conf`), then verify it is listening before booting UML.
- [ ] **(per run)** After boot, re-register every port forward via
      `POST /services/forwarder/expose`; nothing is persisted.
- [ ] **(always)** Never use `exit` in the guest — `poweroff -f`.
- [ ] **(always)** After any unexpected container or daemon disappearance, check
      the phantom-killer toggle before debugging Docker.
- [ ] **(monitoring)** Watch for the gvproxy EOF line: it is the earliest signal
      that the guest died underneath you.

## 8. What to measure on a new device before trusting it

Do these **before** relying on the device, in this order. Each is cheap; the first
one usually fails.

1. **API level floor.** Android 11+ in practice. The bionic builds need
   `statx(30)` and `getrandom(28)`; a report exists of Android 10 failing with
   `SIGSYS` ("Bad system call"). Check `getprop ro.build.version.sdk` (≥ 30).
2. **Architecture and page size.** `uname -m` must be `aarch64`. Check the host
   page size too — the guest uses 16 KB pages, which works on both 4 KB and 16 KB
   hosts, but a 16 KB host is worth confirming (`getconf PAGESIZE`).
3. **The app sandbox's shape.** `cat /proc/self/status | grep -E 'CapEff|CapBnd'`
   should be zero. Note whether `/proc/sys` is readable; the port does not need it,
   but scripts that assume it will mislead you.
4. **Boot gate.** The plain Alpine shell boot must print the kernel banner and a
   prompt. If this fails, nothing downstream will work; capture the whole log.
5. **Interception modes.** Confirm which mode you actually get: default (expect
   `Userspace mode: ptrace`, 1 CPU) and forced (`seccomp=on`, `ncpus=4` → 4 CPUs).
   A device where `PTRACE_SYSEMU` is unavailable would be a different story; the
   boot-time check tells you.
6. **Guest config.** The docker-capable prerequisite check in
   [FORENSICS.md §3](FORENSICS.md#3-how-to-verify-a-kernel-is-docker-capable) —
   every symbol present, cgroup2 showing `cpu io memory pids`.
7. **Docker smoke test.** pull → run → exec → container-to-container ping, inside
   the guest.
8. **Phantom-killer headroom.** Start more than 32 guest child processes (e.g. a
   loop of `sleep` in the guest, or several containers) and see whether children
   start disappearing. Record the toggle state at the time.
9. **Memory headroom.** Boot with a modest `mem=` and watch the app's RSS / phone
   free memory; find the largest stable guest size before LMK pressure.
10. **Screen-off survival.** With a wakelock held, leave the screen off for a
    fixed period (e.g. 15 and 60 minutes) and check the guest is still alive.
    Without a wakelock, do the same and record how quickly it stops responding.
11. **Inbound path.** gvproxy + BESS + `expose`, then fetch from the phone:
    `curl -i http://127.0.0.1:<port>/`. This is the end-to-end test that matters
    most, and the one that distinguishes this project's path from the released
    `passt` bridge.
12. **Record it.** Produce a run summary JSON and a sanitised log per
    [../evidence/README.md](../evidence/README.md). If you cannot state the
    marker string, you have not verified the device.

Anything you skip here becomes an unverified claim in someone else's hands.
