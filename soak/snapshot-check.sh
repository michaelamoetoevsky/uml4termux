#!/usr/bin/env bash
#
# C — snapshot & resume, end to end on the device (docs/NEXT-STEPS.md, direction C).
#
# What this proves, with a real guest and a real boot each time:
#   C1  a snapshot stops the guest cleanly and records what it was taken against;
#   C2  a resume brings the FILESYSTEM back -- a file written before the snapshot
#       is readable after resuming -- and the snapshot itself is immutable, so
#       resuming the same label twice does not show the second guest's writes;
#   C4  a snapshot taken against a different backing image is refused before a
#       single byte is staged, with the recorded and observed numbers in the
#       message.
#
# Device facts that shape this script, every one of them learned by getting it
# wrong in this project:
#   * /proc/net/tcp is NOT readable on Termux/Android, so liveness is answered by
#     an actual request, never by parsing /proc;
#   * `up` ADOPTS a daemon that is already serving the runtime directory and
#     returns 0 without booting anything, so every resume is preceded by `down` --
#     otherwise a "second resume" silently re-tests the first guest;
#   * the console log is written through an open handle, so deleting it while a
#     daemon lives unlinks the file and the output disappears. It is moved aside
#     (archived as evidence) only after `down`;
#   * the console ECHOES the command it is given, so any marker typed literally
#     proves nothing. Every payload and every marker below is base64 in the typed
#     text and only appears in clear text when the guest actually executes it; the
#     strong evidence is an md5 of the file content, which is never typed at all;
#   * leftover processes are counted for THIS run's work directory. A device-wide
#     count reports the operator's own runit guest as a leftover.
#
# usage: soak/snapshot-check.sh [--out DIR] [--ssh-port N]
# SPDX-License-Identifier: GPL-2.0-only
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${ROOT}/bin/uml4termux"
DBIN="${UML4TERMUXD_BIN:-${ROOT}/bin/uml4termuxd}"
OUT=""
SSH_PORT="${C_SSH_PORT:-12640}"
MEM="${C_MEM:-2048M}"
GUEST_PORT="${C_GUEST_PORT:-8123}"
rc_total=0

while [ $# -gt 0 ]; do
  case "$1" in
    --out)      OUT="${2:?}"; shift ;;
    --ssh-port) SSH_PORT="${2:?}"; shift ;;
    -h|--help)  sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "c: unknown option '$1'" >&2; exit 64 ;;
  esac
  shift
done

port_busy() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }
for _t in 1 2 3 4 5; do port_busy "${SSH_PORT}" || break; SSH_PORT=$((SSH_PORT + 1)); done
port_busy "${SSH_PORT}" && { echo "c: no free ssh port near ${SSH_PORT}" >&2; exit 1; }

export NO_COLOR=1
OUT="${OUT:-${TMPDIR:-/tmp}/c-snapshot-$(date +%Y%m%d-%H%M%S)}"
W="${OUT}/work"
mkdir -p "${W}/guest" "${W}/initramfs" "${W}/state" "${OUT}/console"
export UML4TERMUX_STATE_DIR="${W}/state"
export UML4TERMUX_INITRAMFS_DIR="${W}/initramfs"
ASSETS="${UML4TERMUX_HOME:-$HOME/.uml4termux}"
IMG_SRC="${ASSETS}/${UML4TERMUX_DISK_FILE:-debian-docker.ext4}"
BASE="${ASSETS}/initramfs-alpine.cpio.gz"
RT="${W}/rt-c"
NAME="c1"
fail() { printf '  FAIL: %s\n' "$1"; rc_total=1; }
ok()   { printf '  PASS: %s\n' "$1"; }
exe_of() { readlink "/proc/$1/exe" 2>/dev/null; }

[ -x "${DBIN}" ] || { echo "c: daemon client not found: ${DBIN}" >&2; exit 1; }
for f in "${BASE}" "${IMG_SRC}" "${ASSETS}/gvproxy"; do
  [ -e "${f}" ] || { echo "c: missing ${f}" >&2; exit 1; }
done

