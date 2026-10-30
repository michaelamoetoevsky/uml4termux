#!/bin/sh
# ---------------------------------------------------------------------------
# Launcher commands (direction G2): up / down / status / logs / ls.
#
# These drive the daemon directly -- no `sv`, no runsvdir, no termux-services.
# The same commands therefore work under runit, under systemd, under s6, or
# from a bare shell, which is the actual prize of direction G: portability, not
# "independence from runit" for its own sake.
#
# `up --foreground` is the adapter hook: a supervisor only has to exec it and
# restart it when it exits.
#
# SPDX-License-Identifier: GPL-2.0-only
# ---------------------------------------------------------------------------

uml4termux_instance_name() { printf '%s' "${UML4TERMUX_INSTANCE_NAME:-default}"; }

# Contract §5: ready = socket exists AND protocol answers AND phase is running.
# Polled, never a fixed sleep. Returns 1 as soon as the daemon gives up, so a
# doomed start fails fast instead of burning the whole timeout.
uml4termux_wait_ready() { # <runtime> <daemon-bin> <timeout-seconds>
  local rt="$1" bin="$2" timeout="${3:-60}" i=0 phase
  while [ "${i}" -lt "${timeout}" ]; do
    phase="$(uml4termux_state_phase "${rt}")"
    case "${phase}" in failed|completed|exited|stopped) return 1 ;; esac
    if [ "${phase}" = "running" ] && uml4termux_socket_answers "${rt}" "${bin}"; then
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  return 1
}

uml4termux_require_instance_dirs() {
  uml4termux_dirs_init >/dev/null 2>&1 || true
  uml4termux_runtime_init >/dev/null 2>&1 || true
}

