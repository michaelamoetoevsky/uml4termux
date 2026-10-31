#!/usr/bin/env bash
#
# D4: real recipes with measured numbers, run inside a live guest.
#
# Direction D is about making this usable by someone else, and the honest part of
# that is telling them what to expect. The recipes below are the ones people
# actually ask for -- starting a container, serving HTTP, running a local registry --
# and every number printed here is a wall clock measured on this phone, not an
# estimate.
#
# Mechanics: each recipe is one `uml4termuxd exec` against a running instance, so the
# measurement includes exactly what a user waits for. The guest console echoes the
# command it runs, so every marker the harness greps for is sent base64-encoded: a
# literal marker in the command would satisfy the assertion through the echo alone.
#
# usage: UML4TERMUX_RUNTIME=<rt> bench/recipes.sh [--out DIR] [--guest-port N]
# SPDX-License-Identifier: GPL-2.0-only
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DBIN="${UML4TERMUXD_BIN:-${ROOT}/bin/uml4termuxd}"
RT="${UML4TERMUX_RUNTIME:?set UML4TERMUX_RUNTIME to a running instance}"
OUT="${TMPDIR:-/tmp}/uml4termux-recipes-$(date +%Y%m%d-%H%M%S)"
WAIT="${RECIPE_WAIT:-300}"

while [ $# -gt 0 ]; do
  case "$1" in
    --out)   OUT="${2:?--out needs a value}"; shift ;;
    --wait)  WAIT="${2:?--wait needs a value}"; shift ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "recipes: unknown option '$1'" >&2; exit 64 ;;
  esac
  shift
done

mkdir -p "${OUT}"
CONSOLE="${RT}/uml-console.log"
export UML4TERMUX_RUNTIME="${RT}"
# The recipes are one-off commands; the exec rate limit exists for a client that
# floods the socket, and would otherwise make this harness measure itself.
export UML4TERMUXD_EXEC_MIN_INTERVAL_MS=0
export NO_COLOR=1

say()  { printf '%s\n' "$*"; }
note() { printf '  %s\n' "$*"; }

# run_in_guest <label> <script> -- send one command, wait for its END marker
run_in_guest() {
  local label="$1" script="$2" mark plain t0 t1
  # Unique per run: the console log is written by the daemon at its own offset, so it
  # must NOT be truncated here (truncating a file a writer holds open leaves a NUL
  # hole and the scan then trips over null bytes). A per-run marker is what makes an
  # append-only log safely searchable instead.
  plain="D4$(printf '%s' "${label}" | tr -cd '[:alnum:]')$(date +%s)"
  mark="$(printf '%s' "${plain}" | base64)"
  t0="$(date +%s)"
  # The script prints <marker>-START / <marker>-END around its work, and the marker
  # itself only ever exists inside the guest's output because the command carries it
  # base64-encoded.
  "${DBIN}" exec "sh -c 'm=\$(echo ${mark} | base64 -d); echo \$m-START; ${script}; echo \$m-END'" \
    >"${OUT}/${label}.exec.json" 2>&1
  local i=0
  while [ "${i}" -lt "${WAIT}" ]; do
    grep -qa -- "${plain}-END" "${CONSOLE}" 2>/dev/null && break
    sleep 1
    i=$((i + 1))
  done
  t1="$(date +%s)"
  grep -a -- "${plain}" "${CONSOLE}" >"${OUT}/${label}.console.log" 2>/dev/null || true
  printf '%s' "${t1}" >"${OUT}/${label}.wall"
  printf '%s' "$(( t1 - t0 ))" >"${OUT}/${label}.seconds"
  if [ "${i}" -ge "${WAIT}" ]; then
    note "${label}: TIMEOUT after ${WAIT}s (see ${OUT}/${label}.console.log)"
    return 1
  fi
}

value_of() { # <marker syllable> <KEY> -- strip CR: the guest console is CRLF, and
  # "143293\r" is not a number as far as $(( )) is concerned.
  grep -a -- "-${2} " "${OUT}/${1}.console.log" 2>/dev/null | tail -1 | awk '{print $NF}' | tr -d '\r'
}

say "recipes: runtime=${RT} out=${OUT}"
say ""

# ---- R1: starting a container -------------------------------------------------
say "R1. container start latency (docker run --rm alpine true, 10x, warm image)"
run_in_guest r1 'docker run --rm alpine true >/dev/null 2>&1; s=$(date +%s%N); for i in $(seq 1 10); do docker run --rm alpine true >/dev/null 2>&1; done; e=$(date +%s%N); echo $m-TOTAL_MS $(( (e-s)/1000000 )); docker image inspect alpine --format "{{.Size}}" | head -1 | sed "s/^/$m-IMAGE_BYTES /"'
r1_total="$(value_of r1 TOTAL_MS)"
r1_bytes="$(value_of r1 IMAGE_BYTES)"
r1_wall="$(cat "${OUT}/r1.seconds" 2>/dev/null || echo 0)"
if [ -n "${r1_total}" ]; then
  note "10 starts in ${r1_total} ms wall -> median $(( r1_total / 10 )) ms per container start (harness wall ${r1_wall}s, includes the first cold pull)"
  note "image alpine on disk: $(( r1_bytes / 1024 / 1024 )) MiB"
