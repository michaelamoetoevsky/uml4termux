# Open issues

Things that are **known, open, and deliberately not fixed yet**. Each entry says what
was measured, what it costs, and what "done" would look like.

Different from [KNOWN-LIMITS.md](KNOWN-LIMITS.md): that file lists limits this
project does not intend to remove (architectural, kernel, Android). This file lists
gaps that should be closed — with an owner-visible plan, so nothing here is a
sentence that quietly rots.

| # | Issue | Severity | Blocked on |
|---|---|---|---|
| ~~1~~ | ~~`exec` drops a command line above ~568 bytes, silently~~ — **CLOSED: three silent truncations found and fixed, measured limit enforced** | was: high | — |
| 2 | Local-registry recipe has no number (`registry:2` pull never completes) | low | device network/time |
| ~~3~~ | ~~The status panel is verified by executing its script, not by rendering it~~ — **CLOSED for the DOM, residual gap moved to KNOWN-LIMITS** | low | — |
| 4 | `expose HOST:GUEST` once logged the host port as the guest port — **unverified** | unknown | a clean reproduction |
| 5 | `termux-packages` PR prepared, not submitted | — | repository owner's approval |
| 6 | Upstream patch **sent** as PR #26 — watching for a response | — | upstream response (30-day clock) |
| ~~7~~ | ~~`up` on the shared asset image booted a guest that exited at once~~ — **CLOSED, root cause found** | was: unknown | — |

---

## 1. CLOSED — three silent truncations plus a measured limit

**What the code actually did** (found while chasing the reported symptom): three
independent places cut a command, none of them said so, and the guest's `__EXEC_n_DONE`
marker still appeared — so the client saw `rc=0` while the guest ran a fragment.

1. `main()` joined argv into `char joined[900]` after testing `used` **before** copying a
   whole argument; one long argument walked past the end. Proven on the device: the old
   front end **segfaulted** (`rc=139`) on a 3 000-byte argument.
2. `client_line()` built the request with `snprintf` into `char buf[1024]`, so the real
   limit was 1 022 bytes with no message.
3. The daemon read the request with **one** `read()` into `char req[512]`; anything longer
   was cut at 511 bytes and the half line was still executed.

