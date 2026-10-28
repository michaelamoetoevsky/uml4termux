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

- [ ] B1 **Persistensi state lintas boot**: registry expose port + konfigurasi
  guest dalam satu state file yang daemon baca saat start ulang (sudah
  setengah ada di supervisor shell — pindah ke daemon).
- [ ] B2 **Guest snapshot/lifecycle**: stop bersih via mconsole (`halt`),
  start ulang tanpa kehilangan image state; opsi `--ephemeral` (image sementara,
  overlay copy-on-write per boot) untuk uji tanpa menyentuh image utama.
- [ ] B3 **Multi-guest**: daemon mengelola >1 guest dengan label (matriks:
  memori HP vs mem=256M per guest; batas phantom-killer Android).

## C. Kapabilitas

- [ ] C1 **CONFIG_MEMCG_KMEM=y** di config CI (gap sisa 0.3.0: tmpfs/page-cache
  tak tercharge) → boot-test matrix ulang + evidence baru.
- [ ] C2 **io.max retest** child-cgroup (subtree_control +io) — tutup pertanyaan
  throttle blok.
- [ ] C3 **Akselerasi jaringan**: evaluasi path vector bess vs passthrough;
  ukur throughput pull/run (baseline 0.3.0 ada).
- [ ] C4 **Kernel lebih baru**: coba HEAD port setelah fix upstream `user_mode`
  (temuan #1 UPSTREAM-FINDINGS) — dengan config gap-closing yang sama.
- [ ] C5 **Evidence checker diperkuat** (temuan review GPT #2): wajibkan path
  artefak pada tiap record, gag bila log hilang/kosong, simpan + verifikasi
  SHA-256 log mentah, dan cek marker spesifik-kapabilitas terhadap verdict.

## D. Aksesibilitas

- [ ] D1 **`uml4termuxd` CLI tunggal**: satu binary untuk daemon + client
  (status/stop/exec/ports) — menggantikan urutan perintah shell di README.
- [ ] D2 **WebUI hook**: endpoint status/health daemon untuk panel Hermes WebUI
  (port yang sama dengan registry expose).
- [ ] D3 **Dokumentasi pengguna baru**: quickstart 3 langkah (install →
  `uml4termuxd daemon` via runit → docker run), diagram arsitektur daemon.
