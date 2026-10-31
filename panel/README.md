# panel/ — read-only status page

```sh
uml4termux panel                 # http://127.0.0.1:8788/
uml4termux panel --port 9123     # another port (8080 is often taken)
uml4termux help panel            # the same text as this file, from the CLI
```

What it shows, per instance the launcher has registered: the name, the daemon's
state and the guest pid, uptime, the memory and CPU count the guest was started
with, its SSH port, and every exposure — plus the exact command to start or stop
that guest.

## Two decisions a reviewer should check

**Read-only.** The page does not start or stop anything; it hands you the command.
The reason is security rather than laziness: the daemon's HTTP endpoint
(`UML4TERMUXD_HTTP`) is unauthenticated — `docs/THREAT-MODEL.md` lists that as a
residual risk — so adding a control endpoint on top of it would trade a documented
limit for an undocumented hole. Buttons that copy a command get the convenience
without the exposure.

**Loopback only.** The default bind is `127.0.0.1`, and anything else requires
`--allow-lan`. The page reports what is running on the user's phone; on a phone,
"the LAN" is a network the user did not choose.

## Where the numbers come from

Not from the daemon's files. Guest state is read through the daemon's own client
commands — protocol v1 `status` and `ports`, the same replies
`tests/test-runtime-contract.sh` asserts — and the name → runtime mapping comes from
the launcher's registry, which the launcher owns. The raw replies are included in
`/api/state` under `protocol_raw`, so a wrong number on the page can be traced to
the reply it came from instead of being taken on trust.

## Files

| File | What it is |
|---|---|
| `serve.py` | the server: `GET /`, `GET /api/state`, `GET /healthz` (stdlib only) |
| `index.html` | the page: no framework, no build step, polls `/api/state` every 2s |
| `render-check.mjs` | runs the page's own script against a live reply and asserts what it rendered |

## Testing, and its one honest limit

```sh
tests/test-panel.sh              # runs a real daemon, a real panel, and asserts both
node panel/render-check.mjs http://127.0.0.1:8788 <guest>
```

`render-check.mjs` exists because this device has **no browser engine**: Playwright
answers `Unsupported platform: android`, and the local Chromium backend is not
installed. A screenshot assertion is therefore impossible here, and grepping the
HTML would prove nothing about what the page displays. Running the page's own
JavaScript against the panel's live reply, with a stub DOM, is the strongest check
available — and it is named as such rather than called a browser test.

To look at it with your own eyes, open the URL on the phone whose guests it shows.
