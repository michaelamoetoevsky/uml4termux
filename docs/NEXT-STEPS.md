# Next steps — arah pengembangan pasca v0.5.0

Status dasar (terverifikasi, lihat `docs/ROADMAP-0.4.md` dan `evidence/`):
Docker berjalan penuh di UML arm64 dalam Termux tanpa root; daemon biner
menjalankan/mengawasi guest; boot ephemeral COW; multi-guest; kernel
byte-reproducible; rilis v0.5.0 terbit dengan 6 asset.

Dokumen ini menetapkan **tujuh arah** (A–G) pengembangan berikutnya. Arah G
lahir dari usulan pengguna (runtime/supervisor sendiri) dan memuat penilaian
jujur berikut bentuk yang direkomendasikan. Aturan main:

1. Setiap arah punya **kriteria lulus yang bisa diuji** dan **evidence**
   yang harus dihasilkan (schema 1.1) — bukan klaim naratif.
2. Urutan pengerjaan mengutamakan yang **nol-risiko** lebih dulu.
3. Tidak ada perubahan pada janji keamanan: tanpa root host, tanpa `hostfs`,
   tanpa membuka port ke LAN kecuali diminta.

---

## A. Performa — mengukur dan mengecilkan overhead

**Tujuan.** Mengetahui secara kuantitatif di mana UML kalah dari native, dan
apakah kernel upstream terbaru memperbaiki salah satunya.

**Fakta yang sudah terdokumentasi** (`docs/FORENSICS.md`): page fault ~7,6×
native per fault (1,77× per byte pada 16 KB); mode ptrace ~10× lebih buruk per
syscall dibanding seccomp; beban syscall-heavy paling menderita.

**Lingkup.**
- A1. Benchmark **kernel pin `169b17ff` vs HEAD `32e5e10b81d8`** pada tiga
  profil: (i) syscall-heavy (`fork`+`exec` loop kecil), (ii) page-fault-heavy
  (mmap + baca 512 MB berpola acak), (iii) I/O sekuensial (`dd` 1 GB).
  Hipotesis spesifik: commit upstream *"give libc back what it allocated
  inside physical memory"* (`257d23ee`) berpotensi menurunkan biaya fault;
  uji apakah terlihat di angka.
- A2. Inventaris opsi kernel/UML yang relevan (`CONFIG_UML_*`, mode
  interception, `vec0` depth/gro, ukuran `mem=`) dan uji satu per satu
  terhadap profil yang sama — hanya yang terbukti berpengaruh yang masuk
  dokumentasi.

**Harness sudah siap dan terbukti jalan** (bukan rencana di atas kertas):

```sh
# sekali: bangun kernel HEAD dari sumber yang sama (input ksrc_ref/ksrc_repo)
gh workflow run kernel-build.yml -f ksrc_ref=32e5e10b81d8 \
   -f ksrc_repo=https://github.com/zalexdev/linux-um-arm64
bash bench/fetch-head-kernel.sh <run_id> $TMPDIR/bench-assets   # -> linux-head

# kampanye: 2 kernel x 3 run, ketiga profil, median + rentang
UML4TERMUX_HOME=$TMPDIR/bench-assets UML4TERMUXD_BIN=$PWD/bin/uml4termuxd \
UML4TERMUXD_MEM=2048M bash bench/bench.sh \
  --kernels "pin=linux-bionic,head=linux-head" --runs 3 \
  --image $TMPDIR/bench-assets/debian-docker.ext4 --out bench/out/campaign-1
```

`bench/bench.sh` menyalakan guest nyata lewat launcher (tanpa runit), menunggu
`BENCH_DONE` dari guest sendiri, dan menulis `summary.json` + `summary.md`.
Profil disk **read-only** (`dd if=/dev/ubda`) supaya benchmark tak pernah
menyentuh image atau baseline digest. `BENCH_SCALE=0.1` untuk kalibrasi cepat
(terbukti: satu run 0.1 selesai <1 menit), `=1` untuk angka kampanye.

**Kriteria lulus.** Tabel sebelum/sesudah dengan ≥3 run per sel, median +
rentang, dan pernyataan jelas: "HEAD lebih cepat X% / lebih lambat / setara"
pada tiap profil. Keputusan pin rilis berikutnya mengikuti hasil ini.