cmd_up() {
  local name fg=0 no_gvproxy=0 selftest=0 mem="" cpus="" image="" ssh_port="" timeout="" rt="" from=""
  name="$(uml4termux_instance_name)"
  while [ $# -gt 0 ]; do
    case "$1" in
      --name)        name="${2:?--name needs a value}"; shift ;;
      --foreground|-f) fg=1 ;;
      --mem)         mem="${2:?--mem needs a value}"; shift ;;
      --cpus)        cpus="${2:?--cpus needs a value}"; shift ;;
      --image)       image="${2:?--image needs a value}"; shift ;;
      --from)        from="${2:?--from needs a snapshot label}"; shift ;;
      --runtime)     rt="${2:?--runtime needs a value}"; shift ;;
      --ssh-port)    ssh_port="${2:?--ssh-port needs a value}"; shift ;;
      --timeout)     timeout="${2:?--timeout needs a value}"; shift ;;
      --no-gvproxy)  no_gvproxy=1 ;;
      --selftest)    selftest=1 ;;
      -h|--help)     usage_up; return 0 ;;
      *)             die "up: unknown option '$1' (try 'uml4termux help up')" ;;
    esac
    shift
  done
  uml4termux_require_instance_dirs
  [ -n "${timeout}" ] || timeout="${UML4TERMUX_BOOT_TIMEOUT:-90}"

  local dbin
  dbin="$(uml4termux_daemon_bin)" || die "daemon binary not found (run 'uml4termux fetch' first, or set UML4TERMUXD_BIN)"

  if uml4termux_reg_live "${name}"; then
    # A resume REPLACES the disk state, so it cannot be silently skipped: `up`
    # would otherwise report success while the running guest -- the one whose
    # state the caller wanted replaced -- keeps running.
    if [ -n "${from}" ]; then
      die "instance '${name}' is live, and a resume replaces its disk state. Stop it first: uml4termux down --name ${name} (then: uml4termux up --from ${from} --name ${name})"
    fi
    warn "instance '${name}' is already up"
    cmd_status --name "${name}"
    return 0
  fi

  if [ "${selftest}" = "1" ]; then
    : # test hook: no guest boot, so no assets are needed
  else
    uml4termux_require_assets kernel stub
    [ "${no_gvproxy}" = "1" ] || uml4termux_require_assets gvproxy
  fi

  [ -n "${image}" ] || image="$(uml4termux_asset_path disk)"
  [ -n "${mem}" ] || mem="${UML4TERMUX_MEM}"
  [ -n "${cpus}" ] || cpus="${UML4TERMUX_CPUS}"
  case "${mem}" in *[!0-9]*) mem="${mem%[Mm]}" ;; esac
  case "${cpus}" in *[!0-9]*) cpus="${cpus%[Mm]}" ;; esac

  [ -n "${rt}" ] || rt="${UML4TERMUX_RUNTIME}"
  uml4termux_check_runtime_path "${rt}" || return 64

  # C2/C4: a resume is checked against the snapshot record before a single byte
  # is staged -- a mismatch must name its numbers, not surface as a kernel
  # refusal after a 30 s boot.
  if [ -n "${from}" ]; then
    uml4termux_snap_verify "${rt}" "${from}" "${image}" || return 1
  fi

  # G4: bound the logs BEFORE starting, so an instance never inherits an
  # unbounded daemon.log / console log from a previous run. Copy+truncate keeps
  # any writer on the same inode.
  uml4termux_log_rotate_runtime "${rt}" >/dev/null 2>&1 || true

  local holder
  # --- invariant 3: one runtime directory per instance ---
  if holder="$(uml4termux_reg_live_runtime "${rt}")" && [ "${holder}" != "${name}" ]; then
    die "runtime ${rt} is owned by live instance '${holder}'; pass --runtime with a directory of its own"
  fi
  # --- invariant 1: one guest per backing image (F_SETLK) ---
  if holder="$(uml4termux_reg_live_image "${image}")"; then
    die "image ${image} is used by live instance '${holder}': UML holds an exclusive lock, a second guest would boot WITHOUT a disk. Copy the image per instance (see docs/RUNTIME-CONTRACT.md §6)."
  fi
  # --- invariant 2: one gvproxy per host ssh port ---
  if [ -z "${ssh_port}" ] && [ "${no_gvproxy}" != "1" ]; then
    ssh_port="$(uml4termux_reg_pick_ssh_port)" \
      || die "no free gvproxy ssh port (2222 and 12222-12229 are taken by live instances)"
  fi
  if [ -n "${ssh_port}" ] && holder="$(uml4termux_reg_live_ssh_port "${ssh_port}")"; then
    die "host ssh port ${ssh_port} is held by live instance '${holder}'; pass --ssh-port with a free port"
  fi

  # Only now, with all three invariants satisfied, is adopting an unregistered
  # live daemon safe: it cannot belong to another live instance (checked above).
  if uml4termux_socket_answers "${rt}" "${dbin}"; then
    if [ -n "${from}" ]; then
      die "a daemon is already serving ${rt}, and adopting it would not resume anything. Stop it first: uml4termux down --name ${name} (then: uml4termux up --from ${from})"
    fi
    warn "a daemon is already serving ${rt}; adopting it as instance '${name}'"
    uml4termux_reg_write "${name}" "${rt}" "${image}" "${ssh_port:-}" "$(uml4termux_read_pid uml4termuxd)"
    cmd_status --name "${name}"
    return 0
  fi

  local -a env
  env=(
    "UML4TERMUX_RUNTIME=${rt}"
    "UML4TERMUXD_KERNEL=$(uml4termux_asset_path kernel)"
    "UML4TERMUXD_STUB=$(uml4termux_asset_path stub)"
    "UML4TERMUXD_IMAGE=${image}"
    "UML4TERMUXD_INITRAMFS=${UML4TERMUX_INITRAMFS_DIR}/docker.cpio.gz"
    "UML4TERMUXD_COW=${rt}/${name}.cow"
    "UML4TERMUXD_MEM=${mem}M"
    "UML4TERMUXD_NCPUS=${cpus}"
    "UML4TERMUXD_BESS=${rt}/bess.sock"
    "UML4TERMUXD_STRICT_UBD=1"
  )
  [ "${no_gvproxy}" = "1" ] || env+=("UML4TERMUXD_GVPROXY=$(uml4termux_asset_path gvproxy)")
  [ -z "${ssh_port}" ] || env+=("UML4TERMUXD_GVPROXY_SSH_PORT=${ssh_port}")
  [ -r "${UML4TERMUXD_INITRAMFS:-}" ] || true

  local -a cmd=(env "${env[@]}" "${dbin}" daemon)
  [ "${selftest}" = "1" ] && cmd+=("--selftest")

  if uml4termux_is_dry_run; then
    uml4termux_print_cmd "${cmd[@]}"
    [ "${fg}" = "1" ] || printf '+ (registry write %s, then wait for readiness)\n' "${name}"
    return 0
  fi

  # The fresh/resume decision lives here and nowhere else. The daemon writes a
  # COW header only when the file is missing or invalid, so whatever this branch
  # leaves on disk is the state the guest boots from: a fresh header for a fresh
  # boot, the snapshot copy for a resume. Copy-on-resume keeps the snapshot
  # itself immutable, which is what lets the same label be resumed twice.
  local cow="${rt}/${name}.cow"
  if [ -n "${from}" ]; then
    uml4termux_snap_swap_in "${rt}" "${from}" "${cow}" || return 1
  else
    rm -f "${cow}"
  fi

  if [ "${fg}" = "1" ]; then
    # Register BEFORE exec: under exec the shell IS the daemon afterwards (same
    # pid), so $$ is the daemon's pid -- and without this record `status`, `ls`
    # and `down` could not find an instance started by a supervisor adapter.
    uml4termux_reg_write "${name}" "${rt}" "${image}" "${ssh_port:-}" "$$"
    info "instance '${name}': running the daemon in the foreground (adapter hook)"
    exec "${cmd[@]}"
  fi

  rm -f "${rt}/daemon.sock.state" "${rt}/daemon.sock" "${rt}/daemon.log"

  uml4termux_spawn uml4termuxd "${rt}/daemon.log" "${cmd[@]}"
  local pid
  pid="$(uml4termux_read_pid uml4termuxd)"
  [ -n "${pid}" ] || die "the daemon did not stay up (see ${rt}/daemon.log)"
  uml4termux_reg_write "${name}" "${rt}" "${image}" "${ssh_port:-}" "${pid}"

  if uml4termux_wait_ready "${rt}" "${dbin}" "${timeout}"; then
    info "instance '${name}' is up (pid ${pid}, runtime ${rt})"
    cmd_status --name "${name}"
    return 0
  fi

  err "instance '${name}' did not become ready within ${timeout}s"
  sed -n '1,20p' "${rt}/daemon.log" 2>/dev/null | sed 's/^/  /'
  cmd_down --name "${name}" >/dev/null 2>&1 || true
  return 1
}

