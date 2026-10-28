# Roadmap 0.4 — mobilitas, kapabilitas, aksesibilitas + daemon

> Dibuka 28 Okt 2026 setelah rilis 0.3.0 (CI kernel diadopsi, repo publik).
> Urutan eksekusi mengikuti prioritas di bawah; item bertanda ✔ selesai.

## A. `uml4termuxd` — daemon binary (prioritas tertinggi)

Runtime UML sebagai **program binary** (C, bionic, tanpa dependency runtime),
bukan lagi kumpulan shell exec:

- [ ] A1 ✔ **Skeleton + smoke test**: `src/uml4termuxd.c` — arg parsing,
  control socket unix (`$UML4TERMUX_RUNTIME/daemon.sock`, protokol line-JSON),
  client `status|stop`, fork/exec/waitpid supervisor dengan restart policy +
  backoff, `--selftest` (supervise `/bin/sleep` — tanpa boot UML).
- [ ] A2 ✔ **Spawn UML nyata** (inti): config via `UML4TERMUXD_{KERNEL,STUB,
  IMAGE,INITRAMFS,MEM,NCPUS}`, console guest → `$UML4TERMUX_RUNTIME/
  uml-console.log`, `status` + kernel/mem/ncpus/uptime, stop SIGTERM→SIGKILL
  (5 s). Semantik sesi teruji di device: exit 0 (guest `poweroff` setelah
  payload) = `completed`, TIDAK di-restart; crash = restart backoff (cap 5);
  exec gagal (126/127) = fatal. CI job `daemon-c` hijau (compile -Werror +
  selftest runner).
- [ ] A2b ✔ **Guest exec via console PTY**: `exec <cmd...>` menulis baris
  `exec:` yang dievaluasi agen console guest (docker-init.sh), output ke log
  konsol dengan marker `__EXEC_<n>_BEGIN__/DONE_$?`; `console [n]` tail log.
  Teruji device: `uname -a` (kernel aarch64 CI) dan `docker ps` (listing
  container web) dari dalam guest.
- [ ] A3 ✔ **Integrasi gvproxy (lifecycle)**: `UML4TERMUXD_GVPROXY`(+`_BESS`)
  → daemon spawn gvproxy (proot /etc bind auto-di Termux), tunggu socket bess,
  pasang `vec0:transport=bess` di cmdline kernel, stop saat guest selesai /
  daemon berhenti. Teruji: boot docker penuh ~70 s di bawah daemon, shutdown
  bersih tanpa proses yatim. Sisa: registry expose port persisten (A3b).
- [ ] A4 **Runit**: `$PREFIX/var/service/uml4termux/run` → `exec uml4termuxd
  daemon`; `uml4termux service` CLI bicara ke daemon, bukan lagi ke shell.
- [ ] A3b ✔ **Registry expose port persisten**: `expose <hport> <gport>` /
  `ports` via control socket; daemon memanggil API unix gvproxy langsung
  (HTTP-over-unix di C, tanpa libcurl), registry JSONL di runtime dir,
  **re-applied otomatis saat daemon restart** — teruji: expose → curl loopback
  `gvproxy-bess-ok` → restart daemon → `re-applied 1 exposure(s)` → curl
  langsung jalan lagi tanpa intervensi.
- [x] A4 ✔ **Runit**: `packaging/service/{run.uml4termuxd,log.run,
  daemon.conf.example,README.md}` — run script exec daemon (conf
  `~/.uml4termux/daemon.conf` auto-export, wake-lock, runtime dir). Teruji di
  device dengan service uji `uml4d-test`: boot guest di bawah runit, `sv down`
  → daemon exit 1 s + **0 proses yatim**. Bug ditemukan & diperbaiki: gvproxy
  via proot selamat dari kill pid tunggal (tracee proot jadi yatim) →
  shutdown kini mem-bunuh **process group** (`setsid()` + `kill(-pid)`,
  eskalasi SIGKILL berbatas waktu).
- [x] A5 ✔ **Packaging 0.4.0**: daemon bionic dibangun di `kernel-build.yml`
  (NDK clang, `-Werror`) dan ikut artifact; rilis **v0.4.0** menerbitkan
  5 asset (tarball 207 KB, `uml4termuxd`, `linux-bionic`, `stub_exe`,
  SHA256SUMS); `fetch` mengunduh daemon sebagai asset kelas satu
  (kernel,stub,daemon,disk,base); digest pin diperbarui (kernel v0.4.0
  `29180d95…`, stub byte-identical, daemon `2b13fad0…`); binary CI lulus
  selftest di device. Catatan reproducibility: hash kernel berubah antar
  build (timestamp tertanam di version string) → kandidat
  `KBUILD_BUILD_TIMESTAMP` (C5b).

