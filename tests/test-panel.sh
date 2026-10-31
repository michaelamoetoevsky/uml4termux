#!/usr/bin/env bash
#
# The read-only status panel (direction D3).
#
# It runs a REAL daemon in --selftest mode, writes the registry record the launcher
# would write, starts the panel against that state directory, and then asserts what
# the panel reports. The last assertion executes the page's own script (node, with a
# stub DOM) against the panel's live reply: this device has no browser engine --
# Playwright answers "Unsupported platform: android" -- so a screenshot assertion is
# impossible here, and grepping the HTML would prove nothing. Running the page's
# code against real data is the strongest check available, and it is stated as such
# in docs/NEXT-STEPS.md rather than dressed up as a browser test.
#
# usage: tests/test-panel.sh [daemon-binary]
# SPDX-License-Identifier: GPL-2.0-only
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
fails=0
skips=0
daemon_pid=""
panel_pid=""

cleanup() {
  for p in "${panel_pid}" "${daemon_pid}"; do
    [ -n "${p}" ] && kill -TERM "${p}" 2>/dev/null
  done
  sleep 1
  for p in "${panel_pid}" "${daemon_pid}"; do
    [ -n "${p}" ] && kill -KILL "${p}" 2>/dev/null
  done
  rm -rf "${work}"
}
trap 'cleanup' EXIT

ok()  { printf '  PASS: %s\n' "$1"; }
bad() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }
skip() { printf '  SKIP: %s\n' "$1"; skips=$((skips + 1)); }
chk() { # <description> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi
}
has() { # <description> <needle> <haystack>
  case "$3" in
    *"$2"*) ok "$1" ;;
    *) bad "$1 (no '$2' in: $(printf '%s' "$3" | head -c 140))" ;;
  esac
}

# --- the daemon under test (same rule as the other daemon-driven tests) --------
mkdir -p "${work}/probe"
runnable() { # <binary> -> 0 when this host can execute it
  local out rc
  out="$(UML4TERMUX_RUNTIME="${work}/probe" "$1" status 2>&1)"
  rc=$?
  case "${rc}" in 126 | 127) return 1 ;; esac
  case "${out}" in *"Exec format error"* | *"cannot execute"*) return 1 ;; esac
  return 0
}
compile_daemon() { # <out>
  { cc -O2 -o "$1" "${ROOT}/src/uml4termuxd.c" 2>/dev/null \
      || clang -O2 -o "$1" "${ROOT}/src/uml4termuxd.c" 2>/dev/null; } || return 1
  [ -x "$1" ]
}
DBIN="${1:-${UML4TERMUXD_BIN:-${ROOT}/bin/uml4termuxd}}"
if [ ! -x "${DBIN}" ] || ! runnable "${DBIN}"; then
  alt="${work}/uml4termuxd"
  if compile_daemon "${alt}" && runnable "${alt}"; then
    DBIN="${alt}"
  else
    echo "SKIP: ${DBIN} cannot run on this host and the source did not compile"
    exit 77
  fi
fi
echo "daemon under test: ${DBIN}"

# The panel's protocol queries shell out to the daemon; a path with spaces is not
# supported by that interface, so refuse loudly instead of failing obscurely later.
case "${DBIN}" in *' '*) echo "SKIP: daemon path contains a space"; exit 77 ;; esac

SELFTEST_SLEEP="${UML4TERMUXD_SELFTEST_CHILD:-$(command -v sleep || echo /bin/sleep)}"

printf '\nD3.1: panel reports a live daemon\n'
rt="${work}/rt"
state_dir="${work}/state"
mkdir -p "${rt}" "${state_dir}/instances"
UML4TERMUX_RUNTIME="${rt}" UML4TERMUXD_SELFTEST_SECONDS=180 \
  UML4TERMUXD_SELFTEST_CHILD="${SELFTEST_SLEEP}" "${DBIN}" daemon --selftest \
  >"${work}/daemon.log" 2>&1 &
daemon_pid=$!
i=0
while [ "${i}" -lt 40 ]; do
  [ -S "${rt}/daemon.sock" ] && UML4TERMUX_RUNTIME="${rt}" "${DBIN}" status >/dev/null 2>&1 && break
  sleep 0.5
  i=$((i + 1))
