# shellcheck shell=bash
#
# uml4termux — lib/doctor.sh
# Non-destructive environment report: no UML boot, no network, no writes
# outside the report itself.
#
# SPDX-License-Identifier: GPL-2.0-only

DOC_MISSING=0
DOC_MISMATCH=0
DOC_BROKEN=0

doc_field() { printf '  %-16s %s\n' "$1" "$2"; }
doc_head()  { printf '\n%s-- %s%s\n' "${C_BOLD}" "$1" "${C_RESET}"; }

doctor_usage() {
  cat <<'EOF'
uml4termux doctor [options]

Reports the host environment and the state of the runtime assets.  Never boots
UML and never changes anything.

Options:
  --no-assets   skip the asset inventory (works on a bare CI box)
  --strict      exit non-zero when a required tool is missing
  --json        machine-readable output
  -h, --help    this text

Exit codes: 0 ok, 77 required assets/kernel unavailable, 1 a check failed.
EOF
}

cmd_doctor() {
  local no_assets=0 strict=0 json=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --no-assets) no_assets=1 ;;
      --strict)    strict=1 ;;
      --json)      json=1 ;;
      -h|--help)   doctor_usage; return 0 ;;
      *)           die "doctor: unknown option '$1' (try 'uml4termux help doctor')" ;;
    esac
    shift
  done

  DOC_MISSING=0; DOC_MISMATCH=0; DOC_BROKEN=0
  if [ "${json}" = "1" ]; then doctor_json; return $?; fi

  printf '%suml4termux doctor%s  v%s (%s)\n' "${C_BOLD}" "${C_RESET}" "${UML4TERMUX_VERSION}" "${UML4TERMUX_LICENSE}"
  doc_field "when" "$(uml4termux_now)"

  doc_head "host"
  doc_field "uname" "$(uname -srm)"
  [ -r /proc/version ] && doc_field "kernel" "$(cat /proc/version)"
  if command -v getprop >/dev/null 2>&1; then
    local api model
    api="$(getprop ro.build.version.sdk 2>/dev/null || true)"
    model="$(getprop ro.product.model 2>/dev/null || true)"
    doc_field "android" "sdk=${api:-?} ($(getprop ro.build.version.release 2>/dev/null || true)) model=${model:-?}"
  else
    doc_field "android" "not an Android host (no getprop)"
  fi
  doc_field "prefix" "${PREFIX} (termux=${UML4TERMUX_IS_TERMUX})"
  doc_field "python" "$(command -v python3 2>/dev/null || echo MISSING)"
  if ( : > "${HOME}/.uml4termux-write-test" ) 2>/dev/null; then
    rm -f "${HOME}/.uml4termux-write-test"
    doc_field "HOME writable" "yes (UML needs it for ~/.uml/<umid>)"
  else
    doc_field "HOME writable" "NO -> UML cannot create ~/.uml/<umid>"
    DOC_BROKEN=$((DOC_BROKEN + 1))
  fi

  doc_head "cpu"
  doc_field "nproc" "$(nproc 2>/dev/null || echo '?')"
  local cpufeat
  cpufeat="$(grep -m1 -E '^(Features|flags)' /proc/cpuinfo 2>/dev/null | cut -d: -f2- | sed 's/^ *//' || true)"
  doc_field "features" "${cpufeat:-unreadable}"
  case "${cpufeat}" in
    *" paca"*|*paca*) doc_field "pointer auth" "yes (paca/pacg present)" ;;
    *bti*)            doc_field "bti" "yes" ;;
  esac
  doc_field "guest cpus" "requested ${UML4TERMUX_CPUS} with ${UML4TERMUX_SMP} (ptrace mode caps the guest at 1)"

  doc_head "sandbox"
  local capeff capbnd seccomp
  capeff="$(awk '/^CapEff:/{print $2}' /proc/self/status 2>/dev/null || true)"
  capbnd="$(awk '/^CapBnd:/{print $2}' /proc/self/status 2>/dev/null || true)"
  seccomp="$(awk '/^Seccomp:/{print $2}' /proc/self/status 2>/dev/null || true)"
  doc_field "CapEff" "${capeff:-?} $([ "${capeff}" = "0000000000000000" ] && echo '(unprivileged: expected)')"
  doc_field "CapBnd" "${capbnd:-?}"
  doc_field "seccomp" "${seccomp:-?} (2 = filter active; UML still installs its own)"
  local sysread=1 p m
  for p in /proc/sys/kernel/randomize_va_space /proc/sys/vm/mmap_min_addr /proc/sys/kernel/pid_max; do
    if m="$(cat "${p}" 2>/dev/null)"; then
      doc_field "readable" "${p} = ${m}"
    else
      sysread=0
      doc_field "unreadable" "${p} (Permission denied is normal in Termux)"
    fi
  done
  if [ "${sysread}" = "0" ]; then
    doc_field "note" "UML must run with no /proc/sys access: verified working (stub maps high, not low)"
  fi

  doc_head "tools"
  local t missing_tools=""
  for t in proot clang git curl tar gzip timeout setsid sha256sum truncate sed awk grep; do
    if command -v "${t}" >/dev/null 2>&1; then
      doc_field "${t}" "$(command -v "${t}")"
    else
      doc_field "${t}" "MISSING"
      missing_tools+="${t} "
    fi
  done
  if uml4termux_python_ok; then
    doc_field "python3" "runs via 'env -u LD_LIBRARY_PATH python3' ($(uml4termux_python -V 2>&1))"
  else
    doc_field "python3" "MISSING/BROKEN (needed for the initramfs builder and hashing)"
    DOC_BROKEN=$((DOC_BROKEN + 1))
  fi
  if command -v cpio >/dev/null 2>&1 && cpio --version >/dev/null 2>&1; then
    doc_field "cpio" "$(command -v cpio)"
  else
    doc_field "cpio" "not usable (the builder writes newc archives in pure python)"
  fi
  # proot is only needed to give gvproxy a /etc/resolv.conf on Android
  if [ "${UML4TERMUX_IS_TERMUX}" = "1" ] && ! command -v proot >/dev/null 2>&1; then
    doc_field "proot note" "proot is required on Termux: gvproxy reads /etc/resolv.conf"
    DOC_BROKEN=$((DOC_BROKEN + 1))
  fi

  doc_head "resources"
  local avail_kb total_kb need_kb
  if [ -r /proc/meminfo ]; then
    total_kb="$(awk '/^MemTotal:/{print $2}' /proc/meminfo)"
    avail_kb="$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)"
    doc_field "RAM" "total $(uml4termux_human_size $((total_kb * 1024))), available $(uml4termux_human_size $((avail_kb * 1024)))"
    need_kb=$((UML4TERMUX_MEM * 1024 + 262144))
    if [ "${avail_kb}" -lt "${need_kb}" ]; then
      warn "  less than mem=${UML4TERMUX_MEM}M + 256M is available: the guest may be OOM-killed"
    fi
  fi
  local dftarget dfavail
  for dftarget in "${HOME}" "${UML4TERMUX_HOME}"; do
    [ -d "${dftarget}" ] || continue
    dfavail="$(df -P -k "${dftarget}" 2>/dev/null | awk 'NR==2{print $4}')"
    if [ -n "${dfavail}" ]; then
      doc_field "free space" "${dftarget}: $(uml4termux_human_size $((dfavail * 1024)))"
      # image (1.2 GiB) + initramfs + logs; a grown 8 GiB image needs more
      if [ "${dfavail}" -lt 4194304 ]; then
        warn "  < 4 GiB free at ${dftarget}: the 1.2 GiB disk image needs room to decompress"
      fi
    fi
  done

  doc_head "android phantom-process killer"
  local api
  api="$(getprop ro.build.version.sdk 2>/dev/null || echo 0)"
  if [ "${api:-0}" -ge 31 ] 2>/dev/null; then
    doc_field "risk" "AMBER (sdk ${api}): the guest + dockerd + containers are many processes"
    doc_field "symptom" "guest dies mid-run with no kernel message (AMS kills it), ~32 child processes system-wide is the usual cap"
    doc_field "check adb" "adb shell device_config get activity_manager max_phantom_processes"
    doc_field "fix adb" "adb shell device_config put activity_manager max_phantom_processes 2147483647"
    doc_field "fix ui" "Developer options -> 'Disable child process restrictions' (Android 14+)"
    doc_field "fix termux" "termux-wake-lock; keep the app in the foreground while docker runs"
  else
    doc_field "risk" "low (sdk ${api:-?}: no phantom process killer, or not an Android host)"
    doc_field "check adb" "adb shell device_config get activity_manager max_phantom_processes"
  fi
  local procs
  procs="$(ps -e -o pid= 2>/dev/null | wc -l | tr -d ' ')"
  if [ -n "${procs}" ] && [ "${procs}" != "0" ]; then
    doc_field "processes" "${procs} visible now (a docker run adds dockerd + containerd + per-container procs)"
  fi

  doc_head "instance"
  if uml4termux_instance_live; then
    doc_field "running" "yes (uml pid $(uml4termux_instance_get UML_PID 2>/dev/null || echo ?), gvproxy pid $(uml4termux_instance_get GVPROXY_PID 2>/dev/null || echo ?))"
  else
    doc_field "running" "no"
  fi
  local stale=0
  [ -e "${UML4TERMUX_INSTANCE_ENV}" ] && stale=1
  [ -S "${UML4TERMUX_BESS_SOCK}" ] && stale=1
  [ -d "${HOME}/.uml/${UML4TERMUX_UMID}" ] && stale=1
  if [ "${stale}" = "1" ] && ! uml4termux_instance_live; then
    doc_field "stale" "leftover runtime state / sockets / ~/.uml/${UML4TERMUX_UMID} -> cleared by 'uml4termux stop'"
  fi

  if [ "${no_assets}" = "1" ]; then
    doc_head "assets"
    skip "--no-assets: asset inventory skipped"
  else
    doc_head "assets (UML4TERMUX_HOME=${UML4TERMUX_HOME})"
    doctor_assets
  fi

  doc_head "gvproxy"
  local gv; gv="$(uml4termux_asset_path gvproxy)"
  if [ -x "${gv}" ]; then
    local ver
    ver="$(timeout 10 "${gv}" -version 2>&1 | head -1 || true)"
    doc_field "version" "${ver:-?}"
  else
    doc_field "version" "unknown (gvproxy not fetched)"
    DOC_MISSING=$((DOC_MISSING + 1))
  fi

  # ---------------------------------------------------------------------
  doc_head "verdict"
  if [ "${DOC_MISMATCH}" -gt 0 ]; then
    err "FAIL: ${DOC_MISMATCH} asset checksum mismatch(es)"
    return 1
  fi
  if [ "${strict}" = "1" ] && [ "${DOC_BROKEN}" -gt 0 ]; then
    err "FAIL: ${DOC_BROKEN} broken requirement(s)"
    return 1
  fi
  if [ "${DOC_MISSING}" -gt 0 ]; then
    skip "SKIP: ${DOC_MISSING} asset(s) missing -> run 'uml4termux fetch'"
    return 77
  fi
  ok "PASS: host looks able to run UML arm64 + Docker"
  return 0
}

