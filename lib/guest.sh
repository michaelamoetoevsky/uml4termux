# shellcheck shell=bash
#
# uml4termux — lib/guest.sh
# Guest initramfs generation and UML boot.
#
# The initramfs is built at runtime by scripts/build-initramfs.py from
# scripts/guest/* ; a prebuilt archive is only a fallback.
#
# SPDX-License-Identifier: GPL-2.0-only

# scripts/build-initramfs.py and scripts/guest/ live next to bin/uml4termux
uml4termux_root()  { printf '%s' "${UML4TERMUX_ROOT:?UML4TERMUX_ROOT is not set}"; }
guest_script_dir() { printf '%s/scripts/guest' "$(uml4termux_root)"; }
guest_builder()    { printf '%s/scripts/build-initramfs.py' "$(uml4termux_root)"; }

# Prebuilt archives we may fall back to (first existing wins).
guest_fallback_initramfs() {
  local c
  for c in "${UML4TERMUX_PREBUILT_INITRAMFS:-}" \
           "${UML4TERMUX_HOME}/initramfs-switch8.cpio.gz" \
           "${HOME}/workspace/uml-forensics/bin/initramfs-switch8.cpio.gz"; do
    if [ -n "${c}" ] && [ -f "${c}" ]; then printf '%s' "${c}"; return 0; fi
  done
  return 1
}

# Ports the guest containers must publish = the guest side of UML4TERMUX_PORTS.
guest_web_ports() {
  local spec parsed g out=""
  for spec in ${UML4TERMUX_PORTS}; do
    parsed="$(net_parse_mapping "${spec}")"
    g="${parsed##* }"
    out+="${g} "
  done
  printf '%s' "${out% }"
}

# guest_build_initramfs <docker|gate>
# Sets GUEST_INITRAMFS (never writes data to stdout: stdout is reserved for the
# --dry-run command listing).
GUEST_INITRAMFS=""
guest_build_initramfs() {
  local mode="$1" out entry base
  out="${UML4TERMUX_INITRAMFS_DIR}/initramfs-${mode}.cpio.gz"
  GUEST_INITRAMFS="${out}"
  case "${mode}" in
    docker) entry="/docker-init.sh" ;;
    gate)   entry="/forensic.sh" ;;
    *)      die "unknown initramfs mode: ${mode}" ;;
  esac
  base="$(uml4termux_asset_path base-initramfs)"
  [ -f "${base}" ] || base=""

  step "building initramfs (${mode}) -> ${out}"
  uml4termux_dirs_init
  uml4termux_is_dry_run || rm -f "${out}"

  if ! uml4termux_python_ok && ! uml4termux_is_dry_run; then
    warn "python3 unavailable: falling back to a prebuilt initramfs"
    guest_use_fallback
    return 0
  fi

  local args=("$(guest_builder)" --guest-dir "$(guest_script_dir)" --out "${out}"
              --mode "${mode}" --entry "${entry}" --force
              --define "GUEST_ENTRY=${entry}"
              --define "GUEST_MODE=${mode}"
              --define "GUEST_IP=${UML4TERMUX_GUEST_IP}"
              --define "GUEST_GW=${UML4TERMUX_GUEST_GW}"
              --define "GUEST_DNS=${UML4TERMUX_DNS}"
              --define "WEB_PORTS=$(guest_web_ports)"
              --define "GUEST_LIFETIME=${UML4TERMUX_GUEST_LIFETIME}")
  if [ -n "${base}" ]; then
    args+=(--base "${base}")
  else
    warn "base initramfs asset missing: the guest would have no busybox"
  fi

  if uml4termux_is_dry_run; then
    uml4termux_python "${args[@]}"
    return 0
  fi
  if ! uml4termux_python "${args[@]}" || [ ! -s "${out}" ]; then
    warn "initramfs generator did not produce ${out}: trying the prebuilt fallback"
    guest_use_fallback
    return 0
  fi
  ok "initramfs ready: ${out} ($(uml4termux_human_size "$(uml4termux_sizeof "${out}")"))"
  return 0
}