else
  note "r1: no measurement (console in ${OUT}/r1.console.log)"
fi
say ""

# ---- R2: HTTP throughput (nginx behind docker's bridge) -----------------------
say "R2. nginx serving over the container bridge, measured with ab in a second container"
run_in_guest r2 'docker network create d4net >/dev/null 2>&1; docker rm -f d4web >/dev/null 2>&1; docker run -d --name d4web --network d4net nginx:alpine >/dev/null 2>&1; sleep 3; docker run --rm --network d4net httpd:alpine ab -n 500 -c 10 -q http://d4web/ 2>&1 | grep -E "Requests per second|Time per request|Failed requests" | sed "s/^/$m-AB /"; docker rm -f d4web >/dev/null 2>&1; docker network rm d4net >/dev/null 2>&1'
# ab prints "Requests per second:    76.32 [#/sec] (mean)"; the label itself has
# spaces, so the number is whatever follows the label, not a fixed column.
ab_value() { # <label>
  grep -a -- '-AB ' "${OUT}/r2.console.log" 2>/dev/null \
    | grep -a "$1" | tail -1 | sed 's/.*'"$1"': *//' | awk '{print $1}' | tr -d '\r'
}
r2_rps="$(ab_value 'Requests per second')"
r2_lat="$(grep -a -- '-AB ' "${OUT}/r2.console.log" 2>/dev/null | grep -a 'Time per request' | head -1 | sed 's/.*Time per request: *//' | awk '{print $1}' | tr -d '\r')"
r2_fail="$(ab_value 'Failed requests')"
if [ -n "${r2_rps}" ]; then
  note "500 requests, concurrency 10: ${r2_rps} req/s, ${r2_lat} ms per request, failed requests: ${r2_fail:-0}"
else
  note "r2: no measurement (console in ${OUT}/r2.console.log)"
fi
say ""

# ---- R3: a local registry -----------------------------------------------------
say "R3. local registry: push and pull a real image through it"
run_in_guest r3 'docker rm -f d4reg >/dev/null 2>&1; docker run -d -p 5000:5000 --name d4reg registry:2 >/dev/null 2>&1; sleep 4; docker build -t 127.0.0.1:5000/d4:1 - >/dev/null 2>&1 <<EOF
FROM alpine
RUN echo d4 > /d4.txt
EOF
s=$(date +%s%N); docker push 127.0.0.1:5000/d4:1 >/dev/null 2>&1; e=$(date +%s%N); echo $m-PUSH_MS $(( (e-s)/1000000 )); docker rmi 127.0.0.1:5000/d4:1 >/dev/null 2>&1; s=$(date +%s%N); docker pull 127.0.0.1:5000/d4:1 >/dev/null 2>&1; e=$(date +%s%N); echo $m-PULL_MS $(( (e-s)/1000000 )); docker image inspect 127.0.0.1:5000/d4:1 --format "{{.Size}}" | sed "s/^/$m-IMAGE_BYTES /"; docker rm -f d4reg >/dev/null 2>&1'
r3_push="$(value_of r3 PUSH_MS)"
r3_pull="$(value_of r3 PULL_MS)"
r3_bytes="$(value_of r3 IMAGE_BYTES)"
if [ -n "${r3_push}" ] && [ -n "${r3_pull}" ]; then
  note "push ${r3_push} ms, pull ${r3_pull} ms for a $(( r3_bytes / 1024 )) KiB image"
else
  note "r3: no measurement (console in ${OUT}/r3.console.log)"
fi

# ---- summary ------------------------------------------------------------------
env -u LD_LIBRARY_PATH python3 - "$OUT" <<'PY'
import json, pathlib, sys
out = pathlib.Path(sys.argv[1])
def v(name, key):
    f = out / f"{name}.console.log"
    if not f.exists():
        return None
    for line in reversed(f.read_text(errors="replace").splitlines()):
        parts = line.split()
        if len(parts) >= 2 and parts[-2] == key:
            return parts[-1].strip()
    return None
def wall(name):
    f = out / f"{name}.seconds"
    return int(f.read_text().strip()) if f.exists() else None
summary = {
    "container_start_media_ms": (lambda t: t // 10 if t else None)(int(v("r1", "TOTAL_MS") or 0)),
    "container_start_total_ms": int(v("r1", "TOTAL_MS") or 0) or None,
    "alpine_bytes": int(v("r1", "IMAGE_BYTES") or 0) or None,
    "registry_push_ms": int(v("r3", "PUSH_MS") or 0) or None,
    "registry_pull_ms": int(v("r3", "PULL_MS") or 0) or None,
    "harness_wall_seconds": {n: wall(n) for n in ("r1", "r2", "r3")},
}
(out / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
print("  summary -> " + str(out / "summary.json"))
PY
say ""
say "raw consoles and the per-recipe exec replies are in ${OUT}"