# shellcheck shell=bash
#
# uml4termux — lib/common.sh
# Shared defaults, logging, dry-run plumbing and process bookkeeping.
#
# SPDX-License-Identifier: GPL-2.0-only
#
# Sourced by bin/uml4termux (bash >= 4.2). Nothing here executes UML.

UML4TERMUX_VERSION="${UML4TERMUX_VERSION:-0.1.0}"
UML4TERMUX_LICENSE="GPL-2.0-only"
UML4TERMUX_NAME="uml4termux"

# ---------------------------------------------------------------------------
# platform / prefix detection
# ---------------------------------------------------------------------------
# Termux has no /usr/bin/env and no /etc/resolv.conf; on such a host $PREFIX is
# already exported. On a plain Linux box we derive a harmless /usr.
if [ -z "${PREFIX:-}" ]; then
  _uml4_bash="$(command -v bash 2>/dev/null || true)"
  _uml4_cand=""
  if [ -n "${_uml4_bash}" ]; then
    _uml4_cand="$(cd "$(dirname "${_uml4_bash}")/.." 2>/dev/null && pwd || true)"
  fi
  case "${_uml4_cand}" in
    */com.termux/files/usr) PREFIX="${_uml4_cand}" ;;
    *)                       PREFIX="/usr" ;;
  esac
  unset _uml4_bash _uml4_cand
fi
export PREFIX
case "${PREFIX}" in *com.termux*) UML4TERMUX_IS_TERMUX=1 ;; *) UML4TERMUX_IS_TERMUX=0 ;; esac

# ---------------------------------------------------------------------------
# directories
# ---------------------------------------------------------------------------
UML4TERMUX_HOME="${UML4TERMUX_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/uml4termux}"
UML4TERMUX_STATE_DIR="${UML4TERMUX_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/uml4termux}"
UML4TERMUX_LOG_DIR="${UML4TERMUX_LOG_DIR:-${UML4TERMUX_STATE_DIR}/logs}"
UML4TERMUX_RUNTIME="${UML4TERMUX_RUNTIME:-${TMPDIR:-/tmp}/uml4termux}"
UML4TERMUX_INITRAMFS_DIR="${UML4TERMUX_INITRAMFS_DIR:-${UML4TERMUX_STATE_DIR}/initramfs}"
export UML4TERMUX_HOME UML4TERMUX_STATE_DIR UML4TERMUX_LOG_DIR UML4TERMUX_RUNTIME
export UML4TERMUX_INITRAMFS_DIR

# ---------------------------------------------------------------------------
# assets: file names, download URLs, pinned digests
# ---------------------------------------------------------------------------
UML4TERMUX_UPSTREAM_BASE_URL="${UML4TERMUX_UPSTREAM_BASE_URL:-https://github.com/zalexdev/linux-um-arm64/releases/download/prebuilt-20260816}"
UML4TERMUX_FORK_BASE_URL="${UML4TERMUX_FORK_BASE_URL:-https://github.com/Raymer8639/linux-um-arm64/releases/download/um-arm64-v0.3.0}"
UML4TERMUX_GVPROXY_BASE_URL="${UML4TERMUX_GVPROXY_BASE_URL:-https://github.com/containers/gvisor-tap-vsock/releases/download/v0.9.0}"
# The project's own release: the CI-built kernel adopted in 0.3.0 (gap-closed
# config: CPUSETS/BLK_CGROUP/THROTTLING/MODULES; stub byte-identical to the
# released one). Until the repo is public, downloads need GITHUB_TOKEN.
UML4TERMUX_RELEASE_BASE_URL="${UML4TERMUX_RELEASE_BASE_URL:-https://github.com/michaelamoetoevsky/uml4termux/releases/download/v0.5.0}"

