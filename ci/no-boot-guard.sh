#!/usr/bin/env bash
# ci/no-boot-guard.sh -- fail if a CI workflow tries to *boot* User-Mode Linux
# or the container stack.
#
# Why this exists
# ---------------
# GitHub-hosted runners cannot run uml4termux at all: the UML arm64 port must
# run on an Android/Termux device with the correct SUBARCH, and the emulated
# UML build needs the device's own toolchain. A successful CI run therefore
# proves *packaging and lint* health only -- never that a kernel booted.
#
# If somebody later adds a step that actually launches the thing, this guard
# fails loudly instead of letting a red run masquerade as coverage.
#
# Rules:
#   * scan .github/workflows/*.yml and *.yaml, plus ci/*.sh
#   * ignore comment lines (leading whitespace then '#')
#   * ignore this file itself
#   * match an invocation of the CLI's boot/run/start verbs, or a direct
#     golden-mean/UML kernel launch (a *.uml / linux binary executed),
#     on a non-comment line.
#
# Exit: 0 clean, 1 violation found, 77 nothing to scan.
set -uo pipefail

# Allow --help/-h to show usage and exit 0
case "${1:-}" in
  -h|--help)
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
esac

root=${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
cd "$root" || exit 1

files=()
while IFS= read -r f; do
  files+=("$f")
done < <(
  {
    find .github -type f \( -name '*.yml' -o -name '*.yaml' \) -print 2>/dev/null
    find ci -maxdepth 1 -type f -name '*.sh' -print 2>/dev/null
  } | sed 's|^\./||' | sort -u
)

# Exclude this guard script itself from the scan
self=$(basename "${BASH_SOURCE[0]}")
files=("${files[@]/$self}")

if [ "${#files[@]}" -eq 0 ]; then
  echo "no-boot-guard: no workflows or ci/*.sh found -- nothing to scan (SKIP)"
  exit 77
fi

# Patterns that mean "this step runs the emulated kernel / container stack".
patterns=(
  'uml4termux[[:space:]]+(run|boot|start|up|docker)\b'
  'bin/uml4termux[[:space:]]+(run|boot|start|up)\b'
  'linux-[0-9.]+[[:space:]]+ubda='
  'ubda=.*rootfstype='
  'gvproxy[[:space:]]+-listen'
)

hits=0
for f in "${files[@]}"; do
  # Skip comments; keep everything else.
  filtered=$(grep -nvE '^[[:space:]]*(#|$)' "$f" || true)
  [ -n "$filtered" ] || continue
  for p in "${patterns[@]}"; do
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      echo "no-boot-guard: VIOLATION in $f:$line"
      hits=$((hits + 1))
    done < <(printf '%s\n' "$filtered" | grep -E -- "$p" || true)
  done
done

if [ "$hits" -gt 0 ]; then
  cat >&2 <<'EOF'

no-boot-guard: CI must not boot UML.
GitHub-hosted runners cannot execute the arm64 UML port: it requires an
Android/Termux device (SUBARCH=arm64 downstream port, no root, no KVM).
Booting is verified on-device and reported through .github/workflows/device-evidence.yml.
Remove the offending step, or move it into a device-side script that CI never runs.
EOF
  exit 1
fi

echo "no-boot-guard: OK -- no workflow boots UML ($(printf '%s' "${#files[@]}") files scanned)"
exit 0