cmd_down() {
  local name timeout="${UML4TERMUX_STOP_TIMEOUT:-30}"
  name="$(uml4termux_instance_name)"
  while [ $# -gt 0 ]; do
    case "$1" in
      --name)    name="${2:?--name needs a value}"; shift ;;
      --timeout) timeout="${2:?--timeout needs a value}"; shift ;;
      -h|--help) usage_down; return 0 ;;
      *)         die "down: unknown option '$1'" ;;
    esac
    shift
  done
  uml4termux_require_instance_dirs

  local rt pid dbin
  rt="$(uml4termux_reg_get "${name}" RUNTIME)" || rt="${UML4TERMUX_RUNTIME}"
  pid="$(uml4termux_reg_get "${name}" PID)" || pid="$(uml4termux_read_pid uml4termuxd)"
  dbin="$(uml4termux_daemon_bin)" || dbin=""

  if ! uml4termux_reg_live "${name}"; then
    uml4termux_is_dry_run || rm -f "$(uml4termux_reg_path "${name}")"
    info "instance '${name}' is not running"
    return 0
  fi

  if uml4termux_is_dry_run; then
    printf '+ UML4TERMUX_RUNTIME=%s %s stop\n' "${rt}" "${dbin}"
    printf '+ (wait up to %ss for the socket to disappear)\n' "${timeout}"
    return 0
  fi

  UML4TERMUX_RUNTIME="${rt}" "${dbin}" stop >/dev/null 2>&1 || true

  local i=0
  while [ "${i}" -lt "${timeout}" ]; do
    if ! uml4termux_pid_alive "${pid}" uml4termux || [ ! -S "${rt}/daemon.sock" ]; then
      rm -f "$(uml4termux_reg_path "${name}")"
      info "instance '${name}' is down"
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done

  err "instance '${name}' did not stop within ${timeout}s (pid ${pid}); it is still running"
  return 1
}

