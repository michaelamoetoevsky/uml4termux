#!/usr/bin/env bash
# Wait for the CI kernel build of upstream HEAD, then fetch it into the bench
# asset home as linux-head (direction A needs pin vs HEAD on the same device).
#
# usage: fetch-head-kernel.sh <run_id> [out_dir]
# SPDX-License-Identifier: GPL-2.0-only
set -uo pipefail

RUN="${1:?run id required}"
OUT="${2:-$TMPDIR/bench-assets}"
CREDS="$HOME/.hermes/cache/scratch/ghprobe/auth"
REPO="michaelamoetoevsky/uml4termux"
WORK="${TMPDIR:-/tmp}/head-kernel-${RUN}"

T="$(sed -n 's/^GITHUB_TOKEN=//p' "$HOME/.hermes/.env" | head -1 | tr -d '\r')"
[ -n "${T}" ] || { echo "no token"; exit 1; }
printf 'header = "Authorization: Bearer %s"\n' "$T" > "$CREDS"
chmod 600 "$CREDS"
trap 'rm -f "$CREDS"' EXIT

mkdir -p "$WORK"
echo "[$(date +%H:%M:%S)] waiting for run ${RUN}; local account cc unavailable offline, this may take ~20 min"

for i in $(seq 1 120); do
  st="$(curl -s --config "$CREDS" "https://api.github.com/repos/${REPO}/actions/runs/${RUN}" \
        | env -u LD_LIBRARY_PATH python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("status"), d.get("conclusion"))' 2>/dev/null)"
  case "$st" in
    "completed success") echo "[$(date +%H:%M:%S)] build completed successfully after $((i*30))s"; break ;;
    completed*) echo "[$(date +%H:%M:%S)] build ended as: $st"; exit 1 ;;
  esac
  [ $((i % 4)) -eq 0 ] && echo "[$(date +%H:%M:%S)] still $st (${i}x30s)"
  sleep 30
done

AID="$(curl -s --config "$CREDS" "https://api.github.com/repos/${REPO}/actions/runs/${RUN}/artifacts" \
      | env -u LD_LIBRARY_PATH python3 -c 'import json,sys; print(json.load(sys.stdin)["artifacts"][0]["id"])')"
echo "[$(date +%H:%M:%S)] artifact ${AID}, downloading"
curl -sL --config "$CREDS" -H 'Accept: application/vnd.github+json' \
  -o "$WORK/kernel.zip" "https://api.github.com/repos/${REPO}/actions/artifacts/${AID}/zip"
[ -s "$WORK/kernel.zip" ] || { echo "download failed"; exit 1; }
env -u LD_LIBRARY_PATH python3 - "$WORK/kernel.zip" "$WORK/x" <<'PY'
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1]); z.extractall(sys.argv[2])
for n in z.namelist()[:12]:
    print("   ", n, z.getinfo(n).file_size)
PY

KERN="$(find "$WORK/x" -type f -name 'linux*' -size +3M -perm -u+x 2>/dev/null | head -1)"
[ -n "$KERN" ] || KERN="$(find "$WORK/x" -type f -size +3M 2>/dev/null | head -1)"
[ -n "$KERN" ] || { echo "no kernel inside the artifact"; exit 1; }
mkdir -p "$OUT"
cp -f "$KERN" "$OUT/linux-head"
chmod 0755 "$OUT/linux-head"
echo "[$(date +%H:%M:%S)] installed $OUT/linux-head"
echo "sha256 $(sha256sum "$OUT/linux-head" | cut -d' ' -f1)"
echo "size $(stat -c%s "$OUT/linux-head")"
strings "$OUT/linux-head" | grep -m1 -oE 'Linux version [0-9][^ ]*' || true