guest_use_fallback() {
  local fb
  if fb="$(guest_fallback_initramfs)"; then
    warn "using prebuilt initramfs fallback: ${fb}"
    uml4termux_run cp -f "${fb}" "${GUEST_INITRAMFS}"
    if uml4termux_is_dry_run; then
      info "the fallback archive ships the reference forensic script, not ${GUEST_INITRAMFS##*/}"
    fi
    return 0
  fi
  die "cannot build the guest initramfs and no prebuilt fallback was found"
}

# ---------------------------------------------------------------------------
# boot
# ---------------------------------------------------------------------------
# UML registers console fds with epoll; a non-pollable stdin (pipe, regular
# file) fails epoll_ctl with EPERM and the console silently stops.  Interactive
# mode needs a real tty on both ends, everything else uses stdout only.
guest_console_args() {
  if [ "${1:-0}" = "1" ]; then
    printf 'con=null con0=fd:0,fd:1'
  else
    printf 'con=null con0=null,fd:1'
  fi
}

# guest_cmdline_build <mode> <initrd> [interactive] : sets CMDLINE[]
CMDLINE=()
guest_cmdline_build() {
  local mode="$1" initrd="$2" interactive="${3:-0}"
  local stub disk
  stub="$(uml4termux_asset_path stub)"
  disk="$(uml4termux_asset_path disk)"

  CMDLINE=()
  CMDLINE+=("mem=${UML4TERMUX_MEM}M")
  CMDLINE+=("ncpus=${UML4TERMUX_CPUS}")
  CMDLINE+=("${UML4TERMUX_SMP}")
  if [ "${mode}" = "docker" ]; then
    CMDLINE+=("ubd0=${disk}" root=/dev/ubda rw)
  fi
  CMDLINE+=("initrd=${initrd}")
  CMDLINE+=("stub_exe=${stub}")
  CMDLINE+=("panic=-1")
  CMDLINE+=("umid=${UML4TERMUX_UMID}")
  CMDLINE+=(console=tty0)
  # Split the console spec ("con=... [conN=...]") into words without SC2207:
  # `read -a` is the shellcheck-clean way to word-split command output.
  local console_spec console_args=()
  console_spec="$(guest_console_args "${interactive}")"
  read -r -a console_args <<< "${console_spec}"
  CMDLINE+=("${console_args[@]}")
  CMDLINE+=("vec0:transport=bess,dst=${UML4TERMUX_BESS_SOCK},depth=128,gro=1,mac=${UML4TERMUX_GUEST_MAC}")
}

# guest_boot <mode> [interactive]
guest_boot() {
  local mode="$1" interactive="${2:-0}" log kernel
  uml4termux_require_assets kernel stub
  if [ "${mode}" = "docker" ]; then
    uml4termux_require_assets disk
  fi

  guest_build_initramfs "${mode}"
  log="${UML4TERMUX_LOG_DIR}/uml-${mode}-$(uml4termux_ts).log"
  UML4TERMUX_UML_LOG="${log}"
  export UML4TERMUX_UML_LOG
  kernel="$(uml4termux_asset_path kernel)"

  guest_cmdline_build "${mode}" "${GUEST_INITRAMFS}" "${interactive}"

  step "booting UML (${UML4TERMUX_MEM}M, ${UML4TERMUX_CPUS} cpus, ${UML4TERMUX_SMP}, mode=${mode})"
  uml4termux_runtime_init
  if ! uml4termux_is_dry_run; then
    mkdir -p "$(dirname "${log}")"
    : > "${log}"
  fi
  info "kernel:  ${kernel}"
  info "cmdline: $(uml4termux_quote "${CMDLINE[@]}")"
  info "log:     ${log}"

  local argv=(timeout "${UML4TERMUX_BOOT_TIMEOUT}" "${kernel}" "${CMDLINE[@]}")
  uml4termux_spawn uml "${log}" "${argv[@]}"
  if uml4termux_is_dry_run; then
    uml4termux_instance_write
    return 0
  fi

  # UML re-execs stub_exe very early: if the kernel cannot start at all, report
  # it now instead of waiting for a marker that will never arrive.
  local i pid
  for i in 1 2 3 4 5; do
    sleep 1
    pid="$(uml4termux_read_pid uml)"
    if ! uml4termux_pid_alive "${pid}"; then
      err "the UML kernel exited within ${i}s of start"
      uml4termux_tail "${log}" 25
      return 1
    fi
    if grep -aq 'Userspace mode:' "${log}" 2>/dev/null; then break; fi
  done
  uml4termux_instance_write
  return 0
}