cmd_status() {
  local name json=0
  name="$(uml4termux_instance_name)"
  while [ $# -gt 0 ]; do
    case "$1" in
      --name) name="${2:?--name needs a value}"; shift ;;
      --json) json=1 ;;
      -h|--help) usage_status; return 0 ;;
      *) die "status: unknown option '$1'" ;;
    esac
    shift
  done
  uml4termux_require_instance_dirs

  local rt pid image ssh_port phase live="no"
  rt="$(uml4termux_reg_get "${name}" RUNTIME 2>/dev/null)" || rt="${UML4TERMUX_RUNTIME}"
  pid="$(uml4termux_reg_get "${name}" PID 2>/dev/null)" || pid="$(uml4termux_read_pid uml4termuxd)"
  image="$(uml4termux_reg_get "${name}" IMAGE 2>/dev/null)" || image=""
  ssh_port="$(uml4termux_reg_get "${name}" SSH_PORT 2>/dev/null)" || ssh_port=""
  phase="$(uml4termux_state_phase "${rt}")"
  uml4termux_reg_live "${name}" && live="yes"

  if [ "${json}" = "1" ]; then
    printf '{"name":"%s","live":"%s","phase":"%s","pid":"%s","runtime":"%s","image":"%s","ssh_port":"%s"}\n' \
      "${name}" "${live}" "${phase:-none}" "${pid}" "${rt}" "${image}" "${ssh_port}"
    return 0
  fi

  printf 'instance  : %s\n' "${name}"
  printf 'state     : %s%s\n' "${live}" "$([ "${live}" = "yes" ] && printf ' (phase %s)' "${phase:-unknown}" || printf '')"
  printf 'pid       : %s%s\n' "${pid:-none}" "$([ -n "${pid}" ] && uml4termux_pid_alive "${pid}" uml4termux && printf ' (alive)' || true)"
  printf 'runtime   : %s\n' "${rt}"
  printf 'image     : %s\n' "${image:-none}"
  printf 'ssh port  : %s\n' "${ssh_port:-none}"
  printf 'logs      : %s\n' "$(uml4termux_human_size "$(uml4termux_log_total "${rt}")")"
  [ "${live}" = "yes" ] || return 1
  return 0
}

cmd_logs() {
  local name lines=30 follow=0 which="daemon"
  name="$(uml4termux_instance_name)"
  while [ $# -gt 0 ]; do
    case "$1" in
      --name)    name="${2:?--name needs a value}"; shift ;;
      -l)        lines="${2:?-l needs a value}"; shift ;;
      --lines)   lines="${2:?--lines needs a value}"; shift ;;
      -f|--follow) follow=1 ;;
      --console) which="console" ;;
      --daemon)  which="daemon" ;;
      -h|--help) usage_logs; return 0 ;;
      *) die "logs: unknown option '$1'" ;;
    esac
    shift
  done
  uml4termux_require_instance_dirs

  local rt file
  rt="$(uml4termux_reg_get "${name}" RUNTIME 2>/dev/null)" || rt="${UML4TERMUX_RUNTIME}"
  if [ "${which}" = "console" ]; then
    file="${rt}/uml-console.log"
  else
    file="${rt}/daemon.log"
  fi
  if [ -z "$(uml4termux_reg_get "${name}" RUNTIME 2>/dev/null)" ] && [ ! -r "${file}" ]; then
    err "instance '${name}' is not registered (see 'uml4termux ls')"
    return 1
  fi
  [ -r "${file}" ] || { err "no ${which} log at ${file}"; return 1; }
  if [ "${follow}" = "1" ]; then
    tail -n "${lines}" -f "${file}"
  else
    tail -n "${lines}" "${file}"
  fi
}