**Kalibrasi awal (pin, skala 0.1, 1 run) — bukan hasil kampanye.** forkexec
1500/10 = 150 exec: 4900 ms; pagefault 51,2 MB bs=4k: 380 ms; diskread 102,4 MB
dari ubda: 720 ms. Angka ini hanya untuk memastikan harness bekerja dan
mengukur biaya per run (~80 s pada skala 1), bukan untuk memutuskan pin.

**Kampanye pertama selesai (7 boot guest, 2026-10-30) — hasilnya DIREKSIONAL,
bukan dasar keputusan.** Bukti: `evidence/20261030-bench-pin-vs-head.json`.
Atribusi kernel diambil dari `uname` guest sendiri tiap run
(`g169b17ff3f66` = pin, `g32e5e10b81d8` = HEAD).

| kernel | profil | run | median | min | max | sebaran |
|---|---|---|---|---|---|---|
| pin  | forkexec  | 4 | 44.625 ms | 35.160 | 50.180 | 33,7% |
| head | forkexec  | 3 | 43.430 ms | 28.220 | 51.050 | 52,6% |
| pin  | pagefault | 4 | 1.545 ms  | 1.400  | 2.620  | 79,0% |
| head | pagefault | 3 | 1.180 ms  | 1.120  | 3.760  | 223,7% |
| pin  | diskread  | 3 | 6.169 ms  | 5.010  | 13.040 | 130,2% |
| head | diskread  | 3 | 5.580 ms  | 3.410  | 127.150| 2217,6% |

- **forkexec: SETARA** (selisih <5%). Angka "HEAD 15% lebih cepat" pada
  ringkasan antara muncul karena jumlah run belum sama (pin 3 vs head 3, lalu
  pin 4) — koreksi ini yang benar.
- **pagefault: HEAD lebih cepat ~31% menurut median**, dan arahnya konsisten
  (min HEAD 1.120 ms < min pin 1.400 ms). Ini **sejalan** dengan hipotesis A1
  (upstream `257d23ee` menurunkan biaya fault) — tapi **belum konfirmasi**:
  sebaran sel 79%/224% lebih besar daripada selisihnya.
- **diskread: tak konklusif.** Median mendukung HEAD, satu titik 127 s di sel
  HEAD membuat rentangnya tak berguna.
- Catatan jujur yang menentukan: kampanye berjalan saat device **sibuk**
  (load average 16–20). Satu run dingin (pin-1) bahkan tak menyelesaikan profil
  disk di dalam jendela tunggu dan harus diulang dengan `BENCH_WAIT=900`.

**Kampanye kedua — device tenang, 5 run/sel, 1 run pemanasan dibuang
(2026-10-30).** Layanan runit `uml4termux` dihentikan sementara (disetujui
operator) dan tak ada proses uml4termux lain yang hidup (diverifikasi lewat
resolusi `/proc/<pid>/exe`, bukan pencocokan cmdline). Bukti:
`evidence/20261030-bench-pin-vs-head-clean.json`.

| kernel | profil | run | median | min | max | sebaran |
|---|---|---|---|---|---|---|
| pin  | forkexec  | 5 | 30.930 ms | 27.420 | 39.940 | 40,5% |
| head | forkexec  | 5 | 34.320 ms | 25.070 | 42.790 | 51,6% |
| pin  | pagefault | 5 | 3.530 ms  | 2.010  | 9.310  | 206,8% |
| head | pagefault | 5 | **1.700 ms** | 1.440 | 12.020 | 622,4% |
| pin  | diskread  | 5 | 5.410 ms  | 3.970  | 33.830 | 551,9% |
| head | diskread  | 5 | 6.800 ms  | 4.720  | 20.090 | 226,0% |

- **pagefault: arah BERULANG** — HEAD lebih cepat di kedua kampanye (31% pada
  kampanye berisik, 107,6% pada kampanye tenang). Arahnya konsisten; besarannya
  tidak. Ini yang diprediksi hipotesis A1 (`257d23ee` menurunkan biaya fault).
- **forkexec: setara** — selisih 9,9% dengan sebaran sel 40–52%, jadi di dalam
  kebisingan (kampanye pertama menyebut sel yang sama "setara" juga).
