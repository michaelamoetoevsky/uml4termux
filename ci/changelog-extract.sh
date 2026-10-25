#!/usr/bin/env bash
# ci/changelog-extract.sh -- print the CHANGELOG.md section for one version.
#
# Usage:
#   ci/changelog-extract.sh 0.1.0 [CHANGELOG.md]
#   ci/changelog-extract.sh v0.1.0            # a 'v' prefix is stripped
#
# Prints the body of the matching "## [<version>]" (or "## <version>") section,
# without the heading itself, up to (not including) the next "## " heading.
#
# Exit 0 with output on success, exit 1 with a readable message on stderr when
# the version has no (or an empty) section -- so release.yml fails with a reason
# instead of publishing empty release notes.
#
# Keep-a-Changelog headings look like:  ## [0.1.0] - 2026-10-26
set -uo pipefail

if [ "$#" -lt 1 ]; then
  echo "usage: $0 <version> [CHANGELOG.md]" >&2
  exit 2
fi

# Allow --help/-h to show usage and exit 0
case "${1:-}" in
  -h|--help)
    sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
esac

version=${1#v}
changelog=${2:-}

if [ -z "$changelog" ]; then
  root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
  changelog="$root/CHANGELOG.md"
fi
case "$changelog" in
  /*) ;;
  *) changelog="$PWD/$changelog" ;;
esac

if [ ! -f "$changelog" ]; then
  echo "changelog-extract: no such file: $changelog" >&2
  exit 1
fi

if [ -z "$version" ]; then
  echo "changelog-extract: empty version argument" >&2
  exit 2
fi

# The heading is "## [0.1.0] - 2026-10-26" or "## 0.1.0 - ...". The version is
# matched literally below (no regex), so no escaping is needed and awk cannot
# warn about escape sequences.
#
# First, a cheap existence check so a missing version fails with a readable
# message before any extraction happens.
if ! awk -v ver="$version" '
  function heading_version(line,   s) {
    s = line
    sub(/^#+[[:space:]]+/, "", s)
    if (substr(s, 1, 1) == "[") {
      sub(/^\[/, "", s)
      sub(/\].*$/, "", s)
    } else {
      sub(/[[:space:]].*$/, "", s)
    }
    return s
  }
  /^##[[:space:]]/ && heading_version($0) == ver { found = 1; exit }
  END { if (!found) exit 1 }
' "$changelog"; then
  {
    echo "changelog-extract: CHANGELOG.md has no section for version '$version'."
    echo "Sections found:"
    grep -E '^##[[:space:]]' "$changelog" | sed 's/^/  /'
  } >&2
  exit 1
fi

# The heading is "## [0.1.0] - 2026-10-26" or "## 0.1.0 - ...". We match the
# version literally (no regex), so no escaping is needed and awk cannot warn
# about escape sequences.
raw=$(
  awk -v ver="$version" '
    function heading_version(line,   s) {
      s = line
      sub(/^#+[[:space:]]+/, "", s)          # drop "## "
      if (substr(s, 1, 1) == "[") {
        sub(/^\[/, "", s)
        sub(/\].*$/, "", s)                  # drop "] ..." including the date
      } else {
        sub(/[[:space:]].*$/, "", s)         # "0.1.0 - 2026-10-26" -> "0.1.0"
      }
      return s
    }
    /^##[[:space:]]/ {
      if (in_section) { exit }
      if (heading_version($0) == ver) { in_section = 1; found = 1 }
      next
    }
    in_section { print }
    END { if (!found) exit 3 }
  ' "$changelog"
)
rc=$?

if [ "$rc" -eq 3 ] || [ -z "$raw" ]; then
  {
    echo "changelog-extract: CHANGELOG.md has no section for version '$version'."
    echo "Sections found:"
    grep -E '^##[[:space:]]' "$changelog" | sed 's/^/  /'
  } >&2
  exit 1
fi

# Trim leading and trailing blank lines.
body=$(printf '%s\n' "$raw" | sed -e '/./,$!d' | sed -e ':a' -e '/^\n*$/{$d;N;ba' -e '}')

if [ -z "$(printf '%s' "$body" | tr -d '[:space:]')" ]; then
  echo "changelog-extract: section for '$version' exists but is empty" >&2
  exit 1
fi

printf '%s\n' "$body"
exit 0
