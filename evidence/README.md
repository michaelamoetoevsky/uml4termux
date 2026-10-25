# Evidence

Every capability claim in this repository has to point at a run recorded here.
The rule that makes that possible is short:

> **The verdict is the marker string, never the exit status.**

A run is PASS only when the expected marker text appears in a captured log. An
exit code of `0` with no marker is a **FAIL**. A non-zero exit with the marker
present is a **PASS with a note**. Everything else in this document is
bookkeeping around that one rule.

Read this before adding a run, and read
[../docs/FORENSICS.md](../docs/FORENSICS.md) for the checks a run should contain.

---

## 1. Why the marker rule exists

Exit statuses lie in this environment, in both directions:

- **False success.** A wrapper script can exit `0` because the thing it started
  exited `0` — while the guest never got to the state under test. The classic case
  in this project is a helper that goes away when its peer does: a process can
  report a *clean* shutdown of a run that never worked.
- **False failure.** A timeout, a killed supervisor, or a `gvproxy` that exits
  because the BESS peer disconnected (`cannot receive packets from @ ... EOF`) all
  produce non-zero exits around a guest that was perfectly fine up to that point.
  Conversely, the guest cannot exit at all — `exit` hangs it, so `poweroff -f` is
  the only clean ending, and the host side often sees something other than a tidy
  `0`.

So a verdict must rest on evidence that the *guest* produced. The marker is that
evidence: a string that only appears if the behaviour actually happened, printed
into a log that is captured and committed.

Practical consequences:

- Each check declares **one marker string**, and the log file expected to contain
  it. If you cannot name the marker, you do not have a check — you have a hope.
- `process_exit_status` may be recorded for a run, but it is **informational
  only** and can never change a verdict.
- The marker must be specific enough not to appear by accident (`OK` is a bad
  marker; `BUSYBOX_RUN_OK` after a `docker run` is a good one), and stable enough
  that tools can grep for it.
- If a marker is missing, the correct action is to say so, not to lower the bar.
  An honest FAIL is worth more than a vague PASS.

## 2. Layout and naming scheme

One directory per run, one run per directory:

```
evidence/
├── README.md
├── schema.json          (see §4 for its structure)
├── 2026-10-26-android16-aarch64-runbook/
│   ├── evidence.json      validated against schema.json
│   ├── boot.log           kernel boot, includes the Userspace mode line
│   ├── guest.log          guest-side checks and their markers
│   ├── gvproxy.log        gvproxy lifecycle (including any EOF exit)
│   └── host.log           host-side commands and their output
└── 2026-10-25-android16-aarch64-config-matrix/
    ├── evidence.json
    └── guest.log
```

**Naming scheme:**

```
evidence/<YYYY-MM-DD>-android<API>-<arch>-<slug>/
```

- `<YYYY-MM-DD>` — date the run was **executed** (not the date of the commit).
- `android<API>` — Android API level of the device, e.g. `android16`. API level
  matters more than the marketing version, because the floor here is API 30.
- `<arch>` — `aarch64` (the only architecture supported).
- `<slug>` — what the run demonstrates, lowercase, hyphenated:
  `runbook`, `config-matrix`, `interception-modes`, `passt-inbound-negative`,
  `gvproxy-expose`, `phantom-killer-probe`.

If the same slug runs twice on the same day, suffix `-2`, `-3`, … — never
overwrite a run. A run is a measurement, and measurements are not edited.

Inside `evidence.json`, `run_id` must equal the directory name exactly. That is the
one field that ties the JSON to the files, and CI checks it.

## 3. Evidence file: `evidence.json` (schema v1)

The `evidence.json` file in each run directory is the *only* JSON CI validates.
It conforms to [`schema.json`](schema.json) (JSON Schema draft-07, see §4).

### Core required fields