# ---------------------------------------------------------------------------
# Markers that cannot lie. Nothing below is typed into the guest in clear text:
# the guest sees base64 and prints the decoded form only when it runs the
# command, and it prints an md5 of the file content that this script computes
# independently.
# ---------------------------------------------------------------------------
b64() { printf '%s' "$1" | base64 -w0; }
PAYLOAD_A='SNAP-A-CONTENT'
PAYLOAD_B='SNAP-B-CONTENT'
MK_WROTE_A='WROTE_A'; MK_READ_A='READ_A'; MK_WROTE_B='WROTE_B'; MK_READ_B='READ_B'
MD5_A="$(printf '%s' "${PAYLOAD_A}" | md5sum | cut -c1-10)"
MD5_B="$(printf '%s' "${PAYLOAD_B}" | md5sum | cut -c1-10)"
CMD_WRITE_A="echo $(b64 "${PAYLOAD_A}") | base64 -d > /root/snap-a.txt; md5sum /root/snap-a.txt | cut -c1-10; echo \$(echo $(b64 "${MK_WROTE_A}") | base64 -d)"
CMD_READ_A="md5sum /root/snap-a.txt 2>/dev/null | cut -c1-10; echo \$(echo $(b64 "${MK_READ_A}") | base64 -d)"
CMD_WRITE_B="echo $(b64 "${PAYLOAD_B}") | base64 -d > /root/snap-b.txt; md5sum /root/snap-b.txt | cut -c1-10; echo \$(echo $(b64 "${MK_WROTE_B}") | base64 -d)"
CMD_READ_B="md5sum /root/snap-b.txt 2>/dev/null | cut -c1-10; echo \$(echo $(b64 "${MK_READ_B}") | base64 -d)"
echo "c: md5 isi A=${MD5_A} B=${MD5_B} (dihitung di host, dicocokkan dengan keluaran guest)"