# The docker-capable kernel of the fork is the one verified on-device:
# `uname -r` == 7.2.0-rc4-opt, OVERLAY_FS/VETH/BRIDGE/PID_NS/MEMCG on.
# Default now = our own 0.3.0 CI kernel (same base + the four gap-closing
# symbols; device-validated in evidence/20261027-ci-kernel-round3.json).
UML4TERMUX_KERNEL_URL="${UML4TERMUX_KERNEL_URL:-${UML4TERMUX_RELEASE_BASE_URL}/linux-bionic}"
UML4TERMUX_STUB_URL="${UML4TERMUX_STUB_URL:-${UML4TERMUX_RELEASE_BASE_URL}/stub_exe}"
UML4TERMUXD_URL="${UML4TERMUXD_URL:-${UML4TERMUX_RELEASE_BASE_URL}/uml4termuxd}"
UML4TERMUX_DISK_URL="${UML4TERMUX_DISK_URL:-${UML4TERMUX_UPSTREAM_BASE_URL}/debian-docker.ext4.gz}"
UML4TERMUX_BASE_INITRAMFS_URL="${UML4TERMUX_BASE_INITRAMFS_URL:-${UML4TERMUX_UPSTREAM_BASE_URL}/initramfs-alpine.cpio.gz}"
UML4TERMUX_GVPROXY_URL="${UML4TERMUX_GVPROXY_URL:-${UML4TERMUX_GVPROXY_BASE_URL}/gvproxy-linux-arm64}"
UML4TERMUX_SHA256SUMS_URL="${UML4TERMUX_SHA256SUMS_URL:-${UML4TERMUX_UPSTREAM_BASE_URL}/SHA256SUMS}"
UML4TERMUX_FORK_SHA256SUMS_URL="${UML4TERMUX_FORK_SHA256SUMS_URL:-${UML4TERMUX_FORK_BASE_URL}/SHA256SUMS}"
UML4TERMUX_GVPROXY_SHA256SUMS_URL="${UML4TERMUX_GVPROXY_SHA256SUMS_URL:-${UML4TERMUX_GVPROXY_BASE_URL}/sha256sums}"

# Pinned digests (all re-measured with sha256sum on this device).
# Kernel = the v0.5.0 CI-built release asset (same pinned source commit as
# 0.3.0; the hash differs only because the kernel embeds its build timestamp).
# Stub = byte-identical across both CI runs (NDK r29 toolchain parity).
# Daemon = the bionic uml4termuxd built in the same CI run.
UML4TERMUX_KERNEL_SHA256="${UML4TERMUX_KERNEL_SHA256:-6970ada592e49c03f90e1b422ffb38ea0ceced9d9d1de1c5120542126a426c02}"
UML4TERMUX_STUB_SHA256="${UML4TERMUX_STUB_SHA256:-731c48d5bf42ef25e26625af6a02627a5d658bf9f67d6f7fc443d6d644d6e52e}"
UML4TERMUXD_SHA256="${UML4TERMUXD_SHA256:-d86f1c4d41f7ac7ce30841137fa291737d18e8b2d2a68a2b7de48f6696e34335}"
UML4TERMUX_DISK_SHA256="${UML4TERMUX_DISK_SHA256:-2807979f76021fadf1f76f0c827fbe1eab4df51e33bfeca0c840c5181c610be3}"
UML4TERMUX_GVPROXY_SHA256="${UML4TERMUX_GVPROXY_SHA256:-c1ea864636182a774235c8866c70f2a0223dfcd4f08d24e37a7e82d9882beb9c}"
UML4TERMUX_BASE_INITRAMFS_SHA256="${UML4TERMUX_BASE_INITRAMFS_SHA256:-15238a37328b99b3206a58c7ab69b853139c40b8ca35f8acacf6226a4c1cf94f}"