cmd_ls() {
  local json=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) json=1 ;;
      -h|--help) usage_ls; return 0 ;;
      *) die "ls: unknown option '$1'" ;;
    esac
    shift
  done
  uml4termux_require_instance_dirs
  local pruned=0
  pruned="$(uml4termux_reg_prune)"

  if [ "${json}" = "1" ]; then
    local name first=1
    printf '{"instances":['
    for name in $(uml4termux_reg_names); do
      [ "${first}" = "1" ] || printf ','
      first=0
      cmd_status --name "${name}" --json | tr -d '\n'
    done
    printf '],"pruned":%s}\n' "${pruned}"
    return 0
  fi

  local name any=0
  printf '%-12s %-5s %-9s %-9s %s\n' "NAME" "LIVE" "PHASE" "SSH-PORT" "RUNTIME"
  for name in $(uml4termux_reg_names); do
    any=1
    local rt phase ssh_port live="no"
    rt="$(uml4termux_reg_get "${name}" RUNTIME 2>/dev/null)"
    ssh_port="$(uml4termux_reg_get "${name}" SSH_PORT 2>/dev/null)"
    phase="$(uml4termux_state_phase "${rt}")"
    uml4termux_reg_live "${name}" && live="yes"
    printf '%-12s %-5s %-9s %-9s %s\n' "${name}" "${live}" "${phase:-none}" "${ssh_port:-none}" "${rt}"
  done
  [ "${any}" = "1" ] || info "no instances registered (start one with 'uml4termux up')"
  [ "${pruned}" = "0" ] || info "pruned ${pruned} stale record(s)"
}

# --- log rotation (arah G4) ------------------------------------------------
usage_rotate() {
  cat <<'EOF'
uml4termux rotate — rotate an instance's logs without an external log daemon.

usage: uml4termux rotate [--name NAME] [--runtime DIR] [--max-bytes B] [--keep K]
                         [--all]

  --max-bytes B   rotate a file once it exceeds B bytes (default 10 MiB, or
                  $UML4TERMUX_LOG_MAX_BYTES)
  --keep K        generations kept as <file>.1 .. <file>.K (default 3, or
                  $UML4TERMUX_LOG_KEEP)
  --all           rotate every registered instance

Files: daemon.log, uml-console.log, bess.sock.gv.log. Rotation uses
copy+truncate, so a process holding the log open keeps writing to the same
inode -- a rename would silently divert it into the rotated generation.

`up` already rotates before each start; call this from a supervisor tick (or a
cron job) for continuous rotation -- that is the whole rotation role, done by
this CLI instead of a log daemon.
EOF
}

cmd_rotate() {
  local name all=0 max="${UML4TERMUX_LOG_MAX_BYTES}" keep="${UML4TERMUX_LOG_KEEP}" rt=""
  name="$(uml4termux_instance_name)"
  while [ $# -gt 0 ]; do
    case "$1" in
      --name)      name="${2:?--name needs a value}"; shift ;;
      --runtime)   rt="${2:?--runtime needs a value}"; shift ;;
      --max-bytes) max="${2:?--max-bytes needs a value}"; shift ;;
      --keep)      keep="${2:?--keep needs a value}"; shift ;;
      --all)       all=1 ;;
      -h|--help)   usage_rotate; return 0 ;;
      *) die "rotate: unknown option '$1' (try 'uml4termux help rotate')" ;;
    esac
    shift
  done
  uml4termux_require_instance_dirs

  local rc=0 out
  if [ "${all}" = "1" ]; then
    local n
    if [ -z "$(uml4termux_reg_names)" ]; then info "no instances registered"; return 0; fi
    for n in $(uml4termux_reg_names); do
      info "instance ${n}"
      uml4termux_log_rotate_runtime "$(uml4termux_reg_get "${n}" RUNTIME)" "${max}" "${keep}" | sed 's/^/  /'
    done
    return 0
  fi

  [ -n "${rt}" ] || rt="$(uml4termux_reg_get "${name}" RUNTIME 2>/dev/null)" || rt="${UML4TERMUX_RUNTIME}"
  if [ ! -d "${rt}" ]; then err "no runtime directory at ${rt}"; return 1; fi
  out="$(uml4termux_log_rotate_runtime "${rt}" "${max}" "${keep}")"
  if [ -z "${out}" ]; then info "no logs in ${rt}"; return 0; fi
  printf '%s\n' "${out}" | while read -r file before action; do
    printf '%-46s %10s byte  %s\n' "${file#"${rt}"/}" "${before}" "${action}"
  done
  return "${rc}"
}