cp "${ROOT}/scripts/guest/init" "${ROOT}/scripts/guest/forensic.sh" "${ROOT}/scripts/guest/docker-init.sh" "${W}/guest/"
chmod 0755 "${W}"/guest/* 2>/dev/null || true
env -u LD_LIBRARY_PATH python3 "${ROOT}/scripts/build-initramfs.py" \
  --guest-dir "${W}/guest" --base "${BASE}" --entry /docker-init.sh \
  --define GUEST_IP=192.168.127.2 --define GUEST_GW=192.168.127.1 \
  --define GUEST_DNS=192.168.127.1 --define WEB_PORTS="${GUEST_PORT}" \
  --define GUEST_LIFETIME=0 \
  --out "${W}/initramfs/docker.cpio.gz" --force >"${OUT}/build.log" 2>&1 \
  || { echo "c: initramfs build failed (${OUT}/build.log)" >&2; exit 1; }

cp -f "${IMG_SRC}" "${W}/img.ext4"
IMG_SHA_BEFORE="$(sha256sum "${W}/img.ext4" | cut -d' ' -f1)"

CONSOLE="${RT}/uml-console.log"
boot_n=0
marker_count() { # always a number, even before the console exists
  local n
  n="$(grep -ac "$1" "${CONSOLE}" 2>/dev/null)"
  printf '%s' "${n:-0}"
}
wait_marker() { # <marker> <seconds>
  local marker="$1" limit="$2" i=0
  while [ "${i}" -lt "${limit}" ]; do
    [ "$(marker_count "${marker}")" -gt 0 ] && return 0
    sleep 5; i=$((i + 5))
  done
  return 1
}
archive_console() { # only after the instance is down (see header)
  boot_n=$((boot_n + 1))
  if [ -e "${CONSOLE}" ]; then
    mv -f "${CONSOLE}" "${OUT}/console/boot-${boot_n}-previous.log" 2>/dev/null || true
  fi
  echo "boot ${boot_n} started $(date -u +%Y-%m-%dT%H:%M:%SZ)" > "${OUT}/console/boot-${boot_n}.txt"
}
instance_down() {
  UML4TERMUX_RUNTIME="${RT}" "${BIN}" down --name "${NAME}" >/dev/null 2>&1 || true
  sleep 3
}
up_wait() { # <log> [extra up args...]
  local log="$1"; shift
  UML4TERMUX_RUNTIME="${RT}" "${BIN}" up --name "${NAME}" --image "${W}/img.ext4" \
    --mem "${MEM}" --ssh-port "${SSH_PORT}" --timeout 300 "$@" >"${log}" 2>&1
}
guest_shell() { UML4TERMUX_RUNTIME="${RT}" "${DBIN}" exec "$1" >/dev/null 2>&1 || true; }
guest_run() { # <marker> <command> <seconds> -- retried: a line typed before the
  local marker="$1" cmd="$2" limit="${3:-180}" i=0 j   # console agent reads is lost
  while [ "${i}" -lt "${limit}" ]; do
    guest_shell "${cmd}"
    j=0
    while [ "${j}" -lt 6 ]; do
      [ "$(marker_count "${marker}")" -gt 0 ] && return 0
      sleep 5; j=$((j + 1))
    done
    i=$((i + 30))
  done
  return 1
}
console_tail() { tail -8 "${CONSOLE}" 2>/dev/null | tr -d '\r' | sed 's/^/      /'; }

echo "== langkah 1: boot bersih (image privat) =="
instance_down
archive_console
if up_wait "${OUT}/up1.log"; then ok "instance siap (up rc=0)"; else fail "up gagal (lihat ${OUT}/up1.log)"; fi
[ -n "$(sed -n 's/^PID=//p' "${W}/state/instances/${NAME}.env" 2>/dev/null)" ] \
  && ok "registry instance terisi" || fail "registry instance kosong"
if wait_marker 'WEB_UP_MARKER' 300; then ok "guest hidup (WEB_UP_MARKER)"; else fail "WEB_UP_MARKER tidak muncul"; fi

echo "== langkah 2: tulis berkas penanda DI DALAM guest =="
if guest_run "${MK_WROTE_A}" "${CMD_WRITE_A}" 180; then
  if [ "$(marker_count "${MD5_A}")" -gt 0 ]; then
    ok "berkas ditulis dengan isi yang benar (md5 ${MD5_A} muncul dari eksekusi, bukan dari echo)"
  else
    fail "perintah dijalankan tapi md5 isi tidak muncul"
  fi
else
  fail "perintah tulis tidak pernah dieksekusi di guest"
  console_tail
fi

echo "== langkah 3: snapshot (C1) =="
UML4TERMUX_RUNTIME="${RT}" "${BIN}" snapshot snap-a --name "${NAME}" >"${OUT}/snapshot.log" 2>&1 \
  && ok "snapshot rc=0" || { fail "snapshot gagal"; sed -n '1,10p' "${OUT}/snapshot.log" | sed 's/^/    /'; }
[ -s "${RT}/snapshots/snap-a.cow" ] && ok "COW snapshot ada" || fail "COW snapshot tidak ada"
BASE_SIZE="$(stat -c%s "${W}/img.ext4")"
[ "$(sed -n 's/^BASE_SIZE=//p' "${RT}/snapshots/snap-a.meta")" = "${BASE_SIZE}" ] \
  && ok "BASE_SIZE tercatat = ${BASE_SIZE}" || fail "BASE_SIZE tidak cocok"
[ -n "$(sed -n 's/^BASE_SHA256=//p' "${RT}/snapshots/snap-a.meta")" ] \
  && ok "BASE_SHA256 tercatat" || fail "BASE_SHA256 kosong"
SNAP_SHA="$(sha256sum "${RT}/snapshots/snap-a.cow" | cut -d' ' -f1)"
echo "     snapshot COW sha256=${SNAP_SHA:0:16}... size=$(stat -c%s "${RT}/snapshots/snap-a.cow")"
instance_down

echo "== langkah 4: resume pertama (C2) -- berkas harus masih ada =="
archive_console
if up_wait "${OUT}/up2.log" --from snap-a; then ok "resume rc=0"; else fail "resume gagal (lihat ${OUT}/up2.log)"; fi
if wait_marker 'WEB_UP_MARKER' 300; then ok "guest hidup lagi dari snapshot"; else fail "guest tidak hidup setelah resume"; fi
if guest_run "${MK_READ_A}" "${CMD_READ_A}" 240; then
  if [ "$(marker_count "${MD5_A}")" -gt 0 ]; then
    ok "berkas yang ditulis SEBELUM snapshot terbaca SETELAH resume (md5 sama, state kembali)"
  else
    fail "guest menjawab tapi md5 isi tidak muncul: berkas tidak kembali"
    console_tail
  fi
else
  fail "tidak ada jawaban dari guest untuk pembacaan berkas"
  console_tail
fi

echo "== langkah 4b: resume pada instance yang MASIH HIDUP harus ditolak =="
# Without this the launcher would adopt the running daemon and report success
# while nothing was resumed -- the instance the caller wanted replaced keeps
# running. Snapshot snap-a exists at this point, and the guest is live.
set +e
UML4TERMUX_RUNTIME="${RT}" "${BIN}" up --name "${NAME}" --image "${W}/img.ext4" \
  --mem "${MEM}" --ssh-port "${SSH_PORT}" --from snap-a --timeout 30 >"${OUT}/refuse-live.log" 2>&1
rc_live=$?
set +e
[ "${rc_live}" -ne 0 ] && ok "resume pada instance hidup DITOLAK (rc=${rc_live})" || fail "resume pada instance hidup diterima"
grep -q 'is live' "${OUT}/refuse-live.log" && grep -q 'down --name' "${OUT}/refuse-live.log" \
  && ok "pesan menyebut sebabnya dan perintah yang harus dijalankan" || { fail "pesan tidak menuntun"; sed -n '1,6p' "${OUT}/refuse-live.log" | sed 's/^/    /'; }
LIVE_PID="$(sed -n 's/^PID=//p' "${W}/state/instances/${NAME}.env" 2>/dev/null)"
[ -n "${LIVE_PID}" ] && [ -d "/proc/${LIVE_PID}" ] && ok "guest yang hidup tidak diganggu (pid ${LIVE_PID} masih hidup)" \
  || fail "instance yang seharusnya hidup ternyata mati"

echo "== langkah 5: tulis penanda kedua, lalu resume snapshot yang SAMA lagi (C2) =="
if guest_run "${MK_WROTE_B}" "${CMD_WRITE_B}" 180 && [ "$(marker_count "${MD5_B}")" -gt 0 ]; then
  ok "penanda kedua ditulis (md5 ${MD5_B})"
else
  fail "penanda kedua tidak berhasil ditulis"
  console_tail
fi
if [ "$(sha256sum "${RT}/snapshots/snap-a.cow" | cut -d' ' -f1)" = "${SNAP_SHA}" ]; then
  ok "snapshot tidak berubah setelah resume pertama (immutable)"
else
  fail "snapshot berubah setelah resume pertama"
fi
instance_down
archive_console
if up_wait "${OUT}/up3.log" --from snap-a; then ok "resume kedua rc=0"; else fail "resume kedua gagal"; fi
if wait_marker 'WEB_UP_MARKER' 300; then ok "guest hidup dari snapshot yang sama"; else fail "guest tidak hidup pada resume kedua"; fi
if guest_run "${MK_READ_A}" "${CMD_READ_A}" 240 && [ "$(marker_count "${MD5_A}")" -gt 0 ]; then
  ok "penanda pertama kembali lagi (dua boot dari satu snapshot)"
else
  fail "penanda pertama hilang pada resume kedua"
  console_tail
fi
if guest_run "${MK_READ_B}" "${CMD_READ_B}" 240; then
  if [ "$(marker_count "${MD5_B}")" -eq 0 ]; then
    ok "penanda kedua TIDAK ada (md5-nya nol kemunculan): tulisan resume pertama tidak bocor"
  else
    fail "penanda kedua muncul: resume kedua melihat tulisan resume pertama"
  fi
else
  fail "tidak ada jawaban dari guest untuk pembacaan penanda kedua"
  console_tail
fi
[ "$(sha256sum "${RT}/snapshots/snap-a.cow" | cut -d' ' -f1)" = "${SNAP_SHA}" ] \
  && ok "snapshot tetap utuh setelah dua resume" || fail "snapshot berubah setelah dua resume"

echo "== langkah 6: daftar, penolakan image berbeda, hapus (C3/C4) =="
UML4TERMUX_RUNTIME="${RT}" "${BIN}" snapshots >"${OUT}/snapshots.log" 2>&1
grep -q '^snap-a' "${OUT}/snapshots.log" && ok "'snapshots' mendaftar snap-a" || fail "snap-a tidak terdaftar"
instance_down
cp -f "${W}/img.ext4" "${W}/img-other.ext4"
touch -d '2020-01-01 00:00:00' "${W}/img-other.ext4"
PID_BEFORE_REFUSE="$(sed -n 's/^PID=//p' "${W}/state/instances/${NAME}.env" 2>/dev/null)"
UML4TERMUX_RUNTIME="${RT}" "${BIN}" up --name "${NAME}" --image "${W}/img-other.ext4" \
  --mem "${MEM}" --ssh-port "${SSH_PORT}" --from snap-a --timeout 30 >"${OUT}/refuse.log" 2>&1
rc_refuse=$?
if [ "${rc_refuse}" -ne 0 ]; then ok "resume dengan image berbeda DITOLAK (rc=${rc_refuse})"; else fail "image berbeda diterima"; fi
if grep -q 'recorded: size' "${OUT}/refuse.log" && grep -q 'now     : size' "${OUT}/refuse.log"; then
  ok "pesan penolakan menyebut angka yang dicatat dan yang terlihat"
else
  fail "pesan penolakan tidak menyebut angka"; sed -n '1,8p' "${OUT}/refuse.log" | sed 's/^/    /'
fi
grep -q 'different backing image' "${OUT}/refuse.log" \
  && ok "pesan menyebut sebabnya (backing image berbeda)" || fail "pesan penolakan tidak jelas"
PID_NOW="$(sed -n 's/^PID=//p' "${W}/state/instances/${NAME}.env" 2>/dev/null)"
if [ -z "${PID_NOW}" ] || [ ! -d "/proc/${PID_NOW}" ] || [ "${PID_NOW}" = "${PID_BEFORE_REFUSE}" ]; then
  ok "penolakan terjadi SEBELUM boot (tidak ada daemon baru)"
else
  fail "daemon baru (${PID_NOW}) sempat hidup walau resume ditolak"
fi

UML4TERMUX_RUNTIME="${RT}" "${BIN}" snapshot --rm snap-a >"${OUT}/rm.log" 2>&1
[ ! -e "${RT}/snapshots/snap-a.cow" ] && [ ! -e "${RT}/snapshots/snap-a.meta" ] \
  && ok "snapshot --rm membersihkan COW + metadata" || fail "--rm tidak membersihkan"

echo "== langkah 7: teardown bersih =="
instance_down
sleep 3
# This run's leftovers only: a device-wide count reports the operator's own runit
# guest (observed: it did, and the count was printed as a failure of this run).
left=0
pid_reg="$(sed -n 's/^PID=//p' "${W}/state/instances/${NAME}.env" 2>/dev/null)"
[ -n "${pid_reg}" ] && [ -d "/proc/${pid_reg}" ] && left=$((left + 1))
for p in /proc/[0-9]*; do
  [ -r "${p}/cmdline" ] || continue   # the pid may exit mid-scan
  cmd="$(tr '\0' ' ' < "${p}/cmdline" 2>/dev/null)" || continue
  case "${cmd}" in *"${W}/"*) left=$((left + 1)) ;; esac
done
device_left=0
for p in /proc/[0-9]*; do
  exe="$(exe_of "${p#/proc/}")" || continue
  case "${exe}" in *linux-bionic*|*uml4termuxd*|*gvproxy*) device_left=$((device_left + 1)) ;; esac
done
[ "${left}" -eq 0 ] && ok "0 proses tersisa milik run ini" || fail "${left} proses milik run ini masih hidup"
echo "     catatan: proses uml se-device sekarang = ${device_left} (layanan operator ikut terhitung)"
IMG_SHA_AFTER="$(sha256sum "${W}/img.ext4" | cut -d' ' -f1)"
[ "${IMG_SHA_BEFORE}" = "${IMG_SHA_AFTER}" ] \
  && ok "image dasar tidak berubah (sha256 sama) -- tulisan guest masuk ke COW" \
  || fail "image dasar BERUBAH: ${IMG_SHA_BEFORE:0:12} -> ${IMG_SHA_AFTER:0:12}"

[ -e "${CONSOLE}" ] && cp -f "${CONSOLE}" "${OUT}/console/boot-${boot_n}-final.log" 2>/dev/null || true
env -u LD_LIBRARY_PATH python3 - "${OUT}" "${IMG_SHA_BEFORE}" "${SNAP_SHA}" "${rc_total}" "${device_left}" <<'PY'
import json, sys
out, img_sha, snap_sha, rc, dev = sys.argv[1:6]
json.dump({"check": "C snapshot & resume (device, real boots)",
           "base_image_sha256": img_sha, "snapshot_cow_sha256": snap_sha,
           "device_wide_processes_after_run": int(dev),
           "passed": rc == "0"},
          open(f"{out}/c-snapshot.json", "w"), indent=1)
PY
echo "c: hasil -> ${OUT}/c-snapshot.json"
[ "${rc_total}" -eq 0 ] && echo "C: OK" || echo "C: ADA KEGAGALAN"
exit "${rc_total}"