UML4TERMUX_KERNEL_FILE="${UML4TERMUX_KERNEL_FILE:-linux-bionic}"
UML4TERMUX_STUB_FILE="stub_exe"
UML4TERMUXD_FILE="${UML4TERMUXD_FILE:-uml4termuxd}"
UML4TERMUX_DISK_GZ_FILE="debian-docker.ext4.gz"
UML4TERMUX_DISK_FILE="debian-docker.ext4"
UML4TERMUX_BASE_INITRAMFS_FILE="initramfs-alpine.cpio.gz"
UML4TERMUX_GVPROXY_FILE="gvproxy"

# ---------------------------------------------------------------------------
# runtime paths
# ---------------------------------------------------------------------------
UML4TERMUX_GVNET_SOCK="${UML4TERMUX_GVNET_SOCK:-${UML4TERMUX_RUNTIME}/gvnet.sock}"
UML4TERMUX_BESS_SOCK="${UML4TERMUX_BESS_SOCK:-${UML4TERMUX_RUNTIME}/bess.sock}"
UML4TERMUX_UMID="${UML4TERMUX_UMID:-uml4termux}"
UML4TERMUX_INSTANCE_ENV="${UML4TERMUX_RUNTIME}/instance.env"
UML4TERMUX_GVPROXY_LOG="${UML4TERMUX_LOG_DIR}/gvproxy.log"

# ---------------------------------------------------------------------------
# guest / network defaults (verified values, do not "improve" blindly)
# ---------------------------------------------------------------------------
UML4TERMUX_MEM="${UML4TERMUX_MEM:-1024}"
UML4TERMUX_CPUS="${UML4TERMUX_CPUS:-4}"
UML4TERMUX_SMP="${UML4TERMUX_SMP:-seccomp=on}"
UML4TERMUX_GUEST_IP="${UML4TERMUX_GUEST_IP:-192.168.127.2}"
UML4TERMUX_GUEST_GW="${UML4TERMUX_GUEST_GW:-192.168.127.1}"
UML4TERMUX_GUEST_MAC="${UML4TERMUX_GUEST_MAC:-5a:94:ef:e4:0c:ee}"
UML4TERMUX_DNS="${UML4TERMUX_DNS:-192.168.127.1}"
UML4TERMUX_PORTS="${UML4TERMUX_PORTS:-8123:8123 8124:8124}"
UML4TERMUX_MARKER="${UML4TERMUX_MARKER:-WEB_UP_MARKER}"
UML4TERMUX_BOOT_TIMEOUT="${UML4TERMUX_BOOT_TIMEOUT:-900}"
UML4TERMUX_GUEST_LIFETIME="${UML4TERMUX_GUEST_LIFETIME:-0}"

# gvproxy under `proot -b $PREFIX/etc:/etc` so it can read /etc/resolv.conf
# (Android has none).  auto = only when the host really has no /etc/resolv.conf.
UML4TERMUX_GVPROXY_PROOT="${UML4TERMUX_GVPROXY_PROOT:-auto}"

UML4TERMUX_DRY_RUN="${UML4TERMUX_DRY_RUN:-0}"