## B. Mobilitas

- [x] B1 ✔ **Persistensi state lintas boot**: tercukupi oleh desain —
  konfigurasi guest = `~/.uml4termux/daemon.conf` (runit menjalankan daemon
  dengannya setiap boot), registry expose = `exposures.jsonl` yang di-reapply
  daemon saat start; `daemon.state.json` mencatat fase terakhir.
- [x] B2 ✔ **Lifecycle guest bersih + ephemeral (COW native UML)**:
  * `stop` kini menulis `sync; poweroff -f` lewat kanal console PTY (budget
    20 s) sebelum fallback SIGTERM/SIGKILL — image tetap konsisten;
    teruji: `clean poweroff landed after 1.5s`.
  * `UML4TERMUXD_COW=<path>`: boot **ephemeral** memakai COW native UML
    (`ubd0=<cow>,<backing>` — COW di depan!). Daemon menulis header COW v3
    sendiri (magic `MOOO` be, v3 packed 4128 B, bitmap reset per boot) karena
    port ini tidak membuat header sendiri. Teruji: boot matrix + boot docker
    penuh (dockerd/pull/containers) dengan hash image 3 GB **identik
    sebelum/sesudah** — semua tulisan tamu hanya menyentuh COW.
- [x] B3 ✔ **Multi-guest**: tanpa perubahan kode — seluruh state sudah
  per-instance via env (`UML4TERMUX_RUNTIME` = socket kontrol + state,
  `UML4TERMUXD_BESS` = data plane, `UML4TERMUXD_COW`, `UML4TERMUXD_MEM`);
  semua socket data plane = unix sehingga tak ada bentrok TCP. Teruji di
  device: 2 daemon × guest 256M menjalankan matriks 27 poin **simultan**
  (27/27 masing-masing), stop bersih, 0 proses yatim. Pola terdokumentasi
  di `packaging/service/daemon.conf.example`; batasan anggaran (RAM + port
  host loopback) di `docs/KNOWN-LIMITS.md`.

## C. Kapabilitas

- [x] C1 ✔ **Charging memcg**: gap 0.3.0 ("tmpfs tak tercharge") **tidak ada
  di kernel CI** — tulis 20 MiB tmpfs dalam child cgroup ter-charge penuh
  (`memory.current` +20384K; `memory.stat` file 21577728, slab 79384).
  Catatan: `CONFIG_MEMCG_KMEM` dihapus upstream sejak v5.14 (charging kmem
  melebur ke MEMCG) — di kernel 7.2 charging bersifat mutlak; diverifikasi
  lewat perilaku, tanpa rebuild config. Evidence:
  `evidence/20261029-cap11-c1-c2.json` (schema 1.1, lulus checker).
- [x] C2 ✔ **io.max retest**: node `io.max` ADA dan **diterima** pada kernel
  CI — `echo 98:0 rbps=1048576 > t2/io.max` dibaca balik
  `98:0 rbps=1048576 wbps=max riops=max wiops=max`. Jebakan sintaks
  tercatat: io.max berkunci per-device `MAJ:MIN` — penulisan `rbps=`
  telanjang ditolak EINVAL; itulah akar pengamatan "io.max ABSEN" era 0.3.0
  (diulang dengan sintaks benar = jalan). Evidence yang sama dengan C1.
- [ ] C3 **Akselerasi jaringan**: evaluasi path vector bess vs passthrough;
  ukur throughput pull/run (baseline 0.3.0 ada).
- [ ] C4 **Kernel lebih baru**: coba HEAD port setelah fix upstream `user_mode`
  (temuan #1 UPSTREAM-FINDINGS) — dengan config gap-closing yang sama.
  Status: menunggu perbaikan di repo upstream (issue #4 terkait).
- [x] C5 ✔ **Evidence checker diperkuat** (temuan review GPT #2): wajibkan path
  artefak pada tiap record, gag bila log hilang/kosong, simpan + verifikasi
  SHA-256 log mentah, dan cek marker spesifik-kapabilitas terhadap verdict.

## D. Aksesibilitas

- [ ] D1 **`uml4termuxd` CLI tunggal**: satu binary untuk daemon + client
  (status/stop/exec/ports) — menggantikan urutan perintah shell di README.
- [ ] D2 **WebUI hook**: endpoint status/health daemon untuk panel Hermes WebUI
  (port yang sama dengan registry expose).
- [ ] D3 **Dokumentasi pengguna baru**: quickstart 3 langkah (install →
  `uml4termuxd daemon` via runit → docker run), diagram arsitektur daemon.