# guest_wait_marker <marker> <timeout_seconds> <log>
guest_wait_marker() {
  local marker="$1" timeout="$2" log="$3" waited=0 pid
  if uml4termux_is_dry_run; then
    printf '+ (wait up to %ss for %s in %s)\n' "${timeout}" "${marker}" "${log}"
    return 0
  fi
  while [ "${waited}" -lt "${timeout}" ]; do
    if grep -qa -- "${marker}" "${log}" 2>/dev/null; then
      ok "guest marker '${marker}' reached after ${waited}s"
      return 0
    fi
    pid="$(uml4termux_read_pid uml)"
    if ! uml4termux_pid_alive "${pid}"; then
      err "the UML kernel exited before '${marker}' appeared"
      uml4termux_tail "${log}" 25
      return 1
    fi
    if [ "${waited}" -gt 0 ] && [ $((waited % 30)) -eq 0 ]; then
      info "still waiting for '${marker}' (${waited}s)"
    fi
    sleep 2
    waited=$((waited + 2))
  done
  err "timed out after ${timeout}s waiting for '${marker}'"
  uml4termux_tail "${log}" 25
  return 1
}

# guest_wait_exit <timeout_seconds> : wait for the kernel process to leave
guest_wait_exit() {
  local timeout="$1" waited=0 pid
  if uml4termux_is_dry_run; then
    printf '+ (wait up to %ss for the UML process to exit)\n' "${timeout}"
    return 0
  fi
  while [ "${waited}" -lt "${timeout}" ]; do
    pid="$(uml4termux_read_pid uml)"
    uml4termux_pid_alive "${pid}" || return 0
    sleep 2
    waited=$((waited + 2))
  done
  return 1
}

# guest_boot_shell : boot an interactive busybox shell (rdinit=/bin/sh)
# Runs in the foreground; the kernel is the direct child of this process.
guest_boot_shell() {
  local mem="${UML4TERMUX_MEM}" cpus="${UML4TERMUX_CPUS}" timeout="${UML4TERMUX_BOOT_TIMEOUT}"
  local kernel base log
  uml4termux_require_assets kernel stub
  base="$(uml4termux_asset_path base-initramfs)"
  if [ ! -f "${base}" ]; then
    base="$(guest_fallback_initramfs)" || die "no base initramfs for shell mode"
  fi
  log="${UML4TERMUX_LOG_DIR}/uml-shell-$(uml4termux_ts).log"
  UML4TERMUX_UML_LOG="${log}"
  export UML4TERMUX_UML_LOG
  kernel="$(uml4termux_asset_path kernel)"

  guest_cmdline_build "shell" "${base}" 1
  # shell mode: no ubd0, rdinit=/bin/sh
  CMDLINE+=("rdinit=/bin/sh")

  step "booting UML shell (${mem}M, ${cpus} cpus, ${UML4TERMUX_SMP})"
  uml4termux_runtime_init
  if ! uml4termux_is_dry_run; then
    mkdir -p "$(dirname "${log}")"
    : > "${log}"
  fi
  info "kernel:  ${kernel}"
  info "initrd:  ${base}"
  info "cmdline: $(uml4termux_quote "${CMDLINE[@]}")"
  info "log:     ${log}"

  if uml4termux_is_dry_run; then
    uml4termux_run timeout "${timeout}" "${kernel}" "${CMDLINE[@]}"
    uml4termux_instance_write
    return 0
  fi

  # Foreground run: no backgrounding, no pidfile needed for UML itself.
  # gvproxy runs in the background (already started).
  timeout "${timeout}" "${kernel}" "${CMDLINE[@]}" >>"${log}" 2>&1
  return 0
}

# Print the interesting guest evidence lines from a UML log.
guest_report() {
  local log="${1:-}"
  [ -n "${log}" ] && [ -r "${log}" ] || return 0
  grep -aE 'Userspace mode|UML4TERMUX|SWITCH_ROOT|NO_DISK|DHCPACK|ADDR:|ROUTE:|RESOLV:|DNS_TEST:|SERVER=|BUSYBOX_RUN_OK|STATIC_FALLBACK|web \||webh \||GATE_OK' "${log}" \
    | head -20 || true
}