- **diskread: masih tak konklusif** — arahnya **berbalik** antar kampanye
  (berisik: HEAD unggul; tenang: pin unggul 20,4%), sebaran >200% di keduanya.
  Arah yang tak stabil = tak ada verdict.
- **Kebisingan intrinsik belum hilang**: bahkan di device tenang, sel HEAD
  pagefault bergerak 1.440 → 12.020 ms (8×). Jadi resep "device tenang" saja
  tidak cukup; kampanye berikutnya butuh lebih banyak run + penjaga stabilitas
  per run.
- **Keputusan: pin tetap `169b17ff`.** Dua dari tiga profil masih noise-bound
  dan belum ada rilis HEAD, jadi memindahkan pin berarti menukar kernel yang
  sudah divalidasi di device dengan kernel yang belum dirilis, atas dasar satu
  profil yang berulang.

**Kampanye berikutnya (bila diperlukan).** Device tenang; ≥10 run/sel; buang 2
run pemanasan; tolak sel yang sebarannya >50% alih-alih melaporkan mediannya.

**Kalibrasi awal (pin, skala 0.1, 1 run) — bukan hasil kampanye.**

**Biaya.** 1 sesi benchmark (perlu baterai cukup). **Risiko.** Nol (hanya baca
dan ukur; tak mengubah jalur rilis).

---

## B. Stabilitas operasional — soak v2 di arsitektur baru

**Tujuan.** Membuktikan daemon v0.5.0 (bukan skrip lama) tahan lama.

**Konteks.** Soak 60 menit / 43 siklus yang ada dijalankan **sebelum** daemon
biner dan COW ada. Jadi belum ada bukti untuk arsitektur sekarang.

**Lingkup.**
- B1. Soak 2 jam: siklus boot → `docker run` → uji → `stop` bersih, dengan
  COW ephemeral, sambil mencatat RSS daemon/kernel tiap siklus.
- B2. Dua guest paralel (multi-instance) selama ≥60 menit untuk mendeteksi
  saling-ganggu (socket, memori, phantom-killer Android).
- B3. `sv restart` daemon di tengah soak → verifikasi re-apply exposure dan
  tidak ada proses yatim.

**Kriteria lulus.** 0 kegagalan boot; RSS daemon stabil (tanpa tren naik);
0 proses yatim pasca-restart; exposure tetap berfungsi setelah restart.
**Evidence.** Satu record schema 1.1 + log mentah + tabel siklus.

**Biaya.** 2–3 jam pasif (device menyala). **Risiko.** Nol.


**Hasil B3 — LULUS, dan ia menemukan tiga cacat nyata.** B3 bukan formalitas:
menjalankannya membongkar masalah yang tak terlihat pada pemakaian biasa.
Bukti: `evidence/20261030-soak-b3-restart.json`.

| Cacat | Gejala | Perbaikan |
|---|---|---|
| Daemon C mengabaikan `UML4TERMUXD_GVPROXY_SSH_PORT` | instance kedua / restart di sebelah gvproxy lama mati `listen tcp 127.0.0.1:2222: bind: address already in use` | daemon C kini meneruskan `-ssh-port=<n>` (daemon Rust sudah melakukannya — ini divergensi perilaku) |
| Anak yatim saat daemon di-`SIGKILL` | gvproxy tetap hidup memegang port host → instance baru tak bisa bind, dan `expose` berikutnya dijawab gvproxy **HTTP 500** | `prctl(PR_SET_PDEATHSIG, SIGTERM)` di kedua cabang anak (gvproxy + kernel guest) |
| Path socket unix dipotong diam-diam | `strncpy` memotong path >107 byte → daemon bind/connect ke path yang berbeda dari yang dilaporkannya; gvproxy mati `bind: invalid argument` | `sockpath_too_long()` menolak keras + launcher memeriksa panjang runtime dir di depan (`exit 64` dengan angka) |

Hasil akhir B3: exposure `18131->8123` diuji **end-to-end** (curl host → banner
container), daemon di-`SIGKILL`, forwarder ikut mati, instance dihidupkan ulang
adapter plain (pid 7573 → 10336), lalu **curl yang sama mencapai container lagi**
(exposure di-*re-apply*, bukan dibuat ulang manual), teardown 0 proses.

