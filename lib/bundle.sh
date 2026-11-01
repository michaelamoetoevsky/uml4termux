# shellcheck shell=bash
#
# uml4termux — lib/bundle.sh
# Moving a guest to another device: one file, verified before it is allowed to boot.
#
# Direction "mobility" in docs/DIRECTION-UML-CORE.md. The pieces already exist -- the image is a
# file, snapshot/resume exists (COW v3), images are fetched only when missing -- but "copy these
# three files and hope" is not mobility. A bundle carries a manifest of digests, and import checks
# every digest BEFORE anything runs: a bundle that fails verification is refused, never booted.
#
# Bundle layout (tar):
#   manifest.json     schema, version, and {sha256,bytes} for each payload file
#   kernel            the pinned UML kernel
#   image             the backing image
#   cow               optional COW overlay (only when a snapshot exists)
#
# SPDX-License-Identifier: GPL-2.0-only

# uml4termux_bundle_manifest_write <dir> <version> -> writes <dir>/manifest.json and prints it
uml4termux_bundle_manifest_write() {
  local dir="$1" version="$2"
  env -u LD_LIBRARY_PATH python3 - "$dir" "$version" <<'PYBUNDLE'
import hashlib
import json
import os
import pathlib
import sys
import datetime as dt

d = pathlib.Path(sys.argv[1])
version = sys.argv[2]
files = {}
for name in ("kernel", "image", "cow"):
    p = d / name
    if not p.is_file():
        continue
    h = hashlib.sha256()
    with p.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    files[name] = {"sha256": h.hexdigest(), "bytes": p.stat().st_size}
manifest = {
    "schema": 1,
    "project_version": version,
    "created_at": dt.datetime.now().astimezone().isoformat(timespec="seconds"),
    "files": files,
}
out = d / "manifest.json"
out.write_text(json.dumps(manifest, indent=2) + "\n")
print(json.dumps(manifest))
PYBUNDLE
}

# uml4termux_bundle_verify <dir> -> 0 when every file matches, 1 otherwise (prints what failed)
uml4termux_bundle_verify() {
  local dir="$1"
  env -u LD_LIBRARY_PATH python3 - "$dir" <<'PYBUNDLE'
import hashlib
import json
import pathlib
import sys

d = pathlib.Path(sys.argv[1])
mp = d / "manifest.json"
if not mp.is_file():
    print("bundle has no manifest.json")
    raise SystemExit(1)
try:
    manifest = json.loads(mp.read_text())
except json.JSONDecodeError as exc:
    print(f"manifest is not valid JSON: {exc}")
    raise SystemExit(1)
files = manifest.get("files") or {}
if not files:
    print("manifest lists no files")
    raise SystemExit(1)

problems = []
for name, want in files.items():
    p = d / name
    if not p.is_file():
        problems.append(f"{name}: missing")
        continue
    h = hashlib.sha256()
    with p.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    got = h.hexdigest()
    if got != want.get("sha256"):
        problems.append(f"{name}: sha256 {got[:16]} != manifest {str(want.get('sha256'))[:16]}")
    elif p.stat().st_size != want.get("bytes"):
        problems.append(f"{name}: {p.stat().st_size} bytes != manifest {want.get('bytes')}")

if problems:
    for line in problems:
        print(line)
    raise SystemExit(1)
print("verified " + ", ".join(sorted(files)))
raise SystemExit(0)
PYBUNDLE
}

# cmd_bundle <export|import> ...
cmd_bundle() {
  local sub="${1:-}"
  shift || true
  case "${sub}" in
    export) _bundle_export "$@" ;;
    import) _bundle_import "$@" ;;
    *) die "usage: uml4termux bundle export --name NAME --out FILE.tar | import --bundle FILE.tar --dir DIR" ;;
  esac
}

_bundle_export() {
  local name="" out=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --name) name="${2:?}"; shift ;;
      --out)  out="${2:?}"; shift ;;
      *) die "bundle export: unknown argument '$1'" ;;
    esac
    shift
  done
  [ -n "${name}" ] || die "bundle export: --name is required"
  [ -n "${out}" ] || die "bundle export: --out is required"

  local work; work="$(mktemp -d)"
  trap 'rm -rf "${work}"' RETURN

  local image; image="$(uml4termux_reg_get "${name}" IMAGE 2>/dev/null || true)"
  [ -n "${image}" ] && [ -f "${image}" ] || image="$(uml4termux_asset_path disk 2>/dev/null || true)"
  [ -n "${image}" ] && [ -f "${image}" ] || die "bundle export: no image for instance '${name}'"

  local kernel; kernel="$(uml4termux_asset_path kernel 2>/dev/null || true)"
  [ -n "${kernel}" ] && [ -f "${kernel}" ] || die "bundle export: kernel asset missing"

  cp -f "${kernel}" "${work}/kernel"
  # --sparse keeps the 1.2 GiB image from becoming a 1.2 GiB copy
  cp --sparse=always -f "${image}" "${work}/image"
  local snap="${UML4TERMUX_RUNTIME}/snapshots/${name}.cow"
  [ -f "${snap}" ] && cp --sparse=always -f "${snap}" "${work}/cow"

  local version; version="$(cat "${UML4TERMUX_ROOT}/VERSION" 2>/dev/null || printf 'unknown')"
  uml4termux_bundle_manifest_write "${work}" "${version}" >/dev/null

  local files=(manifest.json kernel image)
  [ -f "${work}/cow" ] && files+=(cow)
  ( cd "${work}" && tar -cf "${out}.tmp" "${files[@]}" ) || die "bundle export: tar failed"
  mv -f "${out}.tmp" "${out}"
  printf 'bundle: %s (%s bytes)\n' "${out}" "$(wc -c < "${out}" | tr -d ' ')"
}

_bundle_import() {
  local bundle="" dir=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --bundle) bundle="${2:?}"; shift ;;
      --dir)    dir="${2:?}"; shift ;;
      *) die "bundle import: unknown argument '$1'" ;;
    esac
    shift
  done
  [ -f "${bundle}" ] || die "bundle import: '${bundle}' is not a file"
  [ -n "${dir}" ] || die "bundle import: --dir is required"

  mkdir -p "${dir}"
  tar -xf "${bundle}" -C "${dir}" || die "bundle import: not a readable tar"

  local verdict rc
  verdict="$(uml4termux_bundle_verify "${dir}")"; rc=$?
  if [ "${rc}" -ne 0 ]; then
    printf 'bundle import: REFUSED -- %s\n' "${verdict}" >&2
    printf 'bundle import: nothing was booted; remove or re-copy %s\n' "${dir}" >&2
    return 64
  fi
  printf 'bundle import: %s\n' "${verdict}"
  printf 'bundle import: image ready at %s/image\n' "${dir}"
  printf '           boot with: uml4termux up --image %s/image\n' "${dir}"
}