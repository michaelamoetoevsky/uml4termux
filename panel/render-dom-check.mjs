// Render the panel in a REAL DOM and assert what a reader would see.
//
// Why this exists beside render-check.mjs: that check runs the page's script against a
// hand-written DOM stub, which proves the JS logic but not that the HTML parses into
// the elements the script expects. jsdom parses the actual file, builds the actual
// element tree, and executes the page's own inline script -- so a renamed id, a broken
// tag nest or a selector that matches nothing now FAILS instead of silently rendering
// an empty page.
//
// What it still cannot do: layout, CSS, paint, screenshot. This device has no browser
// engine at all (Playwright: "Unsupported platform: android"; the local
// agent-browser/Chromium backend: not installed), so "verified in a browser" remains
// unproven here and docs/KNOWN-LIMITS.md says so.
//
// Usage: node panel/render-dom-check.mjs <payload.json> [--empty]
//   0 = assertions passed, 1 = a failure, 77 = jsdom unavailable (SKIP)

import { readFileSync } from 'node:fs';

// Resolve jsdom the CJS way: NODE_PATH is honoured by require() but NOT by ESM
// `import` of a bare specifier, which is why the first version of this file reported
// SKIP while jsdom sat installed next to it. JSDOM_MODULE=/abs/path is the explicit
// escape hatch.
import { createRequire } from 'node:module';
import { pathToFileURL } from 'node:url';

const require = createRequire(import.meta.url);
let jsdomMod = null;
try {
  jsdomMod = require('jsdom');
} catch {
  if (process.env.JSDOM_MODULE) {
    jsdomMod = await import(pathToFileURL(process.env.JSDOM_MODULE).href).catch(() => null);
  }
}
if (!jsdomMod) {
  console.log('SKIP: jsdom not installed (npm install jsdom in a scratch dir and set NODE_PATH)');
  process.exit(77);
}
const { JSDOM } = jsdomMod;

const payloadPath = process.argv[2];
if (!payloadPath) {
  console.error('usage: render-dom-check.mjs <payload.json> [--empty]');
  process.exit(1);
}
const payload = JSON.parse(readFileSync(payloadPath, 'utf8'));
const html = readFileSync(new URL('./index.html', import.meta.url), 'utf8');

let pass = 0;
const fails = [];
const ok = (cond, label) => {
  if (cond) { pass += 1; console.log(`  PASS: ${label}`); }
  else { fails.push(label); console.log(`  FAIL: ${label}`); }
};

// The page calls poll() at parse time (classic script at the end of <body>), so the
// stub fetch must exist BEFORE the script runs -- beforeParse is the hook that
// guarantees that. Installing it after construction (the first version) rendered the
// untouched placeholder page, which is exactly the false negative this check exists to
// catch, pointed at itself.
const dom = new JSDOM(html, {
  runScripts: 'dangerously',
  url: 'http://127.0.0.1:8788/',
  pretendToBeVisual: true,
  beforeParse(win) {
    win.fetch = async (url) => {
      if (String(url).includes('/api/state')) {
        return { ok: true, status: 200, json: async () => payload };
      }
      return { ok: false, status: 404, json: async () => ({}) };
    };
  },
});
const { window } = dom;
// The first poll is async; give it a turn to resolve and render.
await new Promise((r) => setTimeout(r, 300));

const doc = window.document;
const text = (sel) => (doc.querySelector(sel)?.textContent || '').trim();
const guests = Array.isArray(payload.guests) ? payload.guests : [];

ok(text('#err') === '', 'no error banner rendered');
ok(/guest\(s\)/.test(text('#count')), `count rendered ("${text('#count')}")`);
ok(text('#stamp') !== '', 'timestamp rendered');
ok(
  text('#count') === `${guests.length} guest(s)`,
  `count matches the payload (${guests.length})`
);

const bodyRows = doc.querySelectorAll('#rows tr');
ok(
  bodyRows.length === guests.length,
  `one table row per guest (${bodyRows.length} rows, ${guests.length} guests)`
);

for (const g of guests) {
  const name = g.name || g.instance || '';
  const rows = [...bodyRows].map((r) => r.textContent).join('\n');
  ok(name ? rows.includes(name) : true, `guest "${name}" appears in the table`);
  ok(
    rows.includes(g.phase || '') || !g.phase,
    `guest "${name}" shows its phase (${g.phase})`
  );
}

// Empty state: with no guests the table must not pretend otherwise.
if (guests.length === 0) {
  const emptyHidden = doc.querySelector('#empty')?.hasAttribute('hidden');
  ok(emptyHidden === false, 'empty state is shown when there are no guests');
}

// The page must not throw while rendering: jsdom surfaces uncaught errors here.
const errs = [];
window.addEventListener('error', (e) => errs.push(e.message || String(e.error)));
await new Promise((r) => setTimeout(r, 50));
ok(errs.length === 0, `no uncaught script errors (${errs.join('; ') || 'none'})`);

console.log(`  rendered ${bodyRows.length} row(s) from ${guests.length} guest(s)`);
console.log(`  TOTAL pass=${pass} fail=${fails.length}`);
process.exit(fails.length ? 1 : 0);