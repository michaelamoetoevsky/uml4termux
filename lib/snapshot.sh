#!/bin/sh
# ---------------------------------------------------------------------------
# Snapshot & resume (direction C).
#
# A snapshot is a COLD state. The guest is stopped cleanly, the COW -- the only
# file that holds guest writes -- is copied aside together with a metadata
# record, and `up --from <label>` copies it back into the working COW path.
#
# Snapshots are IMMUTABLE: resume always copies, so resuming the same label
# twice gives two independent guests instead of one guest overwriting the other.
# What comes back is the filesystem, not RAM; resuming costs a boot.
#
# The one integration point with the daemon is the COW header. The daemon writes
# a header only when the COW is missing or not a valid v3 file, so a COW this
# code places there deliberately survives the boot. That is why a fresh `up`
# removes the working COW explicitly: the fresh/resume decision lives in exactly
# one place (the launcher) instead of being duplicated in C and Rust.
#
# SPDX-License-Identifier: GPL-2.0-only
# ---------------------------------------------------------------------------

UML4TERMUX_SNAPSHOT_KEEP="${UML4TERMUX_SNAPSHOT_KEEP:-5}"

uml4termux_snap_dir() { printf '%s/snapshots' "${1:?runtime dir required}"; }
uml4termux_snap_cow() { printf '%s/snapshots/%s.cow' "${1:?runtime dir required}" "${2:?label required}"; }
uml4termux_snap_meta() { printf '%s/snapshots/%s.meta' "${1:?runtime dir required}" "${2:?label required}"; }

# A label becomes a file name, so it is restricted rather than escaped.
uml4termux_snap_label_ok() {
  case "${1:-}" in
    '' | . | ..) return 1 ;;
    *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

uml4termux_snap_abs() { realpath "${1:?}" 2>/dev/null || printf '%s' "$1"; }

uml4termux_snap_sha256() {
  [ -r "${1:-}" ] || return 1
  sha256sum "$1" 2>/dev/null | cut -d' ' -f1
}

# "size mtime" -- the same two numbers the COW header records, so a resume is
# refused for the same reasons the kernel would refuse the BOOT.
uml4termux_snap_image_id() {
  [ -r "${1:-}" ] || return 1
  stat -c '%s %Y' "$1" 2>/dev/null
}

uml4termux_snap_meta_get() {
  sed -n "s/^${2}=//p" "${1:-/nonexistent}" 2>/dev/null | head -1
}

# C4: refuse up front, naming the numbers. UML would either reject the mismatch
# at boot or, worse, mix two backing images through one COW.
uml4termux_snap_verify() { # <runtime> <label> <image>
  local rt="$1" label="$2" image="$3" meta cow want_size want_mtime have want_sha got_sha

  meta="$(uml4termux_snap_meta "${rt}" "${label}")"
  cow="$(uml4termux_snap_cow "${rt}" "${label}")"

  [ -r "${meta}" ] || { err "no snapshot '${label}' in $(uml4termux_snap_dir "${rt}") (see 'uml4termux snapshots')"; return 1; }
  [ -r "${cow}" ] || { err "snapshot '${label}' has metadata but its COW file is gone (${cow}); it is not resumable"; return 1; }

  want_size="$(uml4termux_snap_meta_get "${meta}" BASE_SIZE)"
  want_mtime="$(uml4termux_snap_meta_get "${meta}" BASE_MTIME)"
  have="$(uml4termux_snap_image_id "${image}")" \
    || { err "backing image ${image} is missing or unreadable"; return 1; }

  if [ "${have}" != "${want_size} ${want_mtime}" ]; then
    err "snapshot '${label}' was taken against a different backing image:"
    err "  recorded: size ${want_size} bytes, mtime ${want_mtime}  ($(uml4termux_snap_meta_get "${meta}" BASE_IMAGE))"
    err "  now     : size ${have% *} bytes, mtime ${have#* }  (${image})"
    err "refusing to resume: the COW header names the recorded image."
    return 1
  fi

  # The cheap identity above catches a replaced or rewritten image. The full
  # digest is opt-in because it reads the whole image (seconds on a 3 GB disk):
  # set UML4TERMUX_SNAPSHOT_VERIFY_DIGEST=1 to pay that on every resume.
  if [ "${UML4TERMUX_SNAPSHOT_VERIFY_DIGEST:-0}" = "1" ]; then
    want_sha="$(uml4termux_snap_meta_get "${meta}" BASE_SHA256)"
    got_sha="$(uml4termux_snap_sha256 "${image}")"
    if [ -z "${want_sha}" ] || [ "${want_sha}" != "${got_sha}" ]; then
      err "snapshot '${label}' digest mismatch: recorded ${want_sha:-none}, now ${got_sha:-unreadable}"
      return 1
    fi
  fi
  return 0
}