# ---------------------------------------------------------------------------
# logging
# ---------------------------------------------------------------------------
if [ -t 2 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != "dumb" ]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_RED=$'\033[31m'; C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'; C_DIM=$'\033[2m'
else
  C_RESET=""; C_BOLD=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_DIM=""
fi

log()  { printf '%s\n' "$*"; }
msg()  { printf '%s\n' "$*" >&2; }
info() { printf '%s[info]%s %s\n' "${C_BLUE}" "${C_RESET}" "$*" >&2; }
warn() { printf '%s[warn]%s %s\n' "${C_YELLOW}" "${C_RESET}" "$*" >&2; }
err()  { printf '%s[err]%s %s\n' "${C_RED}" "${C_RESET}" "$*" >&2; }
ok()   { printf '%s[ok]%s %s\n' "${C_GREEN}" "${C_RESET}" "$*" >&2; }
skip() { printf '%s[skip]%s %s\n' "${C_DIM}" "${C_RESET}" "$*" >&2; }
step() { printf '\n%s==>%s %s%s%s\n' "${C_BOLD}${C_BLUE}" "${C_RESET}" "${C_BOLD}" "$*" "${C_RESET}" >&2; }
die()  { err "$*"; exit 1; }

# ---------------------------------------------------------------------------
# small helpers
# ---------------------------------------------------------------------------
uml4termux_is_dry_run() { [ "${UML4TERMUX_DRY_RUN}" = "1" ]; }

uml4termux_quote() {
  local a out=""
  for a in "$@"; do out+="$(printf '%q' "$a") "; done
  printf '%s' "${out% }"
}

# Echo the exact command line a non-dry-run invocation would use.
uml4termux_print_cmd() { printf '+ %s\n' "$(uml4termux_quote "$@")"; }

# Run a command, or only print it under --dry-run.
uml4termux_run() {
  if uml4termux_is_dry_run; then uml4termux_print_cmd "$@"; return 0; fi
  "$@"
}

# Run a shell string (for pipes / redirections), or only print it under --dry-run.
uml4termux_run_sh() {
  if uml4termux_is_dry_run; then printf '+ %s\n' "$1"; return 0; fi
  bash -c "$1"
}

# Start something detached: uml4termux_spawn <label> <logfile> <cmd...>
# Stores the pid in $UML4TERMUX_RUNTIME/<label>.pid
uml4termux_spawn() {
  local label="$1" logfile="$2" pid
  shift 2
  if uml4termux_is_dry_run; then
    uml4termux_print_cmd "$@"
    printf '+ (background: label=%s log=%s)\n' "${label}" "${logfile}"
    return 0
  fi
  uml4termux_runtime_init
  mkdir -p "$(dirname "${logfile}")"
  if command -v setsid >/dev/null 2>&1; then
    setsid "$@" </dev/null >>"${logfile}" 2>&1 &
  else
    "$@" </dev/null >>"${logfile}" 2>&1 &
  fi
  pid=$!
  printf '%s\n' "${pid}" > "${UML4TERMUX_RUNTIME}/${label}.pid"
  return 0
}

uml4termux_pidfile()   { printf '%s/%s.pid' "${UML4TERMUX_RUNTIME}" "$1"; }
uml4termux_read_pid()  { local f; f="$(uml4termux_pidfile "$1")"; [ -r "${f}" ] && tr -d ' \n' < "${f}" || true; }
uml4termux_pid_alive() {
	local p="${1:-}"
	[ -n "${p}" ] || return 1
	kill -0 "${p}" 2>/dev/null || return 1
	# PID-reuse guard: a recycled PID may now belong to an unrelated process.
	# When an expected identity fragment is given, require the live process's
	# cmdline to match it before trusting the PID.
	local want="${2:-}"
	if [ -n "${want}" ] && [ -r "/proc/${p}/cmdline" ]; then
		tr '\0' ' ' < "/proc/${p}/cmdline" 2>/dev/null | grep -qF -- "${want}" || return 1
	fi
	return 0
}

# Kill a process recorded in <label>.pid; SIGTERM then SIGKILL.
uml4termux_kill_label() {
  local label="$1" pid i
  pid="$(uml4termux_read_pid "${label}")"
  if [ -z "${pid}" ]; then skip "no ${label} pid recorded"; return 0; fi
  if ! uml4termux_pid_alive "${pid}"; then skip "${label} pid ${pid} is not running"; rm -f "$(uml4termux_pidfile "${label}")"; return 0; fi
  uml4termux_run kill -TERM "${pid}" || true
  for i in 1 2 3 4 5 6 7 8 9 10; do
    uml4termux_is_dry_run && break
    uml4termux_pid_alive "${pid}" || break
    sleep 0.5
  done
  if uml4termux_pid_alive "${pid}" && ! uml4termux_is_dry_run; then
    warn "${label} pid ${pid} ignored SIGTERM; sending SIGKILL"
    kill -KILL "${pid}" 2>/dev/null || true
  fi
  uml4termux_is_dry_run || rm -f "$(uml4termux_pidfile "${label}")"
  info "stopped ${label} (pid ${pid})"
}

# ---------------------------------------------------------------------------
# daemon ownership: when the daemon owns this runtime it is the SINGLE owner
# of the exposure registry, so front ends must route through its socket instead
# of keeping a parallel list (the two used to drift apart).
# ---------------------------------------------------------------------------
uml4termux_daemon_socket() { printf '%s/daemon.sock' "${UML4TERMUX_RUNTIME}"; }
uml4termux_daemon_running()  { [ -S "$(uml4termux_daemon_socket)" ]; }

uml4termux_daemon_bin() {
  local c
  for c in "${UML4TERMUXD_BIN:-}" "${UML4TERMUX_HOME}/${UML4TERMUXD_FILE}" "${PREFIX}/bin/uml4termuxd"; do
    [ -n "${c}" ] && [ -x "${c}" ] && { printf '%s' "${c}"; return 0; }
  done
  c="$(command -v uml4termuxd 2>/dev/null || true)"
  [ -n "${c}" ] && { printf '%s' "${c}"; return 0; }
  return 1
}

uml4termux_dirs_init() {
  if uml4termux_is_dry_run; then return 0; fi
  mkdir -p "${UML4TERMUX_HOME}" "${UML4TERMUX_STATE_DIR}" "${UML4TERMUX_LOG_DIR}" \
           "${UML4TERMUX_INITRAMFS_DIR}"
  return 0
}

uml4termux_runtime_init() {
  uml4termux_is_dry_run && return 0
  mkdir -p "${UML4TERMUX_RUNTIME}"
  chmod 700 "${UML4TERMUX_RUNTIME}" 2>/dev/null || true
  return 0
}

uml4termux_need_cmd() {
  local c
  for c in "$@"; do
    command -v "${c}" >/dev/null 2>&1 || die "required command not found: ${c}"
  done
}

uml4termux_sha256() {
  local f="$1"
  [ -f "${f}" ] || return 1
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${f}" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "${f}" | awk '{print $1}'
  else
    uml4termux_python -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "${f}"
  fi
}

# Termux ships a python3 whose shared libs are shadowed by LD_LIBRARY_PATH.
uml4termux_python() { env -u LD_LIBRARY_PATH python3 "$@"; }

uml4termux_python_ok() {
  uml4termux_python -c 'import sys' >/dev/null 2>&1
}

uml4termux_require_python() {
  if uml4termux_python_ok; then return 0; fi
  if python3 -c 'import sys' >/dev/null 2>&1; then
    uml4termux_python() { python3 "$@"; }
    return 0
  fi
  die "python3 is required (tried 'env -u LD_LIBRARY_PATH python3' and 'python3')"
}

uml4termux_now() { date '+%Y-%m-%dT%H:%M:%S%z'; }
uml4termux_ts()  { date '+%Y%m%d-%H%M%S'; }

uml4termux_sizeof() {
  local f="$1"
  [ -e "${f}" ] || { printf 'missing'; return 0; }
  if stat -c '%s' "${f}" >/dev/null 2>&1; then stat -c '%s' "${f}"; else wc -c < "${f}" | tr -d ' '; fi
}

uml4termux_human_size() {
  local b="$1"
  uml4termux_python -c 'import sys;b=float(sys.argv[1]);
u=["B","KiB","MiB","GiB","TiB"];i=0
while b>=1024 and i<len(u)-1: b/=1024.0;i+=1
print(f"{b:.1f} {u[i]}")' "${b}" 2>/dev/null || printf '%s B' "${b}"
}

uml4termux_asset_path() {
  case "$1" in
    kernel)          printf '%s/%s' "${UML4TERMUX_HOME}" "${UML4TERMUX_KERNEL_FILE}" ;;
    stub)            printf '%s/%s' "${UML4TERMUX_HOME}" "${UML4TERMUX_STUB_FILE}" ;;
    daemon)          printf '%s/%s' "${UML4TERMUX_HOME}" "${UML4TERMUXD_FILE}" ;;
    disk)            printf '%s/%s' "${UML4TERMUX_HOME}" "${UML4TERMUX_DISK_FILE}" ;;
    disk-gz)         printf '%s/%s' "${UML4TERMUX_HOME}" "${UML4TERMUX_DISK_GZ_FILE}" ;;
    base-initramfs)  printf '%s/%s' "${UML4TERMUX_HOME}" "${UML4TERMUX_BASE_INITRAMFS_FILE}" ;;
    gvproxy)         printf '%s/%s' "${UML4TERMUX_HOME}" "${UML4TERMUX_GVPROXY_FILE}" ;;
    *)               return 1 ;;
  esac
}

