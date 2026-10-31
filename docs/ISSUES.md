# Open issues

Things that are **known, open, and deliberately not fixed yet**. Each entry says what
was measured, what it costs, and what "done" would look like.

Different from [KNOWN-LIMITS.md](KNOWN-LIMITS.md): that file lists limits this
project does not intend to remove (architectural, kernel, Android). This file lists
gaps that should be closed — with an owner-visible plan, so nothing here is a
sentence that quietly rots.

| # | Issue | Severity | Blocked on |
|---|---|---|---|
| 1 | `exec` drops a command line above ~568 bytes, silently | high | nothing — a fix is described below |
| 2 | Local-registry recipe has no number (`registry:2` pull never completes) | low | device network/time |
| 3 | The status panel is verified by executing its script, not by rendering it | low | a browser engine on Android |
| 4 | `expose HOST:GUEST` once logged the host port as the guest port — **unverified** | unknown | a clean reproduction |
| 5 | `termux-packages` PR prepared, not submitted | — | repository owner's approval |
| 6 | Upstream patch **sent** as PR #26 — watching for a response | — | upstream response (30-day clock) |
| 7 | `up` on the shared asset image booted a guest that exited at once — **unverified** | unknown | a clean reproduction |

---

## 1. `exec` silently drops a command line above ~568 bytes — HIGH

**Measured** (`docs/RUNTIME-CONTRACT.md` §9a): a 569-byte command reached the guest
and ran; a 2182-byte one did nothing at all while the daemon answered `rc=0`. The
command is delivered as one console line; the guest agent reads it with
`IFS= read -r aline` on `/dev/console` and evals it, and the PTY truncates beyond that.

**Why it is high severity:** the failure is invisible. A client sees success and the
guest did nothing. Every other failure in this project at least says so.

**Worked around, not fixed:** `bench/guest-put.sh` uploads a script as base64 in
≤380-byte chunks (verified: 1057 B in 4 chunks, 60/60 markers intact).

**Done looks like:** the daemon refuses an over-long command with
`{"error":"command too long","limit":N}` before it writes anything to the PTY, and a
test asserts both the refusal and that the limit is the one documented. Enlarging the
guest's line buffer is the alternative, but a visible refusal is the better failure.

**Where:** `src/uml4termuxd.c` (the `exec` branch), `rust/src/daemon.rs` for parity,
`tests/test-runtime-contract.sh` for the gate.

---

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

## 3. The panel is verified by executing its script, not by rendering it — LOW

**Measured:** this device has no browser engine. Playwright answers
`Unsupported platform: android`, and the local Chromium backend is not installed, so
`tests/test-panel.sh` runs the page's own JavaScript in node against the panel's live
reply, with a DOM stub (`panel/render-check.mjs`). That is stronger than grepping the
HTML and weaker than a browser assertion; the docs say exactly that.

**Done looks like:** a browser-based check — a Playwright (or WebView) run on an
Android host that asserts the rendered DOM and attaches a screenshot — added beside
the node check rather than replacing it.

---

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

## 7. `up` on the shared asset image: the guest exited immediately — UNVERIFIED

**Observed twice** while chasing issue #4, both times with
`--image $UML4TERMUX_HOME/debian-docker.ext4` (the shared asset, used directly rather
than copied): `up` failed, and the daemon log it printed said

```
uml4termuxd[26667]: child 26692 died (exit 0)
uml4termuxd[26667]: guest session completed; not restarting
uml4termuxd[26667]: gvproxy stopped
```

i.e. the kernel came up and exited cleanly within about a second, so the console never
had a guest to show. `up` did report the failure and printed those lines — the
fail-fast path added in direction D worked — but *why* the guest exits is not known.

**Not a reproduction of #4.** It was found while trying to reproduce #4, and it blocks
that reproduction rather than explaining it.

**Why it might happen, untested:** that image was written by the interrupted
registry-pull runs in direction D4 and may carry a dirty journal, so the guest's own
init could be bailing out; or the shared path is being opened by something else. Both
are guesses.

**Workaround that is already the project's practice:** every harness copies the image
per instance (`soak/soak.sh`, `soak/snapshot-check.sh`, `bench/recipes.sh`) — 90/90 and
80/80 clean cycles on copies — and passes `UML4TERMUXD_STRICT_UBD=1`.

**Done looks like:** a test that boots an instance on a *freshly copied* asset image and
on the shared asset image, and asserts the same exit state for both; if the shared case
really is the dirty image, the answer is that `fetch`/`init-image` must produce a clean
one and `up` should refuse an image whose ext4 journal is dirty instead of booting a
guest that dies. Until then the entry stays as an observation with a workaround, not a
diagnosis.