# C1: stop cleanly (the caller does that), then copy + record.
uml4termux_snap_create() { # <runtime> <label> <image> <working-cow> [guest-uname]
  local rt="$1" label="$2" image="$3" src="$4" uname_s="${5:-}"
  local dir meta cow id size sha id_size id_mtime

  [ -s "${src}" ] || { err "nothing to snapshot: ${src} is missing or empty (boot the instance once)"; return 1; }

  dir="$(uml4termux_snap_dir "${rt}")"
  meta="$(uml4termux_snap_meta "${rt}" "${label}")"
  cow="$(uml4termux_snap_cow "${rt}" "${label}")"

  id="$(uml4termux_snap_image_id "${image}")" || { err "backing image ${image} is unreadable"; return 1; }
  id_size="${id% *}"
  id_mtime="${id#* }"

  mkdir -p "${dir}" || { err "cannot create ${dir}"; return 1; }

  # Copy to a temp name and rename: a snapshot either exists complete or not at
  # all, never half-written after an interrupted run.
  cp -f "${src}" "${cow}.tmp" || { err "copy ${src} -> ${cow} failed"; rm -f "${cow}.tmp"; return 1; }
  mv -f "${cow}.tmp" "${cow}" || { err "rename into ${cow} failed"; return 1; }

  size="$(stat -c%s "${cow}" 2>/dev/null)"
  if [ "${UML4TERMUX_SNAPSHOT_DIGEST:-1}" = "1" ]; then
    sha="$(uml4termux_snap_sha256 "${cow}")"
  else
    sha="skipped"
  fi

  {
    printf 'LABEL=%s\n' "${label}"
    printf 'CREATED_AT=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'HOST=%s\n' "$(uname -m)"
    printf 'BASE_IMAGE=%s\n' "$(uml4termux_snap_abs "${image}")"
    printf 'BASE_SIZE=%s\n' "${id_size}"
    printf 'BASE_MTIME=%s\n' "${id_mtime}"
    printf 'BASE_SHA256=%s\n' "$(uml4termux_snap_sha256 "${image}")"
    printf 'COW_SIZE=%s\n' "${size}"
    printf 'COW_SHA256=%s\n' "${sha}"
    printf 'GUEST_UNAME=%s\n' "${uname_s:-unknown}"
  } > "${meta}.tmp" && mv -f "${meta}.tmp" "${meta}" || { err "cannot write ${meta}"; return 1; }

  uml4termux_snap_rotate "${rt}" | sed 's/^/  /'
  info "snapshot '${label}': COW ${size} bytes, base image ${id_size} bytes (mtime ${id_mtime})"
  info "resume it with: uml4termux up --from ${label}"
  return 0
}

# C3: keep the newest <keep> snapshots, drop the rest (newest first by mtime).
uml4termux_snap_rotate() { # <runtime> [keep]
  local rt="$1" keep="${2:-${UML4TERMUX_SNAPSHOT_KEEP}}" dir f n=0 base
  dir="$(uml4termux_snap_dir "${rt}")"
  [ -d "${dir}" ] || return 0
  case "${keep}" in '' | *[!0-9]*) keep="${UML4TERMUX_SNAPSHOT_KEEP}" ;; esac

  ls -1t "${dir}"/*.meta 2>/dev/null | while IFS= read -r f; do
    n=$((n + 1))
    [ "${n}" -le "${keep}" ] && continue
    base="${f%.meta}"
    rm -f "${f}" "${base}.cow"
    printf 'dropped %s (keeping the newest %s)\n' "${base##*/}" "${keep}"
  done
  return 0
}

uml4termux_snap_remove() { # <runtime> <label>
  local rt="$1" label="$2" cow meta
  cow="$(uml4termux_snap_cow "${rt}" "${label}")"
  meta="$(uml4termux_snap_meta "${rt}" "${label}")"
  [ -e "${cow}" ] || [ -e "${meta}" ] || { err "no snapshot '${label}' in $(uml4termux_snap_dir "${rt}")"; return 1; }
  rm -f "${cow}" "${meta}" || { err "could not remove snapshot '${label}'"; return 1; }
  info "snapshot '${label}' removed"
  return 0
}

uml4termux_snap_list() { # <runtime>
  local rt="$1" dir f label created cow_size base guest any=0
  dir="$(uml4termux_snap_dir "${rt}")"
  if [ ! -d "${dir}" ]; then
    printf 'no snapshots in %s\n' "${dir}"
    return 0
  fi
  for f in "${dir}"/*.meta; do
    [ -r "${f}" ] || continue
    if [ "${any}" = "0" ]; then
      printf '%-20s %-21s %10s  %-12s %s\n' LABEL CREATED COW-BYTES BASE "GUEST"
      any=1
    fi
    label="${f##*/}"; label="${label%.meta}"
    created="$(uml4termux_snap_meta_get "${f}" CREATED_AT)"
    cow_size="$(uml4termux_snap_meta_get "${f}" COW_SIZE)"
    base="$(uml4termux_snap_meta_get "${f}" BASE_SIZE)"
    guest="$(uml4termux_snap_meta_get "${f}" GUEST_UNAME)"
    printf '%-20s %-21s %10s  %-12s %s\n' "${label}" "${created:-?}" "${cow_size:-?}" "${base:-?}" "${guest:-unknown}"
  done
  [ "${any}" = "1" ] || printf 'no snapshots in %s\n' "${dir}"
  return 0
}