uml4termux_asset_sha() {
  case "$1" in
    kernel)         printf '%s' "${UML4TERMUX_KERNEL_SHA256}" ;;
    stub)           printf '%s' "${UML4TERMUX_STUB_SHA256}" ;;
    daemon)         printf '%s' "${UML4TERMUXD_SHA256}" ;;
    disk-gz)        printf '%s' "${UML4TERMUX_DISK_SHA256}" ;;
    base-initramfs) printf '%s' "${UML4TERMUX_BASE_INITRAMFS_SHA256}" ;;
    gvproxy)        printf '%s' "${UML4TERMUX_GVPROXY_SHA256}" ;;
    *)              printf '' ;;
  esac
}

uml4termux_asset_url() {
  case "$1" in
    kernel)         printf '%s' "${UML4TERMUX_KERNEL_URL}" ;;
    stub)           printf '%s' "${UML4TERMUX_STUB_URL}" ;;
    disk-gz)        printf '%s' "${UML4TERMUX_DISK_URL}" ;;
    base-initramfs) printf '%s' "${UML4TERMUX_BASE_INITRAMFS_URL}" ;;
    gvproxy)        printf '%s' "${UML4TERMUX_GVPROXY_URL}" ;;
    *)              return 1 ;;
  esac
}

# uml4termux_require_assets kernel stub ... : die (or warn under --dry-run).
uml4termux_require_assets() {
  local a p missing=0
  for a in "$@"; do
    p="$(uml4termux_asset_path "${a}")" || die "unknown asset: ${a}"
    if [ ! -f "${p}" ]; then
      missing=1
      if uml4termux_is_dry_run; then
        warn "asset '${a}' not present at ${p} (ignored under --dry-run)"
      else
        err "asset '${a}' not present at ${p}"
      fi
    fi
  done
  if [ "${missing}" = "1" ] && ! uml4termux_is_dry_run; then
    die "missing assets: run 'uml4termux fetch' (or set UML4TERMUX_HOME to a populated directory)"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# instance bookkeeping (one UML + one gvproxy at a time)
# ---------------------------------------------------------------------------
uml4termux_instance_read() {
  # echo "KEY=VALUE" lines if a state file exists
  [ -r "${UML4TERMUX_INSTANCE_ENV}" ] || return 1
  cat "${UML4TERMUX_INSTANCE_ENV}"
}

uml4termux_instance_get() {
  local key="$1" line
  [ -r "${UML4TERMUX_INSTANCE_ENV}" ] || return 1
  while IFS= read -r line; do
    case "${line}" in "${key}="*) printf '%s' "${line#*=}"; return 0 ;; esac
  done < "${UML4TERMUX_INSTANCE_ENV}"
  return 1
}

