# shellcheck shell=bash
#
# uml4termux — lib/fetch.sh
# Asset download (kernel, stub_exe, Debian+Docker disk image, base initramfs,
# gvproxy) with sha256 verification when a SHA256SUMS file is available.
#
# SPDX-License-Identifier: GPL-2.0-only

# fetch_download <url> <dest>
fetch_download() {
  local url="$1" dest="$2" tmp="${2}.part"
  local -a auth=()
  # Release assets on a private repo need a token; harmless (ignored) on
  # public ones. GITHUB_TOKEN is never logged or echoed.
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    auth=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  fi
  if uml4termux_is_dry_run; then
    uml4termux_print_cmd curl -fL --retry 3 --connect-timeout 20 -o "${tmp}" "${url}"
    printf '+ mv %s %s\n' "$(uml4termux_quote "${tmp}")" "$(uml4termux_quote "${dest}")"
    return 0
  fi
  mkdir -p "$(dirname "${dest}")"
  rm -f "${tmp}"
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 --connect-timeout 20 --progress-bar -o "${tmp}" "${auth[@]}" "${url}"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "${tmp}" "${url}"
  else
    die "neither curl nor wget is available"
  fi
  mv -f "${tmp}" "${dest}"
}

# fetch_sha256sums <url> <dest> ; rc 0 when the sums file was retrieved
fetch_sha256sums() {
  local url="$1" dest="$2"
  if uml4termux_is_dry_run; then
    uml4termux_print_cmd curl -fsSL --connect-timeout 20 -o "${dest}" "${url}"
    return 0
  fi
  [ -n "${url}" ] || return 1
  case "${url}" in
    file://*|/*) [ -r "${url#file://}" ] && cp -f "${url#file://}" "${dest}" && return 0 || return 1 ;;
  esac
  command -v curl >/dev/null 2>&1 || return 1
  curl -fsSL --connect-timeout 20 -o "${dest}" "${url}" 2>/dev/null || return 1
  [ -s "${dest}" ] || return 1
  return 0
}

# fetch_lookup_sum <sumsfile> <basename> -> prints the digest
fetch_lookup_sum() {
  local sums="$1" name="$2"
  [ -r "${sums}" ] || return 1
  awk -v n="${name}" '{
    f=$2; sub(/^\*/, "", f); sub(/^\.\//, "", f);
    if (f == n) { print $1; exit }
  }' "${sums}"
}

# fetch_verify <asset> <file> [sumsfile names...]
# Verifies against the sums file first (when the asset name is listed), then
# against the pinned digest.  Prints NOT VERIFIED when neither is available.
fetch_verify() {
  local asset="$1" file="$2" lettername="$3"
  shift 3
  local want="" actual sums name
  for sums in "$@"; do
    [ -n "${sums}" ] || continue
    if [ -f "${sums}" ]; then
      want="$(fetch_lookup_sum "${sums}" "${lettername}" || true)"
      if [ -n "${want}" ]; then
        info "sha256 source: $(basename "${sums}")"
        break
      fi
      want=""
    fi
  done
  if [ -z "${want}" ]; then
    want="$(uml4termux_asset_sha "${asset}")"
    if [ -n "${want}" ]; then
      warn "no SHA256SUMS entry for ${lettername}: falling back to the pinned digest"
    fi
  fi
  if uml4termux_is_dry_run; then
    uml4termux_print_cmd sha256sum "${file}"
    [ -n "${want}" ] && printf '# expected %s  (%s)\n' "${want}" "${lettername}"
    return 0
  fi
  actual="$(uml4termux_sha256 "${file}")" || die "cannot hash ${file}"
  if [ -z "${want}" ]; then
    warn "NOT VERIFIED: no SHA256SUMS entry and no pinned digest for ${lettername}"
    warn "  sha256(${lettername}) = ${actual}"
    return 0
  fi
  if [ "${actual}" = "${want}" ]; then
    ok "sha256 ok  ${lettername}  ${actual}"
    return 0
  fi
  err "sha256 MISMATCH for ${lettername}"
  err "  expected ${want}"
  err "  actual   ${actual}"
  return 1
}