# The guest's own idea of what it is: recorded so a resume can be compared with
# the boot that produced the snapshot.
uml4termux_snap_guest_uname() { # <runtime> <daemon-bin>
  local rt="$1" dbin="$2" out
  [ -x "${dbin}" ] || return 1
  out="$(UML4TERMUX_RUNTIME="${rt}" "${dbin}" exec 'uname -sr' 2>/dev/null)" || return 1
  [ -n "${out}" ] || return 1
  printf '%s' "${out}" | tr -d '\r' | tr '\n' ' ' | cut -c1-100
}

# C2: stage a snapshot as the working COW. The snapshot is read-only input; the
# copy is what the guest writes into. This is the whole of copy-on-resume.
uml4termux_snap_swap_in() { # <runtime> <label> <working-cow>
  local rt="$1" label="$2" cow="$3" src
  src="$(uml4termux_snap_cow "${rt}" "${label}")"
  [ -r "${src}" ] || { err "snapshot '${label}' has no COW file (${src})"; return 1; }

  cp -f "${src}" "${cow}.tmp" || { err "could not copy snapshot '${label}' into ${cow}.tmp"; rm -f "${cow}.tmp"; return 1; }
  mv -f "${cow}.tmp" "${cow}" || { err "could not stage ${cow}"; return 1; }
  info "resuming '${label}': working COW staged from $(basename "${src}") (the snapshot itself stays untouched)"
  return 0
}

# ---------------------------------------------------------------- commands

cmd_snapshot() {
  local name label="" rm_label="" rt="" image="" stop=1 uname_s="" dbin=""
  name="$(uml4termux_instance_name)"
  while [ $# -gt 0 ]; do
    case "$1" in
      --name)    name="${2:?--name needs a value}"; shift ;;
      --runtime) rt="${2:?--runtime needs a value}"; shift ;;
      --image)   image="${2:?--image needs a value}"; shift ;;
      --rm)      rm_label="${2:?--rm needs a label}"; shift ;;
      --no-stop) stop=0 ;;
      -h|--help) usage_snapshot; return 0 ;;
      -*)        die "snapshot: unknown option '$1' (try 'uml4termux help snapshot')" ;;
      *)         label="$1" ;;
    esac
    shift
  done

  uml4termux_require_instance_dirs
  [ -n "${rt}" ] || rt="$(uml4termux_reg_get "${name}" RUNTIME 2>/dev/null)" || rt="${UML4TERMUX_RUNTIME}"
  [ -n "${image}" ] || image="$(uml4termux_reg_get "${name}" IMAGE 2>/dev/null)" || image="$(uml4termux_asset_path disk)"

  if [ -n "${rm_label}" ]; then
    uml4termux_snap_label_ok "${rm_label}" || die "snapshot: label '${rm_label}' must match [A-Za-z0-9._-]+"
    uml4termux_snap_remove "${rt}" "${rm_label}"
    return $?
  fi

  [ -n "${label}" ] || die "snapshot: a label is required, e.g. 'uml4termux snapshot before-upgrade' (see 'uml4termux snapshots')"
  uml4termux_snap_label_ok "${label}" || die "snapshot: label '${label}' must match [A-Za-z0-9._-]+"

  # Ask the guest what it is BEFORE stopping it: afterwards there is nothing left
  # to ask, and the answer is what makes two resumes comparable.
  if uml4termux_reg_live "${name}"; then
    dbin="$(uml4termux_daemon_bin 2>/dev/null)" || dbin=""
    [ -z "${dbin}" ] || uname_s="$(uml4termux_snap_guest_uname "${rt}" "${dbin}")" || uname_s=""
    if [ "${stop}" = "1" ]; then
      info "stopping '${name}' cleanly: a snapshot of a guest that is still writing is not a state worth keeping"
      cmd_down --name "${name}" >/dev/null 2>&1 || true
      if uml4termux_reg_live "${name}"; then
        err "instance '${name}' is still live after 'down'; refusing to snapshot a running guest"
        return 1
      fi
    fi
  fi

  uml4termux_snap_create "${rt}" "${label}" "${image}" "${rt}/${name}.cow" "${uname_s}"
}

cmd_snapshots() {
  local name rt=""
  name="$(uml4termux_instance_name)"
  while [ $# -gt 0 ]; do
    case "$1" in
      --name)    name="${2:?--name needs a value}"; shift ;;
      --runtime) rt="${2:?--runtime needs a value}"; shift ;;
      -h|--help) usage_snapshots; return 0 ;;
      *)         die "snapshots: unknown option '$1' (try 'uml4termux help snapshots')" ;;
    esac
    shift
  done

  uml4termux_require_instance_dirs
  [ -n "${rt}" ] || rt="$(uml4termux_reg_get "${name}" RUNTIME 2>/dev/null)" || rt="${UML4TERMUX_RUNTIME}"
  uml4termux_snap_list "${rt}"
}