uml4termux_instance_write() {
  uml4termux_is_dry_run && { printf '+ (write instance state %s)\n' "${UML4TERMUX_INSTANCE_ENV}"; return 0; }
  uml4termux_runtime_init
  {
    printf 'STARTED=%s\n' "$(uml4termux_now)"
    printf 'UMID=%s\n' "${UML4TERMUX_UMID}"
    printf 'MEM=%s\n' "${UML4TERMUX_MEM}"
    printf 'CPUS=%s\n' "${UML4TERMUX_CPUS}"
    printf 'PORTS=%s\n' "${UML4TERMUX_PORTS}"
    printf 'GUEST_IP=%s\n' "${UML4TERMUX_GUEST_IP}"
    printf 'GVPROXY_PID=%s\n' "$(uml4termux_read_pid gvproxy)"
    printf 'UML_PID=%s\n' "$(uml4termux_read_pid uml)"
    printf 'GVPROXY_LOG=%s\n' "${UML4TERMUX_GVPROXY_LOG}"
    printf 'UML_LOG=%s\n' "${UML4TERMUX_UML_LOG:-}"
  } > "${UML4TERMUX_INSTANCE_ENV}"
}

uml4termux_instance_clear() {
  uml4termux_is_dry_run && { printf '+ (remove instance state %s)\n' "${UML4TERMUX_INSTANCE_ENV}"; return 0; }
  rm -f "${UML4TERMUX_INSTANCE_ENV}"
}

