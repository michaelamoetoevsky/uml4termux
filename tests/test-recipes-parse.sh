#!/usr/bin/env bash
# The recipes summary is an artifact, so its parser needs a test of its own: it used to
# record null for every value the run had measured, because the marker is a PREFIX
# ("D4r<epoch>-PUSH_MS 10074") and the parser compared the whole token to the key.
# The run that exposed it printed "push 10074 ms" to the screen and wrote null to
# summary.json -- the screen is not the artifact.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
ROOT=$PWD
W=$(mktemp -d)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

# A fixture that looks like the guest console: CRLF endings, marker prefix, noise.
printf 'boot noise\r\nD4r1793459678-START\r\ndocker push ok\r\nD4r1793459678-PUSH_MS 10074\r\n' > "$W/r3.console.log"
printf 'D4r1793459123-PULL_MS 5444\r\nD4r1793459678-IMAGE_BYTES 8657124\r\n' >> "$W/r3.console.log"
printf 'D4r1793459123-TOTAL_MS 157404\r\nD4r1793459123-IMAGE_BYTES 8657121\r\n' > "$W/r1.console.log"
for n in r1 r2 r3; do printf '100\n' > "$W/$n.seconds"; done

env -u LD_LIBRARY_PATH python3 "$ROOT/bench/recipes-summary.py" "$W" > "$W/out.log" 2>&1
rc=$?
[ "$rc" = 0 ] && ok "summariser exits 0" || { bad "summariser failed"; sed 's/^/    | /' "$W/out.log"; }

read_json() { env -u LD_LIBRARY_PATH python3 -c "import json,sys;print(json.load(open('$W/summary.json')).get('$1'))"; }

[ "$(read_json registry_push_ms)" = "10074" ] && ok "registry_push_ms parsed from a prefixed marker" || bad "registry_push_ms = $(read_json registry_push_ms)"
[ "$(read_json registry_pull_ms)" = "5444" ] && ok "registry_pull_ms parsed from a prefixed marker" || bad "registry_pull_ms = $(read_json registry_pull_ms)"
[ "$(read_json registry_image_bytes)" = "8657124" ] && ok "registry_image_bytes parsed" || bad "registry_image_bytes = $(read_json registry_image_bytes)"
[ "$(read_json container_start_media_ms)" = "15740" ] && ok "median start derived from TOTAL_MS" || bad "container_start_media_ms = $(read_json container_start_media_ms)"
[ "$(read_json alpine_bytes)" = "8657121" ] && ok "alpine size parsed" || bad "alpine_bytes = $(read_json alpine_bytes)"

# A missing marker must stay null, not become 0 or a guess.
rm -f "$W/r3.console.log"
env -u LD_LIBRARY_PATH python3 "$ROOT/bench/recipes-summary.py" "$W" >/dev/null 2>&1
[ "$(read_json registry_push_ms)" = "None" ] && ok "absent marker stays null" || bad "absent marker became $(read_json registry_push_ms)"

rm -rf "$W"
echo "  TOTAL pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]