**Catatan pengukuran.** `/proc/net/tcp` **tidak terbaca** oleh app Termux, jadi
"apakah port LISTEN?" harus dijawab dengan permintaan nyata — bukan parsing
`/proc`. Guest yang mematikan diri setelah tugasnya membuat daemon keluar normal
(exit 0 = sesi selesai), sehingga uji restart memakai `docker-init.sh` dengan
`GUEST_LIFETIME=0`.

**Harness sudah tersedia.** `soak/soak.sh` menjalankan siklus
boot → dockerd → `docker run` → stop bersih dengan **COW ephemeral** (launcher
memasangnya otomatis), mencatat RSS daemon + RSS kernel guest tiap siklus ke
`cycles.jsonl`, lalu `soak/summarise.py` menilai: 0 siklus gagal, 0 proses
tertinggal (dihitung lewat resolusi `/proc/<pid>/exe`), image tak tersentuh
(sha **dan** mtime sebelum/sesudah), dan tren RSS (median sepertiga awal vs
sepertiga akhir). `--parallel 2` untuk B2. B3 punya skrip sendiri,
`soak/restart-check.sh`, karena ia butuh gvproxy + port host nyata: kill daemon
di tengah soak → restart lewat adapter plain → verifikasi exposure di-*re-apply*
dan nol proses yatim.

---

## C. Snapshot & resume — state guest yang bisa dikembalikan

**Tujuan.** Fitur pembeda: "coba sesuatu, lalu kembali ke kondisi awal dalam
hitungan detik" — memanfaatkan COW yang sudah terbukti.

**Lingkup.**
- C1. `uml4termuxd snapshot <label>`: hentikan guest dengan bersih (kanal
  console), lalu simpan COW sebagai `snapshots/<label>.cow` + metadata
  (timestamp, ukuran image, digest image dasar, uname guest).
- C2. `uml4termuxd boot --from=<label>`: boot memakai COW tersimpan (state
  lanjut) atau COW baru (state bersih).
- C3. `uml4termuxd snapshots` (daftar) + `snapshot --rm <label>` + kebijakan
  rotasi (mis. simpan N terakhir).
- C4. Verifikasi integritas: digest image dasar dicatat; menolak resume bila
  image dasar berubah (COW UML menyimpan mtime — jadikan pemeriksaan eksplisit).

**Kriteria lulus.** Snapshot → ubah state di guest (tulis file) → resume →
file masih ada; lalu resume snapshot yang sama dua kali → kedua boot identik
(tidak saling merusak); resume pada image dasar berbeda → ditolak dengan pesan
jelas.

**Biaya.** 1–2 sesi. **Risiko.** Rendah (fitur baru, jalur lama tak berubah).

---

## D. Ekosistem & aksesibilitas

**Tujuan.** Membuat uml4termux bisa dipakai orang lain tanpa harus membaca
seluruh dokumen forensik.

**Lingkup.**
- D1. **Varian glibc**: build kernel+daemon untuk `aarch64-linux-gnu` selain
  bionic → bisa jalan di Linux server/CI, bukan hanya Termux. (Stub dan
  daemon saat ini bionic-specific.)
- D2. **Paket Termux**: ajukan `termux-packages` (build.sh sudah ada di
  `packaging/termux/`), lengkap dengan digest rilis.
- D3. **Panel WebUI**: halaman status memakai `GET /status` daemon
  (`UML4TERMUXD_HTTP`) — daftar guest, exposure, tombol start/stop.
- D4. **Contoh nyata**: 2–3 resep (nginx + sqlite, registry lokal, build
  service ringan) beserta angka performa dari arah A supaya ekspektasi jujur.

**Kriteria lulus.** D1: biner glibc boot di runner CI Linux aarch64. D2: PR
dibuka dengan build bersih. D3: panel menampilkan state nyata dari daemon.
**Biaya.** Sedang. **Risiko.** Rendah.

---

## E. Keamanan & isolasi

**Tujuan.** Menetapkan model ancaman tertulis dan menutup celah yang
realistis — terutama bila image pihak ketiga dijalankan.

**Lingkup.**
- E1. **Threat model** tertulis: apa yang dilindungi (data Termux, kredensial
  host) dan apa yang TIDAK (guest root = root di dalam guest; `hostfs` tabu).