# fetch_one <asset> <lettername> <url> [sumsfile...]
fetch_one() {
  local asset="$1" lettername="$2" url="$3"
  shift 3
  local dest
  dest="$(uml4termux_asset_path "${asset}")" || die "unknown asset ${asset}"

  if [ -f "${dest}" ] && [ "${UML4TERMUX_FORCE:-0}" != "1" ]; then
    if fetch_verify "${asset}" "${dest}" "${lettername}" "$@"; then
      ok "already present: ${dest}"
      return 0
    fi
    warn "cached copy of ${lettername} failed verification: re-downloading"
  fi

  info "downloading ${lettername} <- ${url}"
  fetch_download "${url}" "${dest}"
  if ! uml4termux_is_dry_run; then
    chmod 0755 "${dest}" 2>/dev/null || true
  fi
  fetch_verify "${asset}" "${dest}" "${lettername}" "$@"
}

# ---------------------------------------------------------------------------
# commands
# ---------------------------------------------------------------------------
cmd_fetch_usage() {
  cat <<'EOF'
uml4termux fetch [options]

Download the runtime assets into $UML4TERMUX_HOME.

Options:
  --force                 re-download even when a verified copy exists
  --only A[,B...]         subset of: kernel,stub,disk,base,gvproxy,sums
  --base-url URL          release directory for the Debian image + base initramfs
  --kernel-url URL        kernel URL (default: the verified fork linux-bionic-smp)
  --stub-url URL          stub_exe URL
  --gvproxy-url URL       gvproxy URL
  --sums-url URL          SHA256SUMS URL (default: <base-url>/SHA256SUMS)
  --no-sums               skip the SHA256SUMS download, use pinned digests only
  -h, --help              this text
EOF
}

cmd_fetch() {
  local only="kernel,stub,disk,base,gvproxy,sums" no_sums=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --force)        UML4TERMUX_FORCE=1 ;;
      --only)         only="${2:?--only needs a value}"; shift ;;
      --base-url)     local _b="${2:?--base-url needs a value}"; _b="${_b%/}"
                      UML4TERMUX_UPSTREAM_BASE_URL="${_b}"
                      UML4TERMUX_DISK_URL="${_b}/debian-docker.ext4.gz"
                      UML4TERMUX_BASE_INITRAMFS_URL="${_b}/initramfs-alpine.cpio.gz"
                      UML4TERMUX_SHA256SUMS_URL="${_b}/SHA256SUMS"
                      shift ;;
      --kernel-url)   UML4TERMUX_KERNEL_URL="${2:?--kernel-url needs a value}"; shift ;;
      --stub-url)     UML4TERMUX_STUB_URL="${2:?--stub-url needs a value}"; shift ;;
      --gvproxy-url)  UML4TERMUX_GVPROXY_URL="${2:?--gvproxy-url needs a value}"; shift ;;
      --disk-url)     UML4TERMUX_DISK_URL="${2:?--disk-url needs a value}"; shift ;;
      --sums-url)     UML4TERMUX_SHA256SUMS_URL="${2:?--sums-url needs a value}"; shift ;;
      --no-sums)      no_sums=1 ;;
      -h|--help)      cmd_fetch_usage; return 0 ;;
      *)              die "fetch: unknown option '$1' (try 'uml4termux help fetch')" ;;
    esac
    shift
  done

  uml4termux_dirs_init
  uml4termux_require_python
  step "fetching uml4termux assets into ${UML4TERMUX_HOME}"

  local sums="${UML4TERMUX_HOME}/SHA256SUMS"
  local sums_gv="${UML4TERMUX_HOME}/SHA256SUMS.gvproxy"
  local have_sums=0 have_sums_gv=0
  if [ "${no_sums}" = "1" ]; then
    warn "--no-sums: verifying against the pinned digests only"
  else
    if fetch_sha256sums "${UML4TERMUX_SHA256SUMS_URL}" "${sums}"; then
      have_sums=1
    else
      warn "SHA256SUMS is not available at ${UML4TERMUX_SHA256SUMS_URL}"
      warn "  -> falling back to the digests pinned in this build"
    fi
    if fetch_sha256sums "${UML4TERMUX_GVPROXY_SHA256SUMS_URL}" "${sums_gv}"; then
      have_sums_gv=1
    else
      warn "gvproxy checksums are not available at ${UML4TERMUX_GVPROXY_SHA256SUMS_URL}"
      warn "  -> falling back to the pinned gvproxy digest"
    fi
  fi

  local wanted=",${only},"
  local rc=0
  # sha256sums files first so verification can use them
  case "${wanted}" in
    *,kernel,*)  fetch_one kernel         "${UML4TERMUX_KERNEL_FILE}"          "${UML4TERMUX_KERNEL_URL}"          "${sums}" || rc=1 ;;
  esac
  case "${wanted}" in
    *,stub,*)    fetch_one stub           "${UML4TERMUX_STUB_FILE}"            "${UML4TERMUX_STUB_URL}"            "${sums}" || rc=1 ;;
  esac
  case "${wanted}" in
    *,disk,*)    fetch_one disk-gz        "${UML4TERMUX_DISK_GZ_FILE}"         "${UML4TERMUX_DISK_URL}"            "${sums}" || rc=1 ;;
  esac
  case "${wanted}" in
    *,base,*)    fetch_one base-initramfs "${UML4TERMUX_BASE_INITRAMFS_FILE}"  "${UML4TERMUX_BASE_INITRAMFS_URL}"  "${sums}" || rc=1 ;;
  esac
  case "${wanted}" in
    *,gvproxy,*) fetch_one gvproxy        "gvproxy-linux-arm64"               "${UML4TERMUX_GVPROXY_URL}"         "${sums_gv}" "${sums}" || rc=1 ;;
  esac

  if [ "${rc}" -ne 0 ]; then
    err "one or more assets failed verification"
    return 1
  fi
  if [ "${have_sums}" = "0" ] && [ -z "${UML4TERMUX_KERNEL_SHA256}${UML4TERMUX_STUB_SHA256}${UML4TERMUX_DISK_SHA256}" ]; then
    warn "SHA256SUMS was not available and no pinned digests exist: nothing was verified"
  fi
  ok "assets ready in ${UML4TERMUX_HOME}"
  return 0
}

