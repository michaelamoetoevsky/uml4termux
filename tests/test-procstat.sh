#!/usr/bin/env bash
# The parser exists because a process whose comm contains a space or ')' breaks the naive
# `stat.read().split()` -- that is what killed the first attempt at counting the instance's host
# children ("ValueError: invalid literal for int(): '@playw)'"). Test the pure parse against a
# CRAFTED line of exactly that shape, plus the live /proc of this shell; do not depend on a
# process happening to be named awkwardly (`exec -a` does not survive on Termux).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

HOSTILE='1234 (we ird)name) S 3713 1234 1234 0 -1 4194560 100 0 0 0 1 1 0 0 20 0 1 0 99999 0 0 0 0 0 0 0 0 0 0 0 0 17 0 0 0 0 0 0'

got=$(env -u LD_LIBRARY_PATH python3 ci/procstat.py parse "$HOSTILE")
[ "$got" = "3713" ] && ok "ppid from a line whose comm contains a space and ')'" \
  || bad "parse: got '$got', want 3713"

# the naive parser must MISREAD the same line, or the test is not exercising the trap
naive=$(env -u LD_LIBRARY_PATH python3 -c "
line = '''$HOSTILE'''
try:
    print(int(line.split()[3]))
except Exception as e:
    print(type(e).__name__)
")
[ "$naive" != "3713" ] && ok "naive split demonstrably misreads it ($naive)" \
  || bad "naive split got the right answer -- the trap was not reproduced"

# live process: parsing this shell's own stat must agree with the ppid lookup
live=$(env -u LD_LIBRARY_PATH python3 ci/procstat.py parse "$(cat /proc/$$/stat)")
want=$(env -u LD_LIBRARY_PATH python3 ci/procstat.py ppid "$$")
[ -n "$live" ] && [ "$live" = "$want" ] && ok "live /proc parse agrees with ppid lookup ($live)" \
  || bad "live parse '$live' != ppid lookup '$want'"

# a missing process answers None instead of raising
gone=$(env -u LD_LIBRARY_PATH python3 ci/procstat.py ppid 99999999)
[ "$gone" = "None" ] && ok "missing pid answers None instead of raising" || bad "missing pid: '$gone'"

echo "  TOTAL pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]