- E2. **Verifikasi aset**: tanda tangan rilis (minisign/cosign) selain digest;
  `fetch` memverifikasi tanda tangan sebelum menjalankan biner.
- E3. **Pengerasan daemon**: socket 0600 (sudah), tolak koneksi non-pemilik,
  rate-limit `exec`, audit log perintah yang dijalankan.
- E4. **Pembatasan guest**: dokumentasikan + uji batas `mem=`, `ncpus=`,
  `io.max` (kini terbukti berfungsi) sebagai kontrol sumber daya per guest.

**Kriteria lulus.** E2: `fetch` menolak aset dengan tanda tangan salah walau
digest cocok. E3: koneksi dari uid lain ditolak (uji dengan `su`). E4: tabel
batas yang benar-benar ditegakkan di device.
**Biaya.** Sedang. **Risiko.** Rendah.

---

## F. Hulu (upstream) — kontribusi tanpa ketergantungan

**Fakta.** Issue `zalexdev/linux-um-arm64#4` masih **open, 0 komentar** sejak
27 Okt; upstream tidak menambah commit sejak 17 Okt. Port kini sehat (HEAD
kompilasi + boot — lihat arah C4 di roadmap 0.4).

**Strategi.** Jangan menunggu. Dua jalur paralel:
- F1. **Mandiri**: fork + pin tetap jalur rilis (status quo). Keuntungan:
  tak ada ketergantungan; kerugian: kita menanggung patch sendiri.
- F2. **Kontribusi kecil-spesifik**: kirim patch yang jelas manfaatnya ke
  hulu — mis. dukungan build bionic/Termux, perbaikan stub `exec`, dokumentasi
  cara build dengan NDK. Satu patch per PR, dengan bukti CI dari repo ini.

**Kriteria lulus.** F2: minimal satu PR terkirim dengan deskripsi + bukti
(hijau di CI kita). Bila tak direspons dalam 30 hari, tetap jalur F1.
**Biaya.** Rendah–sedang. **Risiko.** Sedang (ketidakpastian hulu) — karena
itu F1 selalu menjadi fallback, bukan taruhan.

---

## G. Runtime mandiri — supervisor, service, socket, daemon sendiri

**Usulan asal.** uml4termux punya supervisor service, service, D-Bus, socket,
daemon, dan runtime sendiri — tidak mengandalkan runit/termux-services.

**Penilaian jujur: arahnya benar, tapi usulannya perlu dibentuk ulang.** Tiga
dari enam komponen yang disebut **sudah ada dan sudah terbukti**; dua
sebaiknya ditolak eksplisit; satu (launcher) justru inti nilainya.

### Yang sudah ada — jangan dibangun ulang

Daemon (Rust, parity 6 baris vs C) sudah menjadi supervisor dari tumpukan
*dalam*:

| Kemampuan | Bukti |
|---|---|
| Kebijakan restart (backoff, batas 5; exit 0 = sesi selesai; 126/127 = menyerah) | tes + soak 8/8 siklus berdisk |
| Shutdown berjenjang: konsol 20 s → SIGTERM → SIGKILL | teardown grup gvproxy terbukti (pid 26934 hilang) |
| State file atomik + socket kontrol 0600 | parity byte-identik dengan daemon C |
| Registry exposure + re-apply saat start | E2E: `expose 18124→8123`, inbound `gvproxy-bess-ok` |
| Endpoint health HTTP | parity body byte-identik |

Jadi "daemon + socket + runtime" **bukan pekerjaan baru** — itu hasil migrasi
Rust yang sedang berjalan. Sisa yang benar-benar belum ada: **launcher/host
manager** (yang memiliki siklus hidup daemon), **registry multi-instance**,
**manajemen log milik sendiri**, dan **kontrak launcher yang terdokumentasi**.

### Batas yang tidak bisa dilewati (fakta, bukan preferensi)

1. **Tidak ada PID 1 di Android.** init milik Android tidak bisa digantikan;
   proses apa pun tetap lahir di dalam sandbox app. "Independen dari runit"
   paling jauh berarti *independen dari konvensi termux-services*, bukan
   independen dari hook boot. Launcher tetap butuh Termux:Boot, shell, unit
   systemd, atau s6 — dan runit hanyalah salah satunya.