# True when a live instance holds the runtime dir.
uml4termux_instance_live() {
  local gp up
  gp="$(uml4termux_instance_get GVPROXY_PID 2>/dev/null || true)"
  up="$(uml4termux_instance_get UML_PID 2>/dev/null || true)"
  uml4termux_pid_alive "${gp}" && return 0
  uml4termux_pid_alive "${up}" && return 0
  return 1
}

# Drop anything stale: state file, sockets and a dead umid directory.
uml4termux_clean_stale() {
  local quiet="${1:-0}"
  if [ -r "${UML4TERMUX_INSTANCE_ENV}" ] && ! uml4termux_instance_live; then
    [ "${quiet}" = "1" ] || info "cleaning stale instance state (${UML4TERMUX_INSTANCE_ENV})"
    uml4termux_is_dry_run || rm -f "${UML4TERMUX_INSTANCE_ENV}"
  fi
  if [ -S "${UML4TERMUX_GVNET_SOCK}" ] || [ -S "${UML4TERMUX_BESS_SOCK}" ]; then
    local gpid; gpid="$(uml4termux_read_pid gvproxy)"
    if ! uml4termux_pid_alive "${gpid}"; then
      [ "${quiet}" = "1" ] || info "removing stale sockets under ${UML4TERMUX_RUNTIME}"
      uml4termux_is_dry_run || rm -f "${UML4TERMUX_GVNET_SOCK}" "${UML4TERMUX_BESS_SOCK}"
    fi
  fi
  # kernel umid dir: ~/.uml/<umid>
  local umldir="${HOME}/.uml/${UML4TERMUX_UMID}"
  if [ -d "${umldir}" ]; then
    local upid; upid="$(uml4termux_read_pid uml)"
    if ! uml4termux_pid_alive "${upid}"; then
      [ "${quiet}" = "1" ] || info "removing stale umid directory ${umldir}"
      uml4termux_is_dry_run || rm -rf "${umldir}"
    fi
  fi
  return 0
}

uml4termux_assert_no_instance() {
  if [ -r "${UML4TERMUX_INSTANCE_ENV}" ] && uml4termux_instance_live; then
    local gp up
    gp="$(uml4termux_instance_get GVPROXY_PID 2>/dev/null || true)"
    up="$(uml4termux_instance_get UML_PID 2>/dev/null || true)"
    err "a uml4termux instance is already running (gvproxy pid ${gp:-?}, uml pid ${up:-?})"
    err "refusing to start a second one: run 'uml4termux stop' first"
    exit 1
  fi
  uml4termux_clean_stale 0
  return 0
}

uml4termux_tail() {
  local f="$1" n="${2:-20}"
  [ -r "${f}" ] || return 0
  printf '%s--- tail -n %s %s ---%s\n' "${C_DIM}" "${n}" "${f}" "${C_RESET}" >&2
  tail -n "${n}" "${f}" >&2 || true
}
