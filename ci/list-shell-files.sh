#!/usr/bin/env bash
# ci/list-shell-files.sh -- print every shell file CI must lint, one per line,
# repo-relative, sorted, deduplicated.
#
# Selection rules (kept in one place so `ci.yml` and `ci/local-ci.sh` lint
# exactly the same set):
#   * any file ending in .sh
#   * any executable file whose first 200 bytes start with a shell shebang
#     (this catches extensionless entry points such as bin/uml4termux)
#
# Pruned trees: .git, build, dist, .uml, tmp, node_modules, __pycache__, and
# anything holding downloaded binaries.
#
# evidence/logs is pruned on purpose: it holds CAPTURED RUN ARTIFACTS (driver
# scripts and console logs) whose sha256 is recorded inside the evidence
# records. They are data, not source -- editing one to satisfy a linter would
# break the very thing they exist to prove.
#
# Usage: ci/list-shell-files.sh [repo-root]
set -uo pipefail

# Allow --help/-h to show usage and exit 0
case "${1:-}" in
  -h|--help)
    sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
esac

root=${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
cd "$root" || exit 1

find . \
  \( -name .git -o -name build -o -name dist -o -name .uml -o -name tmp \
     -o -name node_modules -o -name __pycache__ -o -name '.venv' \
     -o -path ./evidence/logs \) -prune -o \
  -type f -print 2>/dev/null |
sort |
while IFS= read -r f; do
  case "$f" in
    *.sh)
      printf '%s\n' "${f#./}"
      ;;
    *)
      [ -x "$f" ] || continue
      if head -c 200 -- "$f" 2>/dev/null | grep -qE '^#![[:space:]]*(/usr/bin/env[[:space:]]+)?(bash|sh|dash|ksh)'; then
        printf '%s\n' "${f#./}"
      fi
      ;;
  esac
done
