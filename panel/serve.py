#!/usr/bin/env python3
"""Read-only status panel for uml4termux.

Three deliberate constraints, each of which a reviewer should hold this file to:

  * LOOPBACK ONLY. The default bind is 127.0.0.1 and anything else requires
    --allow-lan, because what sits behind this page is the state of the user's
    guests -- on a phone, "the LAN" means a network the user did not choose.
  * READ-ONLY. The page lists guests and exposures and hands you the exact command
    to start or stop one; it does not perform the mutation itself. The daemon's HTTP
    endpoint is unauthenticated (docs/THREAT-MODEL.md names that as a residual
    risk), so adding start/stop on top of it would trade a documented limit for an
    undocumented hole. A read-only page cannot do that.
  * THE CONTRACT, NOT THE FILES. Guest state comes from the daemon's own client
    commands (protocol v1: `status`, `ports`), which tests/test-runtime-contract.sh
    asserts; the name -> runtime mapping comes from the launcher's registry, which
    the launcher owns. Nothing here parses a daemon state file or scrapes
    human-readable output, so a change inside the daemon cannot silently produce a
    wrong number on this page.

usage: panel/serve.py [--port 8788] [--host 127.0.0.1] [--allow-lan]
# SPDX-License-Identifier: GPL-2.0-only
"""
from __future__ import annotations

import argparse
import http.server
import json
import os
import pathlib
import socketserver
import subprocess
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]
# The daemon binary is a parameter, not a constant: bin/uml4termuxd is built for the
# device (bionic/aarch64) and cannot execute on an x86 CI runner, where the tests
# hand over the binary they just compiled. UML4TERMUXD_BIN is the same override the
# other harnesses use.
DAEMON = pathlib.Path(os.environ.get("UML4TERMUXD_BIN", ROOT / "bin" / "uml4termuxd"))


def daemon_cmd(verb: str, runtime: str, timeout: float = 6.0) -> dict:
    """Ask the daemon one protocol question; return its parsed and raw reply."""
    env = dict(os.environ)
    env["UML4TERMUX_RUNTIME"] = runtime
    env.pop("LD_LIBRARY_PATH", None)
    try:
        p = subprocess.run([str(DAEMON), verb], env=env, capture_output=True,
                           text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return {"rc": 124, "data": None, "raw": f"(no reply within {timeout}s)"}
    except OSError as exc:
        return {"rc": 127, "data": None, "raw": str(exc)}
    raw = p.stdout.strip()
    try:
        data = json.loads(raw) if raw else None
    except json.JSONDecodeError:
        data = None
    return {"rc": p.returncode, "data": data, "raw": raw or p.stderr.strip()}


def instances(state_dir: pathlib.Path) -> list[dict]:
    """One <name>.env per instance, written by the launcher (it owns the registry)."""
    out = []
    for f in sorted((state_dir / "instances").glob("*.env")):
        rec = {}
        for line in f.read_text(errors="replace").splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                rec[k.strip()] = v.strip()
        rec["name"] = f.stem
        out.append(rec)
    return out


def snapshot() -> dict:
    state_dir = pathlib.Path(os.environ.get(
        "UML4TERMUX_STATE_DIR", pathlib.Path.home() / ".uml4termux" / "state"))
    guests = []
    for rec in instances(state_dir):
        name = rec["name"]
        rt = rec.get("RUNTIME") or rec.get("runtime") or ""
        st = daemon_cmd("status", rt) if rt else {"rc": 127, "data": None, "raw": ""}
        ports = daemon_cmd("ports", rt) if rt else {"rc": 127, "data": None, "raw": ""}
        st_data = st["data"] or {}
        exposures = (ports["data"] or {}).get("exposures", []) if ports["data"] else []
        guests.append({
            "name": name,
            "runtime": rt,
            "image": rec.get("IMAGE", ""),
            "ssh_port": rec.get("SSH_PORT", ""),
            "launcher_pid": rec.get("PID", ""),
            "state": st_data.get("state", f"no reply (rc={st['rc']})"),
            "guest_pid": st_data.get("child_pid", ""),
            "restarts": st_data.get("restarts", ""),
            "uptime_s": st_data.get("uptime_s", ""),
            "mem": st_data.get("mem", ""),
            "ncpus": st_data.get("ncpus", ""),
            "kernel": st_data.get("kernel", ""),
            "exposures": exposures,
            # The replies themselves stay in the payload: when a field above looks
            # wrong, the source must be visible, or this page is one more thing that
            # hides its evidence.
            "protocol_raw": {"status": st["raw"], "ports": ports["raw"]},
            # What the page offers INSTEAD of a control endpoint.
            "commands": {
                "stop": f"uml4termux down --name {name}",
                "start": (f"uml4termux up --name {name} --image {rec.get('IMAGE', '<image>')}"
                          f" --mem {rec.get('MEM', '2048M')}"),
            },
        })
    return {
        "generated_at": int(time.time()),
        "state_dir": str(state_dir),
        "guest_count": len(guests),
        "guests": guests,
        "read_only": True,
        "note": ("Read-only by design: the daemon's HTTP endpoint is unauthenticated "
                 "(docs/THREAT-MODEL.md), so this page shows state and gives you the "
                 "command to run rather than mutating anything. State comes from "
                 "protocol v1 (status, ports), never from daemon files."),
    }


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "uml4termux-panel/1"

    def _send(self, code: int, body: bytes, ctype: str) -> None:
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802  (http.server's interface)
        path = self.path.split("?", 1)[0]
        if path in ("/", "/index.html"):
            self._send(200, (ROOT / "panel" / "index.html").read_bytes(),
                       "text/html; charset=utf-8")
        elif path == "/api/state":
            self._send(200, json.dumps(snapshot(), indent=2).encode(),
                       "application/json")
        elif path == "/healthz":
            self._send(200, b"ok\n", "text/plain")
        else:
            self._send(404, b"not found\n", "text/plain")

    def log_message(self, format: str, *args) -> None:  # noqa: A002 (base class name)
        """Silence per-request logging: the page polls every couple of seconds."""
        pass


def main() -> int:
    global DAEMON
    ap = argparse.ArgumentParser()
    # 8080 is the most contested port there is, and on this device another service
    # already holds it, whose replies then look like this panel's bug.
    ap.add_argument("--port", type=int, default=8788)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--daemon", default=str(DAEMON),
                    help="daemon binary used for protocol queries (default: the "
                         "tracked one, or $UML4TERMUXD_BIN)")
    ap.add_argument("--allow-lan", action="store_true",
                    help="permit binding a non-loopback address (off by default)")
    args = ap.parse_args()

    DAEMON = pathlib.Path(args.daemon)
    if not os.access(DAEMON, os.X_OK):
        print(f"panel: daemon not executable: {DAEMON}", flush=True)
        return 74

    if not args.allow_lan and args.host not in ("127.0.0.1", "::1", "localhost"):
        print(f"panel: refusing to bind {args.host} without --allow-lan", flush=True)
        return 64

    # allow_reuse_address belongs on the class: setting it after construction is too
    # late for bind, and a restart then hits EADDRINUSE.
    class Server(socketserver.TCPServer):
        allow_reuse_address = True

    try:
        with Server((args.host, args.port), Handler) as srv:
            print(f"panel: http://{args.host}:{args.port}/ (read-only, loopback)",
                  flush=True)
            try:
                srv.serve_forever()
            except KeyboardInterrupt:
                pass
    except OSError as exc:
        print(f"panel: cannot bind {args.host}:{args.port}: {exc} -- pick another with "
              f"--port", flush=True)
        return 74
    return 0


if __name__ == "__main__":
    raise SystemExit(main())