**What the device then measured** (one command per line, timing until
`__EXEC_<seq>_DONE_`, which sits at the END of the line and therefore proves the whole
line arrived; the agent's own `__AGENT_GOT__` echo proves the bytes):

| command | arrived whole? | time to DONE |
|---|---|---|
| 502 B | yes | ~0 s |
| 2 002 B | yes | 1 s |
| 2 502 B | yes — `x_diterima=2500/2500` | 40 s |
| 2 902 B | no | not in 279 s |

So long commands are not truncated, they are **slow**: delivery cost grows with length.
That makes a refusal above a measured ceiling the honest behaviour, not a smaller buffer.

**Fixed:** the limit is **2 000 bytes**, enforced at both hops (front end: exit 64 with
`command too long: N bytes, limit 2000`; daemon: `{"error":"command too long","limit":2000}`),
the request is read until newline into an 8 KiB buffer, and the front end measures before
it copies. `docs/RUNTIME-CONTRACT.md` §9a now carries the table above and the three bugs.

**Gate:** `tests/test-exec-limit.sh` — 10 assertions over both implementations (C and
Rust), no guest needed: refusal at limit+1 with the documented number, acceptance at the
limit, a long request read whole rather than half-parsed, and the front end's exit 64.

## 2. The local-registry recipe has no number — LOW

**Measured:** pulling `registry:2` from Docker Hub inside the guest did not finish in
over ten minutes; `alpine`, `nginx:alpine` and `httpd:alpine` pull and run fine in the
same guest, so it is image size over the guest network rather than a broken path. The
recipe is therefore blocked *before* its push, and
`evidence/20261031-dir-d-ecosystem.json` records no number for it instead of a partial
one. The mechanism is proven: the recipe script arrives in four base64 chunks and the
guest runs it (markers committed).

**Done looks like:** one run of
`bench/recipes.sh --wait 1200` on a quiet device that reaches `PUSH_MS`/`PULL_MS`, and
the numbers added to the direction-D evidence.

---

## 3. CLOSED for the DOM — a real renderer is still absent, and that is now a known limit

**Done here:** `panel/render-dom-check.mjs` renders the real `panel/index.html` in
**jsdom** — the actual HTML is parsed into the actual element tree and the page's own
inline script runs — against a **real** `/api/state` payload captured from a live
instance. 8 assertions: no error banner, `N guest(s)` matching the payload, timestamp,
one row per guest, the guest name in the table, its phase, the empty state when there are
no guests, and no uncaught script errors. First run against a 1-guest payload: 8/8.

It caught its own false negative first: the stub `fetch` was installed after
construction, the page's `poll()` had already run, and the check rendered an empty page
while reporting on the placeholder — fixed with `beforeParse`. A check that cannot fail
is not a check.

**Still unproven, and now written where limits live:** layout, CSS and a screenshot need
a browser engine. Verified unavailable on this device — Playwright MCP answers
`Unsupported platform: android`, and the local browser backend is not installed
(`agent-browser CLI not found`). `docs/KNOWN-LIMITS.md` says so, so nobody reads the
gate as "rendered in a browser".

**Gate:** `tests/test-panel.sh` runs the jsdom check when jsdom is importable and SKIPs
with the reason when it is not (the project does not add a runtime dependency for a
test); CI installs it in its own step.

## 4. `expose HOST:GUEST` once logged the host port as the guest port — UNVERIFIED

**Observed once** during direction D3: `expose 12661:8123` produced a daemon log line
`exposed 127.0.0.1:12661 -> 192.168.127.2:12661`, i.e. the guest port looked dropped.

**Not reproduced.** Reading the code afterwards, both paths split the mapping
correctly — `lib/net.sh:net_parse_mapping` and the daemon's `expose <host> <guest>`
handler, which the CLI feeds two arguments — and a `--dry-run` of the same command
prints `{"local":"127.0.0.1:12700","remote":"192.168.127.2:8123"}`, which is right. The
observed line most likely came from a different exposure in the same session (the
first, malformed invocation in that session never reached the daemon). A clean
reproduction attempt was inconclusive because the guest powered off before the test.

**Done looks like:** a test that starts an instance, exposes `12700:8123`, and asserts
the daemon's reply AND the registry file carry `8123` as the guest port — so the
question stops depending on anybody's memory. If the test fails, fix the split; if it
passes, delete this entry.

---

## 5. `termux-packages` PR prepared, not submitted

`packaging/termux/build.sh` (v0.5.0, digest pinned) and `packaging/termux/PR.md` are
ready. Opening a PR against someone else's repository is a public action on an
external project, so it waits for the repository owner's explicit go-ahead.

---

## 6. Upstream patch sent — PR #26, waiting on the maintainer

**Sent 2026-10-31:** [Raymer8639/linux-um-arm64#26](https://github.com/Raymer8639/linux-um-arm64/pull/26)
— `harness: refuse a second boot on a backing image another UML holds`. Opened from
`michaelamoetoevsky:harness/image-lock`; the API reports `state=open, mergeable=true,
changed_files=1, +34 -0`, and the public page renders the title and body. That fork
runs no CI for pull requests, so the only checks are the ones described in the body
(patch applies to HEAD, guard refuses with exit 2 when the image is held, behaviour
unchanged when free, and `ci/upstream/image-lock-probe.py` pins the per-process lock
trap).

**Done looks like:** a maintainer answer either way. If it is merged, the guard has one
implementation upstream and our `UML4TERMUXD_STRICT_UBD` stays the second line of
defence. If there is no response in 30 days (until 2026-11-30), the entry closes as
"no upstream response" and F1 stays the only path — the project ships a kernel it
builds and tests itself, so nothing here blocks a release.

---

## 7. CLOSED — the shared asset image was simply already locked

**Root cause (measured).** The guest did not die because of the image's contents. UML
takes an exclusive `F_SETLK` on the backing image, and the shared asset, its symlink
target and `~/.local/share/uml4termux/debian-docker.ext4` are **one inode** — so the
runit service's own guest was holding it. The console log says it plainly:

```
F_SETLK failed, file already locked by pid 26563
Failed to lock '.../uml-forensics/debian-docker.ext4', err = 11
ubda: Can't open ".../exp.cow": errno = 11
UML4TERMUX_INIT NO_DISK: no /dev/ubda, running /docker-init.sh inside the initramfs
```

The guest booted with no disk, found nothing to mount, and powered off with exit 0 — a
*clean* exit that reads as a finished session. The earlier "dirty ext4 journal" guess
was wrong: it is the F_SETLK trap again, in its third disguise.

**Fixed.** The daemon refuses before spawning anything: `F_GETLK` (read-only; it neither
takes nor disturbs the lock) asks the kernel who holds it, and a held image stops the
boot with `uml4termuxd: image already in use by pid N`, `rc=2`.
`UML4TERMUXD_ALLOW_SHARED_IMAGE=1` restores the old behaviour on purpose, and
`UML4TERMUXD_STRICT_UBD=1` stays the second line of defence. The launcher now says
`the daemon refused to start: …` instead of blaming a timeout that never happened
(measured: the refusal takes 3 s, not 15).

**Gate:** `tests/test-image-lock.sh` — locked image refused with the holder's pid in the
message, free image not accused, override really bypasses, for **both** daemons (C and
Rust, 6/6). Contract: `docs/RUNTIME-CONTRACT.md` §9b.