| Field | Type | Meaning |
|---|---|---|
| `schema_version` | string `"1.0"` | Schema version. |
| `project_version` | string `"0.1.0"` | `uml4termux` VERSION at the time of the run. |
| `run_id` | string | Must equal the evidence directory name. |
| `generated_at` | date-time (RFC 3339) | When the record was written. |
| `device` | object | The physical device. |
| `device.model` | string | e.g. `Pixel 8` from `getprop ro.product.model`. |
| `device.android_release` | string | e.g. `"16"` from `getprop ro.build.version.release`. |
| `device.abi` | `"arm64-v8a"` or `"aarch64"` | Primary ABI. |
| `device.unprivileged` | boolean, **must be `true`** | This project only runs unprivileged. |
| `device.termux_version` | string (optional) | Termux app version and source (F-Droid/Play/GitHub). |
| `device.cpu_count` | integer ≥1 (optional) | Online CPUs visible to the Termux process. |
| `host` | object (optional) | Userspace environment. |
| `host.python` | string (optional) | Python version available. |
| `host.gvproxy_version` | string (optional) | gvproxy version when used. |
| `host.free_memory_mb` | integer (optional) | Free memory for context on guest sizing. |
| `kernel` | object | The guest kernel that was booted. |
| `kernel.booted` | boolean | `true` iff the guest reached userspace (init ran). |
| `kernel.arch` | `"um/arm64"` (required) | SUBARCH the UML build targeted. |
| `kernel.release` | string (optional) | Guest `uname -r` string when booted. |
| `kernel.source_commit` | string (optional) | Downstream port commit the kernel was built from. |
| `kernel.boot_seconds` | number ≥0 (optional) | Wall-clock seconds from start to guest userspace. |
| `capabilities` | object | Which headline capabilities were exercised. |
| `capabilities.boot` | probe | `{ "ok": true, "evidence": "..." }`. Required. |
| `capabilities.docker` | probe (optional) | Docker exercised in this run. |
| `capabilities.overlay2` | probe (optional) | Storage driver is overlay2. |
| `capabilities.cgroup_v2` | probe (optional) | cgroup v2 with controllers. |
| `capabilities.seccomp_fast_path` | probe (optional) | seccomp interception mode active. |
| `capabilities.vcpu_count` | integer ≥1 (optional) | Guest vCPUs configured. |
| `capabilities.networking_gvproxy` | probe (optional) | gvproxy networking worked. |
| `capabilities.bess_transport` | probe (optional) | BESS transport active. |
| `capabilities.port_forwarding_loopback` | probe (optional) | Port exposed to 127.0.0.1. |
| `observed` | object (optional) | Exact versions, commands, one-line results. |
| `observed.docker_version` | string (optional) | e.g. `"20.10.24"`. |
| `observed.storage_driver` | string (optional) | e.g. `"overlay2"`. |
| `observed.container_image` | string (optional) | Image name used. |
| `observed.container_port` | integer (optional) | Guest container port. |
| `observed.host_port` | integer (optional) | Phone-side listener port. |
| `observed.host_port_check` | string (optional) | Command that proved forwarding, e.g. `curl -i http://127.0.0.1:8123/`. |
| `known_limits_observed` | array of strings (optional) | Limits that showed up in this run, e.g. `"cpuset controller unavailable"`, `"no swap limit support"`, `"no 32-bit compat (i386 binaries do not run)"`. |
| `verdict` | `"pass" \| "fail" \| "partial" \| "unknown"` | Overall result. `pass` = every capability with `ok: true` was directly observed. |
| `notes` | string (optional) | Anything a reader must know to reproduce or distrust this record. |
| `artifacts` | array of objects (optional) | Pointers to bulky evidence: `{ "kind": "console-log" \| "screenshot" \| "sha256sums" \| "other", "path": "...", "sha256": "..." }`. Raw logs match `.gitignore` (`*.raw.log`). |

### The `probe` shape

Each capability field is an object with:

```json
{
  "ok": true,
  "evidence": "verbatim line from a log that justifies 'ok'"
}
```

- `ok` is the boolean result.
- `evidence` is the **verbatim** line (or short command) that a reviewer can
  grep for in the attached logs. If you cannot produce a one-line evidence string,
  you do not have a probe — you have a hope.

This is the structured counterpart of the marker rule: `evidence` *is* the marker,
and `ok` is the verdict for that probe.

## 4. The schema file

[`schema.json`](schema.json) is the authoritative JSON Schema (draft-07). CI
validates every `evidence.json` against it. Do not edit the schema without also
updating all existing evidence files and the CI workflow that validates them.

Key design choices in the schema:

- `additionalProperties: true` on most objects — allows future fields without
  breaking validation, while keeping required fields strict.
- `capabilities` is an object of probes, not a flat list, so new capabilities can
  be added by adding a new property.
- `verdict` uses lowercase (`pass`/`fail`/`partial`/`unknown`) to match the
  rest of the project's JSON conventions.
- `device.unprivileged` is a `const: true` — a run claiming to be this project
  but running with root is not a valid record for this project.

## 5. Recording a run

1. **Run the checks** from the device, capturing output to files as you go. Do not
   reconstruct logs afterwards — the log is the artefact.
2. **Confirm the evidence lines.** For each capability you claim, find the
   one-line verbatim evidence in your logs. If it is absent, the probe is `ok:
   false`.
3. **Sanitise** (§6).
4. **Write `evidence.json`**, with `run_id` matching the directory and every
   field traceable to what the logs show.
5. **Checksum the pair** if you are publishing the run somewhere outside the
   repository.
6. **Commit** under `evidence/<run-id>/`; CI validates the JSON, checks each
   referenced log exists and is non-empty, and checks that every `ok: true`
   probe's `evidence` string appears in at least one attached log.

### Evidence quality bar

A stranger must be able to (a) see which device and kernel produced the run,
(b) reproduce the commands, and (c) find each probe's `evidence` string in the
attached logs. If any of the three is impossible, the run is an anecdote, not
evidence.

## 6. Sanitisation

Logs from a phone carry identifiers. Strip them, and record that you did.

Remove at least:

- device serial numbers, IMEI/MEID, phone numbers, Android ID, advertising ID;
- hostnames and usernames (`$HOME` paths contain the Termux username);
- the phone's own MAC addresses and any real-world IP addresses of the device or
  its carrier — the guest's synthetic addresses (`192.168.127.2`, `172.17.0.2`)
  and the loopback are fine and should be kept, because they are part of what is
  being verified;
- any API tokens, registry credentials, `docker login` config, SSH keys;
- filesystem paths that identify a person, beyond the generic prefix.

Keep: kernel versions, config symbols, syscall/interception lines, docker output,
marker strings, timestamps, guest-internal addresses, and the geometry of the run.

List every removal in a `note` or in `notes`, e.g.:

```json
"notes": "device serial replaced with <serial>; termux username in paths replaced with <user>; host MAC addresses replaced with <mac>; wifi BSSID removed from host log line 12"
```

An empty sanitisation note is a claim that nothing needed removing. Make it
honestly.

**One more reason to be careful:** a guest with `hostfs` mounted can write to host
files. Do not record a run as evidence if the guest under test had `hostfs` access
to the workspace containing the evidence — the thing being judged could have
edited the judgement. Note the mount configuration in `notes`.

## 7. Worked example

A run that demonstrates the boot gate, Docker inside the guest, and inbound
port forwarding via gvproxy/BESS:

```json
{
  "schema_version": "1.0",
  "project_version": "0.1.0",
  "run_id": "2026-10-26-android16-aarch64-runbook",
  "generated_at": "2026-10-26T03:58:11+07:00",
  "device": {
    "model": "Pixel 8",
    "android_release": "16",
    "abi": "aarch64",
    "unprivileged": true,
    "termux_version": "0.118.0 (F-Droid)",
    "cpu_count": 8
  },
  "host": {
    "python": "3.14.6",
    "gvproxy_version": "v0.9.0",
    "free_memory_mb": 2150
  },
  "kernel": {
    "booted": true,
    "arch": "um/arm64",
    "release": "7.2.0-rc4-opt",
    "source_commit": "169b17ff3f66d507cb137b770ceb1fd9f4547a32",
    "boot_seconds": 2.3
  },
  "capabilities": {
    "boot": { "ok": true, "evidence": "Userspace mode: SECCOMP" },
    "docker": { "ok": true, "evidence": "SERVER=20.10.24+dfsg1 DRIVER=overlay2 CGROUPV=2" },
    "overlay2": { "ok": true, "evidence": "Storage Driver: overlay2  Backing Filesystem: extfs  Native Overlay Diff: true" },
    "cgroup_v2": { "ok": true, "evidence": "cgroup2_controllers=cpu io memory pids" },
    "seccomp_fast_path": { "ok": true, "evidence": "Userspace mode: SECCOMP" },
    "vcpu_count": 4,
    "networking_gvproxy": { "ok": true, "evidence": "DHCPREQUEST for 192.168.127.2 on vec0" },
    "bess_transport": { "ok": true, "evidence": "vec0:transport=bess,dst=/data/data/com.termux/files/usr/tmp/bess.sock,depth=128,gro=1,mac=5a:94:ef:e4:0c:ee" },
    "port_forwarding_loopback": { "ok": true, "evidence": "127.0.0.1:8123 -> 'HTTP/1.1 200 OK\\r\\nContent-Length: 15\\r\\n\\r\\ngvproxy-bess-ok\\n'" }
  },
  "observed": {
    "docker_version": "20.10.24+dfsg1",
    "storage_driver": "overlay2",
    "container_image": "busybox:latest",
    "container_port": 8123,
    "host_port": 8123,
    "host_port_check": "curl -i http://127.0.0.1:8123/"
  },
  "known_limits_observed": [
    "cpuset controller unavailable",
    "no swap limit support",
    "no 32-bit compat (i386 binaries do not run)"
  ],
  "verdict": "pass",
  "notes": "Single device (Android 16, aarch64). This run does not establish anything about other devices, Android versions, long-run stability, or the 32-bit/cpuset/swap-limit gaps. gvproxy exited with EOF after guest shutdown — per-run process only.",
  "artifacts": [
    { "kind": "console-log", "path": "guest.log", "sha256": "<64 hex chars>" },
    { "kind": "console-log", "path": "gvproxy.log", "sha256": "<64 hex chars>" },
    { "kind": "sha256sums", "path": "SHA256SUMS", "sha256": "<64 hex chars>" }
  ]
}
```

Note what the example does *not* do: it does not claim multi-device support, it
does not cite an exit status as a verdict, and its `notes` say out loud what the
run cannot be used to prove.

## 8. Non-negotiables

- The verdict is the marker string (`evidence` line), never the exit status.
- Never edit a committed run to make it pass; add a new run.
- Never cite a run as evidence for a device other than the one recorded in it.
- Never record a run performed with `hostfs` access to the evidence workspace
  without saying so in `notes`.
- Sanitise, and say what you sanitised.
- If an `evidence` string is missing from the logs, the probe is `ok: false`.