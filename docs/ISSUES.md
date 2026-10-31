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
| 6 | Upstream patch prepared, not submitted | — | repository owner's approval |

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

## 6. Upstream patch prepared, not submitted

See `docs/UPSTREAM-PR-1.md`: a small harness guard for the packaging fork
(`Raymer8639/linux-um-arm64`), where UML holds an exclusive `F_SETLK` on a backing
image and a second boot on the same image silently runs diskless. Prepared with the
device evidence; publishing it needs the same go-ahead as #5.