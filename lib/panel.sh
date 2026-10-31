# lib/panel.sh — the local status page (direction D3).
#
# What it does: starts panel/serve.py, a read-only page on loopback that shows the
# guests this host knows about, their state as the daemon reports it, and their
# exposures — and hands you the exact command to start or stop one instead of
# performing the mutation itself. The daemon's HTTP endpoint is unauthenticated
# (docs/THREAT-MODEL.md), so a control endpoint would trade a documented limit for
# an undocumented hole.
#
# SPDX-License-Identifier: GPL-2.0-only

usage_panel() {
  cat <<'EOF'
uml4termux panel [--port N] [--host ADDR]

  Local, read-only status page: guests, their state (as the daemon reports it via
  protocol v1), exposures, and the command to start or stop each one.

  --port N      port to listen on            (default 8788)
  --host ADDR   address to bind              (default 127.0.0.1)
                A non-loopback address is refused: the page is unauthenticated.

  The page never mutates anything. Ctrl-C stops it.
EOF
}

cmd_panel() {
  local port="" host=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --port)   port="${2:?--port needs a value}"; shift ;;
      --host)   host="${2:?--host needs a value}"; shift ;;
      -h|--help) usage_panel; return 0 ;;
      *) die "panel: unknown option '$1' (try 'uml4termux panel --help')" ;;
    esac
    shift
  done

  local serve="${UML4TERMUX_ROOT}/panel/serve.py"
  [ -r "${serve}" ] || die "panel: ${serve} not found (reinstall, or run from the repository)"
  uml4termux_python_ok || die "panel: python3 is required (uml4termux Python is not usable here)"

  local -a extra=()
  [ -z "${port}" ] || extra+=(--port "${port}")
  [ -z "${host}" ] || extra+=(--host "${host}")

  if uml4termux_is_dry_run; then
    # uml4termux_python is a shell function, not a program on PATH: quoting it as a
    # command would print something that cannot be pasted.
    printf '+ %s\n' "$(uml4termux_quote uml4termux_python "${serve}" ${extra[@]+"${extra[@]}"})"
    return 0
  fi

  info "panel: read-only status page; Ctrl-C to stop"
  uml4termux_python "${serve}" ${extra[@]+"${extra[@]}"}
}
