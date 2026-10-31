#!/usr/bin/env bash
# Measure how much `exec` payload actually ARRIVES, and how long it takes.
#
# Two independent witnesses per size, both from the guest's own console:
#   * the agent echoes every line it receives ("__AGENT_GOT__: <line>"), so counting the
#     pad bytes in that line is a byte-exact delivery check;
#   * __EXEC_<seq>_DONE_ sits at the END of the line the daemon writes, so its arrival
#     proves the whole line got through, not a prefix.
# Emits one machine-readable line per size; bench/exec-limit-evidence.py turns them into
# an evidence record, so no number in that record is re-typed by hand.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
A=${A:-${TMPDIR:-/tmp}/bench-assets}
W=${W:-$(mktemp -d)}
mkdir -p "$W"   # W may be passed in and need not exist yet
IMG=$W/image.ext4
OUT=$W/results.txt
: > "$OUT"

[ -f "$A/linux-bionic" ] && [ -f "$A/debian-docker.ext4" ] || {
  echo "  SKIP: assets not present under $A"; exit 77; }

cp --sparse=always "$A/debian-docker.ext4" "$IMG" || { echo "  cannot copy image"; exit 1; }

export UML4TERMUX_HOME=$A UML4TERMUXD_BIN=$PWD/bin/uml4termuxd
export UML4TERMUX_STATE_DIR=$W/state UML4TERMUX_RUNTIME=$W/rt UML4TERMUX_KERNEL_FILE=linux-bionic
export UML4TERMUXD_EXEC_MIN_INTERVAL_MS=0
LOG=$W/rt/uml-console.log

bin/uml4termux up --name execlim --image "$IMG" --mem 1024M --ssh-port 12688 --timeout 300 >"$W/up.log" 2>&1 || {
  echo "  SKIP: instance did not come up here (see $W/up.log)"; exit 77; }
for _ in $(seq 1 90); do grep -aq 'TICK' "$LOG" 2>/dev/null && break; sleep 2; done

# Sizes are the COMMAND length (pad + ": "). 1998 -> 2000 bytes delivered, 1999+ -> over
# the limit and refused: the point of the run is both halves of that boundary.
for n in 498 1198 1998 2000 2498; do
  pad=$(env -u LD_LIBRARY_PATH python3 -c "print('x'*$n)")
  out=$("$UML4TERMUXD_BIN" exec ": $pad" 2>&1); rc=$?
  seq=$(printf '%s' "$out" | sed -n 's/.*"seq":\([0-9]*\).*/\1/p')
  t0=$(date +%s); done_seen=0; agent_bytes=0
  if [ -n "$seq" ]; then
    for _ in $(seq 1 150); do
      if grep -aq "__EXEC_${seq}_DONE_" "$LOG" 2>/dev/null; then done_seen=1; break; fi
      sleep 2
    done
    line=$(grep -a "__AGENT_GOT__.*__EXEC_${seq}_BEGIN__" "$LOG" 2>/dev/null | tail -1)
    [ -n "$line" ] && agent_bytes=$(printf '%s' "$line" | sed 's/^.*__AGENT_GOT__: //' | tr -cd 'x' | wc -c)
  fi
  t1=$(date +%s)
  printf 'EXECLIMIT size=%s seq=%s rc=%s agent_bytes=%s done=%s elapsed_s=%s\n' \
    "$((n+2))" "${seq:-0}" "$rc" "$agent_bytes" "$done_seen" "$((t1-t0))" >> "$OUT"
  tail -1 "$OUT" | sed 's/^/  /'
done

bin/uml4termux down --name execlim >/dev/null 2>&1
echo "  results: $OUT"
echo "$OUT" > "$W/results.path"