# ---------------------------------------------------------------------------
# init-image: debian-docker.ext4.gz -> debian-docker.ext4
# ---------------------------------------------------------------------------
cmd_init_image() {
  local size="" force=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --size)   size="${2:?--size needs a value}"; shift ;;
      --force)  force=1 ;;
      -h|--help) sed -n 's/^/ /p' <<'EOF'
uml4termux init-image [--size 8G] [--force]
  Decompress $UML4TERMUX_HOME/debian-docker.ext4.gz into debian-docker.ext4.
  --size grows the image (the guest runs resize2fs itself when it needs room).
EOF
        return 0 ;;
      *) die "init-image: unknown option '$1'" ;;
    esac
    shift
  done

  local gz raw
  gz="$(uml4termux_asset_path disk-gz)"
  raw="$(uml4termux_asset_path disk)"
  uml4termux_require_assets disk-gz

  if [ -f "${raw}" ] && [ "${force}" != "1" ]; then
    ok "disk image already present: ${raw} ($(uml4termux_human_size "$(uml4termux_sizeof "${raw}")"))"
  else
    step "decompressing ${gz} -> ${raw}"
    fetch_verify disk-gz "${gz}" "${UML4TERMUX_DISK_GZ_FILE}" "${UML4TERMUX_HOME}/SHA256SUMS" || die "refusing to decompress a disk image that failed verification"
    if uml4termux_is_dry_run; then
      uml4termux_run_sh "gzip -dc '${gz}' > '${raw}'"
    else
      rm -f "${raw}"
      gzip -dc "${gz}" > "${raw}"
      ok "disk image ready: ${raw} ($(uml4termux_human_size "$(uml4termux_sizeof "${raw}")"))"
    fi
  fi

  if [ -n "${size}" ]; then
    step "growing ${raw} to ${size}"
    uml4termux_run truncate -s "${size}" "${raw}"
    info "run 'resize2fs /dev/ubda' inside the guest after it boots"
  fi
  return 0
}