doctor_assets() {
  local a path want actual size
  for a in kernel stub disk disk-gz base-initramfs gvproxy; do
    path="$(uml4termux_asset_path "${a}")"
    want="$(uml4termux_asset_sha "${a}")"
    if [ ! -f "${path}" ]; then
      if [ "${a}" = "disk" ]; then
        skip "${a}: ${path} (run 'uml4termux init-image')"
      elif [ "${a}" = "disk-gz" ]; then
        skip "${a}: ${path} (run 'uml4termux fetch')"
      else
        skip "${a}: ${path} (run 'uml4termux fetch')"
        DOC_MISSING=$((DOC_MISSING + 1))
      fi
      continue
    fi
    size="$(uml4termux_human_size "$(uml4termux_sizeof "${path}")")"
    if [ -z "${want}" ]; then
      doc_field "${a}" "${path} (${size}) NOT VERIFIED (no pinned digest)"
      continue
    fi
    actual="$(uml4termux_sha256 "${path}" 2>/dev/null || echo '')"
    if [ "${actual}" = "${want}" ]; then
      doc_field "${a}" "OK   ${size}  sha256 ${actual}  ${path}"
    else
      doc_field "${a}" "BAD  ${size}  sha256 ${actual:-?} != ${want}  ${path}"
      DOC_MISMATCH=$((DOC_MISMATCH + 1))
    fi
  done
}

