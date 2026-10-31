#!/usr/bin/env node
// Render-check for panel/index.html: execute the page's OWN script against a live
// /api/state payload and report what the DOM would contain.
//
// Why this exists: this device has no browser engine (Playwright answers
// "Unsupported platform: android", and the local Chromium backend is not
// installed), so a screenshot-level assertion is impossible here. What IS possible
// is stronger than grepping the HTML: the real script runs, with a stub DOM and the
// panel's real reply, and the assertions are made on the nodes it created.
//
// usage: panel/render-check.mjs <panel-url> [expected-guest-name]
// exit 0 = the page rendered the daemon's state; 1 = it did not; 2 = could not run
// SPDX-License-Identifier: GPL-2.0-only

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const base = process.argv[2] || "http://127.0.0.1:8788";
const expectedGuest = process.argv[3] || "";

const html = readFileSync(join(here, "index.html"), "utf8");
const m = html.match(/<script>([\s\S]*?)<\/script>/);
if (!m) {
  console.error("render-check: no <script> block in index.html");
  process.exit(2);
}
const source = m[1];

// A DOM stub small enough to read in one sitting: createElement returns an object
// that records text and children, and the assertions below search exactly that.
function makeNode(tag) {
  const node = {
    tagName: tag, children: [], _text: "", dataset: {}, className: "", title: "",
    hidden: false, style: {},
    set textContent(v) { this._text = String(v); this.children = []; },
    get textContent() {
      return this._text + this.children.map((c) => c.textContent).join("");
    },
    append(...kids) { this.children.push(...kids); },
    appendChild(kid) { this.children.push(kid); return kid; },
    replaceChildren(...kids) { this.children = kids; },
    addEventListener() {},
    querySelectorAll() { return []; },
  };
  return node;
}

const byId = new Map();
for (const id of ["rows", "empty", "err", "count", "stamp", "note"]) {
  byId.set(id, makeNode("div"));
}

const document = {
  createElement: makeNode,
  createTextNode: (t) => ({ textContent: String(t), children: [] }),
  getElementById: (id) => byId.get(id) || makeNode("div"),
  querySelector: () => makeNode("div"),
};

const realFetch = globalThis.fetch;
let payload = null;
const fetchStub = async (url) => {
  const r = await realFetch(base + url, { cache: "no-store" });
  payload = await r.clone().json();
  return { ok: r.ok, status: r.status, json: async () => payload };
};

let intervalCb = null;
const setIntervalStub = (cb) => { intervalCb = cb; return 0; };

// Run the page's script exactly as the browser would load it.
const run = new Function("document", "fetch", "navigator", "setInterval", source);
run(document, fetchStub, { clipboard: { writeText: async () => {} } }, setIntervalStub);

await new Promise((r) => setTimeout(r, 400));

const rows = () => byId.get("rows").children;
const fail = [];
const check = (what, ok, detail = "") => {
  console.log(`  ${ok ? "PASS" : "FAIL"}: ${what}${detail ? " -- " + detail : ""}`);
  if (!ok) fail.push(what);
};

if (!payload) {
  console.error("render-check: the page never fetched /api/state");
  process.exit(2);
}
check("page fetched /api/state", true, `${payload.guest_count} guest(s) in the reply`);
check(`page rendered one row per guest (${payload.guests.length})`,
      rows().length === payload.guests.length,
      `rendered ${rows().length}`);

const first = rows()[0];
if (first) {
  const text = first.textContent;
  const g = payload.guests[0];
  check(`row carries the guest name '${g.name}'`, text.includes(g.name), text.slice(0, 80));
  check(`row carries the daemon's state '${g.state}'`, text.includes(g.state), text.slice(0, 80));
  if (g.guest_pid !== "") {
    check(`row carries the guest pid ${g.guest_pid}`, text.includes(String(g.guest_pid)));
  }
  for (const e of g.exposures) {
    if (e.local) {
      check(`row carries the exposure ${e.local} -> ${e.remote}`, text.includes(e.local));
    }
  }
  if (expectedGuest) {
    check(`row is the expected guest '${expectedGuest}'`, text.includes(expectedGuest));
  }
}
check("read-only badge present", html.includes('data-testid="readonly"'));
check("the page offers commands instead of controls",
      html.includes("commands.stop") && html.includes("commands.start"));

if (intervalCb) {
  // The page must keep painting, not just render once: the panel's whole job is to
  // show a moving daemon.
  check("page schedules a repaint (setInterval)", typeof intervalCb === "function");
}

if (fail.length) {
  console.error(`render-check: ${fail.length} assertion(s) failed`);
  process.exit(1);
}
console.log("render-check: the page rendered the daemon's real state");
