#!/usr/bin/env bash
# The console stamper is what makes a phase breakdown possible, so it gets a test of its own:
# it must attach a time to every line it sees, survive a file that does not exist yet, and stop
# when asked. Without this, "dockerd took 149 s" is a claim; with it, it is a timestamp.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
W=$(mktemp -d)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

SRC=$W/console.log; TIMED=$W/timed.txt; STOP=$W/stop

# start against a file that does not exist yet: the daemon creates it later, and a stamper that
# exits immediately would miss the whole boot
env -u LD_LIBRARY_PATH python3 bench/console-stamp.py "$SRC" "$TIMED" --stop-file "$STOP" &
SPID=$!
sleep 0.3
printf 'Linux version 7.2.0\r\n' > "$SRC"
printf 'UML4TERMUX_INIT mounts_ok\r\n' >> "$SRC"
printf 'starting dockerd...\r\n' >> "$SRC"
sleep 1.2
touch "$STOP"
wait "$SPID" 2>/dev/null

lines=$(wc -l < "$TIMED" 2>/dev/null || echo 0)
[ "$lines" -ge 3 ] && ok "stamped all $lines appended line(s)" || bad "stamped only $lines line(s)"

# every stamped line must start with an epoch and a TAB. `grep -c` prints 0 AND exits 1 on no
# match, so the usual `|| echo 0` yields two lines and every later comparison breaks -- count
# once, in a helper, and compare a single value.
count() { local n; n=$(grep -cE "$1" "$2" 2>/dev/null); [ -n "$n" ] || n=0; printf '%s' "$n"; }
malformed=$(count '^([0-9]+\.[0-9]+	).*' "$TIMED")
total=$(count '.' "$TIMED")
malformed=$((total - malformed))
[ "$malformed" = 0 ] && ok "every line carries an epoch + tab" || bad "$malformed line(s) without a stamp"

# the stamps must be monotonic: time moves forward in a log
mono=$(env -u LD_LIBRARY_PATH python3 - "$TIMED" <<'PY'
import sys
stamps = [float(l.split('\t', 1)[0]) for l in open(sys.argv[1]) if '\t' in l]
print('yes' if stamps == sorted(stamps) else 'no')
PY
)
[ "$mono" = yes ] && ok "timestamps are monotonic" || bad "timestamps go backwards"

# and the markers survive: the phase logic greps for exactly these strings
for m in 'Linux version' 'UML4TERMUX_INIT' 'starting dockerd'; do
  grep -q "$m" "$TIMED" && ok "marker preserved: $m" || bad "marker lost: $m"
done

rm -rf "$W"
echo "  TOTAL pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]