done
if [ -S "${rt}/daemon.sock" ]; then
  ok "daemon hidup (selftest)"
else
  bad "daemon tidak siap"; sed -n '1,8p' "${work}/daemon.log" | sed 's/^/    /'
fi

# The launcher writes this record; the panel only reads it. Writing it here keeps the
# test honest about which side owns what.
cat >"${state_dir}/instances/panel-test.env" <<EOF
NAME=panel-test
RUNTIME=${rt}
IMAGE=${work}/image.ext4
SSH_PORT=12699
PID=${daemon_pid}
STARTED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

port=$(( 8790 + ($$ % 40) ))
# The panel reads the registry from UML4TERMUX_STATE_DIR: without it the panel
# serves whatever HOME points at, and the test then asserts against an unrelated
# instance -- which is exactly how this test first "failed" while the panel was
# working perfectly.
UML4TERMUX_STATE_DIR="${state_dir}" python3 "${ROOT}/panel/serve.py" \
  --port "${port}" --daemon "${DBIN}" >"${work}/panel.log" 2>&1 &
panel_pid=$!
i=0
while [ "${i}" -lt 60 ]; do
  if curl -fsS --max-time 2 "http://127.0.0.1:${port}/healthz" >/dev/null 2>&1; then break; fi
  sleep 0.5
  i=$((i + 1))
done

chk "/healthz menjawab" "ok" "$(curl -fsS --max-time 5 "http://127.0.0.1:${port}/healthz" 2>/dev/null)"
page="$(curl -fsS --max-time 5 "http://127.0.0.1:${port}/" 2>/dev/null)"
has "halaman disajikan" 'data-testid="rows"' "${page}"
has "halaman menyebut dirinya read-only" 'data-testid="readonly"' "${page}"
chk "path tak dikenal -> 404" "404" \
  "$(curl -sS --max-time 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${port}/nope" 2>/dev/null)"

api="$(curl -fsS --max-time 15 "http://127.0.0.1:${port}/api/state" 2>/dev/null)"
has "api/state menyebut instance dari registry" '"name": "panel-test"' "${api}"
has "api/state melaporkan state daemon yang sebenarnya" '"state": "running"' "${api}"
has "api/state membawa balasan protokol apa adanya" '"status": "{\"state\"' "${api}"
has "api/state menandai dirinya read-only" '"read_only": true' "${api}"

printf '\nD3.2: panel menolak bind non-loopback\n'
out="$(python3 "${ROOT}/panel/serve.py" --host 0.0.0.0 --port "$(( port + 1 ))" --daemon "${DBIN}" 2>&1)"
rc=$?
chk "bind 0.0.0.0 tanpa --allow-lan ditolak (rc 64)" "64" "${rc}"
has "alasannya disebut" "without --allow-lan" "${out}"

printf '\nD3.3: skrip halaman merender state itu sendiri\n'
if command -v node >/dev/null 2>&1; then
  if node "${ROOT}/panel/render-check.mjs" "http://127.0.0.1:${port}" panel-test 2>&1 | tee "${work}/render.log" | sed 's/^/  /'; then
    ok "render-check lulus (JS halaman dijalankan terhadap payload nyata)"
  else
    bad "render-check gagal"
  fi
else
  skip "node tidak tersedia: render-check tidak bisa dijalankan di sini"
fi

# stop the daemon through the panel's own source of truth, then see the panel notice
UML4TERMUX_RUNTIME="${rt}" "${DBIN}" stop >/dev/null 2>&1
sleep 2
api2="$(curl -fsS --max-time 15 "http://127.0.0.1:${port}/api/state" 2>/dev/null)"
case "${api2}" in
  *'"state": "running"'*) bad "panel masih melaporkan running setelah daemon berhenti" ;;
  *) ok "panel mengikuti keadaan setelah daemon berhenti" ;;
esac

if [ "${fails}" -gt 0 ]; then
  printf '\n%d assertion(s) FAILED (%d skipped)\n' "${fails}" "${skips}"
  exit 1
fi
printf '\npanel: all assertions passed (%d skipped)\n' "${skips}"