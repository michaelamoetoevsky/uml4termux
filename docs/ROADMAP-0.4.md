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
- [ ] A2b **Guest exec via control socket** (`exec <cmd>`): kanal eksekusi ke
  dalam guest (kandidat: mconsole `config ubdN=` pasang disk perintah, atau
  konsol PTY) + `follow` log konsol.
- [ ] A3 **Integrasi gvproxy**: lifecycle gvproxy dikelola daemon (spawn/stop,
  registry expose port persisten — pindahkan logika supervisor shell ke C).
- [ ] A4 **Runit**: `$PREFIX/var/service/uml4termux/run` → `exec uml4termuxd
  daemon`; `uml4termux service` CLI bicara ke daemon, bukan lagi ke shell.
- [ ] A5 **Packaging**: binary di release 0.4.0 + dibangun di CI (runner
  ubuntu + NDK clang, target bionic — pola sama dengan kernel-build).

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
  (temuan #1 UPSTREAM-FINDINGS) — dengan config gap-closed yang sama.

## D. Aksesibilitas

- [ ] D1 **`uml4termuxd` CLI tunggal**: satu binary untuk daemon + client
  (status/stop/exec/ports) — menggantikan urutan perintah shell di README.
- [ ] D2 **WebUI hook**: endpoint status/health daemon untuk panel Hermes WebUI
  (port yang sama dengan registry expose).
- [ ] D3 **Dokumentasi pengguna baru**: quickstart 3 langkah (install →
  `uml4termuxd daemon` via runit → docker run), diagram arsitektur daemon.