2. **Phantom process killer (Android 12+): 32 proses anak** untuk app latar.
   Mengganti runit tidak menghindari batas ini. Supervisor kita harus **lebih
   hemat proses**, bukan lebih banyak — D-Bus daemon + bus justru menambahnya.
3. **Disiplin bukti tidak boleh turun.** Supervisor milik sendiri = suite tes
   dan gate evidence milik sendiri; tanpa itu properti yang membuat repo ini
   kredibel hilang.
4. **Satu supervisor per lapisan.** runit mengawasi daemon *dan* daemon
   mengawasi guest = dua supervisor, satu terlalu banyak. Yang benar: daemon
   mengawasi tumpukan guest; lapisan atas hanya menjaga daemon tetap hidup.

### Bentuk yang direkomendasikan

- **G1. Kontrak runtime stabil — SELESAI.** `docs/RUNTIME-CONTRACT.md`
  (v1) + perintah `protocol` di kedua daemon (parity byte-identik, gate 7 baris)
  + `tests/test-runtime-contract.sh` (22 asersi × 2 implementasi, dijalankan
  `ci/local-ci.sh` dan CI). Protokol kontrol diberi versi (v1),
  path socket, skema state file, exit code, dan definisi *ready* ditulis
  sebagai kontrak (bukan tersirat di kode). Gate: contract test.
- **G2. `uml4termux up|down|status|logs` tanpa runit — SELESAI.**
  `lib/launch.sh` menjalankan daemon langsung (tanpa `sv`/runsvdir); kesiapan
  mengikuti kontrak §5 (socket + `protocol` + fase `running`, diputar bukan
  `sleep` tetap); `up --foreground` adalah kail adapter untuk runit/systemd/s6.
  Gate `tests/test-launcher.sh`: seluruh siklus dengan **shim `sv`/`runsv`/
  `runsvdir`/`svlogd` yang gagal keras di depan PATH** + cek statis bahwa
  `lib/launch.sh`/`lib/registry.sh` tidak menyebut runit di kode.
- **G3. Manajer multi-instance — SELESAI.** `lib/registry.sh` menyimpan satu
  catatan per instance (`$UML4TERMUX_STATE_DIR/instances/<name>.env`), dan
  `up` **menolak** melanggar tiga invarian: satu guest per image (`F_SETLK`),
  satu gvproxy per port ssh host, satu direktori runtime per instance —
  ketiganya dulu hanya peringatan dokumen. Port ssh dipilih otomatis dari
  daftar bebas (2222, 12222–12229). Catatan basi dibersihkan `ls`
  (liveness = pid hidup **dan** socket menjawab handshake).
- **G4. Layout log & state sendiri — SELESAI.** `lib/logs.sh` merotasi
  `daemon.log` / `uml-console.log` / `bess.sock.gv.log` dengan **copy+truncate**
  (inode dipertahankan, jadi penulis yang memegang berkas tidak "pindah" ke
  generasi lama seperti pada rename), retensi `UML4TERMUX_LOG_KEEP` (default 3),
  batas `UML4TERMUX_LOG_MAX_BYTES` (default 10 MiB). Dipanggil `up` sebelum
  setiap start dan `uml4termux rotate [--all]` untuk tick supervisor/cron.
  Gate: `tests/test-log-rotation.sh` (14 asersi, tanpa daemon).
- **G5. Adapter launcher — SELESAI.** `packaging/adapters/{systemd,s6,plain,runit}`
  semuanya mengeksekusi kail yang sama (`up --foreground`); hanya adapter runit
  yang menyebut runit. `plain/supervise.sh` dibuktikan **fungsional**: setelah
  daemon di-SIGKILL ia menyalakan ulang dengan pid baru (15466 → 15544), dan
  setelah `down` bersih (exit 0) ia berhenti, bukan berputar.
  Gate: `tests/test-adapters.sh` (statis + fungsional; `systemd-analyze verify`
  dijalankan di CI).
- **G6. (Opsional) facade D-Bus** — feature-gated, mati secara default,
  memetakan `status/up/down` ke session bus untuk integrasi desktop.

### Yang ditolak (jangan dijanjikan)