# Minimal JSON report (doctor --json).
doctor_json() {
  local a path state actual want
  printf '{\n'
  printf '  "version": "%s",\n' "${UML4TERMUX_VERSION}"
  printf '  "license": "%s",\n' "${UML4TERMUX_LICENSE}"
  printf '  "when": "%s",\n' "$(uml4termux_now)"
  printf '  "uname": "%s",\n' "$(uname -srm)"
  printf '  "prefix": "%s",\n' "${PREFIX}"
  printf '  "termux": %s,\n' "$([ "${UML4TERMUX_IS_TERMUX}" = "1" ] && echo true || echo false)"
  printf '  "capeff": "%s",\n' "$(awk '/^CapEff:/{print $2}' /proc/self/status 2>/dev/null || echo '')"
  printf '  "seccomp": "%s",\n' "$(awk '/^Seccomp:/{print $2}' /proc/self/status 2>/dev/null || echo '')"
  printf '  "home": "%s",\n' "${UML4TERMUX_HOME}"
  printf '  "assets": [\n'
  local first=1
  for a in kernel stub disk disk-gz base-initramfs gvproxy; do
    path="$(uml4termux_asset_path "${a}")"
    want="$(uml4termux_asset_sha "${a}")"
    if [ ! -f "${path}" ]; then
      state="missing"; actual=""
    else
      actual="$(uml4termux_sha256 "${path}" 2>/dev/null || echo '')"
      if [ -z "${want}" ]; then state="unverified"
      elif [ "${actual}" = "${want}" ]; then state="ok"
      else state="mismatch"; fi
    fi
    [ "${first}" = "1" ] || printf ',\n'
    first=0
    printf '    {"name": "%s", "path": "%s", "state": "%s", "sha256": "%s", "expected": "%s"}' \
      "${a}" "${path}" "${state}" "${actual}" "${want}"
  done
  printf '\n  ]\n}\n'
  [ "${DOC_MISMATCH}" -gt 0 ] && return 1
  return 0
}