- **D-Bus di jalur kritis.** Tidak ada konsumen di Android; menambah dependensi
  daemon + protokol untuk data yang socket unix + protokol baris sudah
  melayani, dan sudah punya parity test. Boleh sebagai facade opsional (G6),
  tidak boleh jadi syarat agar uml4termux hidup.
- **Menjadi PID 1 / menggantikan init.** Lihat batas 1.
- **Mereimplementasi semantik runsv** (ordering, dependensi, readiness antar
  service) dari nol — daemon sudah menangani yang kita butuhkan.
- **Menghapus jalur runit.** Ia tetap adapter pertama dan tetap yang
  terverifikasi di device ini; menghapusnya akan merusak pengguna yang ada.

**Bukti device (G4–G5).** `evidence/20261030-log-rotation-adapters.json` — dua
capability `ok=false` di sana adalah **cacat produk yang ditemukan lewat
pekerjaan ini**: daemon C mewariskan socket listener ke anaknya (anak yatim
memegang socket → klien menggantung setelah daemon dibunuh) dan
`up --foreground` tidak menulis catatan registry (instance milik supervisor tak
terlihat oleh `status`/`down`). Keduanya sudah diperbaiki.

**Bukti device (G1–G3).** `evidence/20261030-launcher-instances.json` — boot
guest nyata lewat `up` (kernel ter-pin, image privat, ssh port 12224), marker
`WEB_UP_MARKER`, `root_mounted`, inbound `gvproxy-bess-ok`, teardown bersih,
dan **shim runit 0 kali dipanggil**; dua capability sengaja dicatat `ok=false`
sebagai batas + regresi yang ditemukan sendiri (umur selftest 30 s; argv guest
kosong akibat refactor).

**Kriteria lulus.** G1: kontrak tertulis + dites. G2: satu boot penuh tanpa
runit, evidence terekam. G3: 2 instance bersamaan tanpa tabrakan. G4: rotasi
log terbukti. G5: satu adapter non-runit hijau di CI.
**Biaya.** Sedang–tinggi (supervision itu halus). **Risiko.** Sedang, dengan
satu syarat: **jangan sampai ada dua supervisor**. Nilai terbesarnya bukan
"lepas dari runit" melainkan **portabilitas** — artefak yang sama bisa dipakai
di host non-Termux (systemd/s6/plain, container, runner CI) dan koordinasi
multi-instance yang hari ini masih berupa peringatan di dokumen.

---

## Urutan yang direkomendasikan

| Urut | Item | Alasan | Risiko |
|---|---|---|---|
| **berikutnya** | A (benchmark pin vs HEAD) | Menentukan pin rilis berikutnya; data sudah setengah tersedia | Nol |
| 2 | B (soak v2) | Arsitektur berubah (daemon + COW) → butuh bukti baru | Nol |
| 3 | C (snapshot/resume) | Fitur pembeda termurah yang memanfaatkan COW | Rendah |
| 4 | E (keamanan) | Prasyarat sebelum orang lain menjalankan image | Rendah |
| 5 | D (ekosistem) | Perluasan audiens setelah fondasi stabil | Rendah |
| 6 | F (hulu) | Paralel, tanpa menahan apa pun | Sedang |
| ~~7~~ | ~~G (runtime mandiri)~~ **SELESAI G1–G5** | Portabilitas ke host non-Termux + penegakan invarian multi-instance | — |
| 8 | G6 (facade D-Bus, opsional) | Hanya bila ada konsumen nyata; bukan jalur kritis | Rendah |

## Di luar lingkup (jangan dijanjikan)

- **Mengganti kernel/port UML dengan bahasa lain.** UML adalah sub-arsitektur
  kernel Linux (C). Yang bisa ditulis ulang hanyalah *userspace*: daemon, CLI,
  tooling.
- **systemd/OpenRC sebagai PID 1** di guest (terbukti hang).
- **Docker rootless di dalam guest** (butuh pemetaan UID yang tidak didukung
  port ini); dockerd tetap root-di-dalam-guest.
- **Menjadi PID 1 / menggantikan init Android.** Sandbox app tidak
  mengizinkan itu; arah G karena itu berbicara soal launcher, bukan boot.
- **D-Bus sebagai dependensi wajib.** Hanya boleh sebagai facade opsional.
- **`hostfs`** untuk kode tak tepercaya.
- **Menyamai performa native** — batas arsitektural, bukan bug.