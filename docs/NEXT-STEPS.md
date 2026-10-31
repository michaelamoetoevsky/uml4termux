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

**Hasil B1 dan B2 (2026-10-30/31).** Bukti: `evidence/20261030-soak-b1.json`
dan `evidence/20261030-soak-b2.json`.

| | B1 (soak 2 jam, 1 guest) | B2 (2 guest paralel) |
|---|---|---|
| siklus | **105** | **80** (40 + 40) |
| durasi terukur | **167,4 menit** | **73,2 menit** |
| siklus gagal | **4** (#74–77) | **0** |
| container berjalan | 101/105 | 80/80 |
| tren RSS daemon | **−0,6%** (4.786 → 4.758 KB) | +1,3% (maks 5.360 / 5.448 KB) |
| proses tersisa per siklus | 0 | 0 |
| proses tersisa se-device setelah run | **0** | **0** |
| image dasar | sha **dan** mtime tak berubah di semua siklus | idem |
| verdict | `partial` | `pass` |

**Empat kegagalan B1 bukan cacat daemon, dan sebabnya dicatat.** Antara siklus
73 dan 78, symlink `bench-assets/linux-bionic` menunjuk ke direktori kerja yang
baru dihapus saat pembersihan, sehingga launcher benar-benar menolak start
(`asset 'kernel' not present`). Bukti bahwa itu bukan bug intermiten: setelah
kernel pin dipasang ulang sebagai **berkas nyata** (sha `6970ada5…` cocok dengan
pin rilis), **19 siklus berikutnya bersih berturut-turut**, dan B2 (80 siklus,
dua guest sekaligus) tidak gagal sekali pun. Angka 101/105 dan verdict `partial`
tetap ditulis apa adanya — menyembunyikannya akan membuat laporan ini tak bisa
dipakai.

**B1 diulang bersih (2026-10-31) — verdict `pass`.** Bukti:
`evidence/20261031-soak-b1-clean.json`. Sebab empat kegagalan di atas sudah
diperbaiki di harness (precheck aset memakai `-e` sehingga symlink menggantung
ditolak dalam <1 detik, bukan setelah gagal boot; fail-fast saat `up` gagal), jadi
bentuk yang sama dijalankan ulang dengan kernel **sha pin rilis** `6970ada5…`
(dicatat sebelum run, bukan sesudah).

| | B1 (30 Okt, jadi riwayat) | **B1 ulang (31 Okt)** |
|---|---|---|
| siklus | 105 (dihentikan SIGTERM eksternal di 105/150) | **90/90 selesai, `rc=0`** |
| durasi terukur | 167,4 menit | **134,3 menit** (≥120 wajib) |
| siklus gagal start | 4 | **0** |
| siklus tak mencapai tick guest | 4 | **0** |
| dockerd siap + container selesai | 101/105 | **90/90** |
| RSS daemon | 4.786 → 4.758 KB | **4.624–5.456 KB**, tren **−0,9%** (median 10 pertama 5.030 vs 10 terakhir 4.986 KB) |
| RSS kernel guest | ~72 MB | 59,6–118,1 MB |
| proses tersisa per siklus | 0 | **0** |
| image dasar (sha **dan** mtime) | tak berubah | **tak berubah di 90 siklus** |
| verdict | `partial` | **`pass`** |

Kriteria B yang berbunyi "0 kegagalan boot" karena itu **terpenuhi dengan run
bersih**, bukan dengan menambal laporan lama. Record `partial` dibiarkan ada di
pohon sebagai riwayat — yang menggantikannya adalah record ini, dan catatan di
dalamnya menyebut penggantian itu secara eksplisit.

Satu detail operasional yang ikut terbukti: run lama berhenti karena **SIGTERM
eksternal** (`rc=143`) saat pembersihan sesi, bukan karena harness punya batas
waktu. Run ulang diluncurkan dengan penanda persistensi sehingga pembersihan sesi
tidak bisa menyentuhnya, dan ia menyelesaikan 90/90.

**Yang dibuktikan B2 secara khusus:** dua guest benar-benar hidup bersamaan
(2 daemon + 2 guest teramati serentak), laju kedua instance identik (~113 s),
port SSH berbeda (12501/12502) tanpa tabrakan, RSS daemon dua-guest hanya naik
~0,2 MB dibanding satu-guest, dan **0 proses tersisa** setelah run selesai —
yaitu klaim yang gagal diuji oleh penghitung device-wide lama.

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
(sha **dan** mtime sebelum/sesudah), dan tren RSS (**median 10 siklus pertama vs 10
siklus terakhir, kronologis** — versi pertama mengurutkan deret lalu membandingkan blok
terkecil vs terbesar, yang mengukur sebaran dan melaporkan +16,9% untuk run yang tren
sebenarnya −0,6%). `--min-minutes` (B1 120, B2 60) ikut menentukan verdict. `--parallel 2` untuk B2. B3 punya skrip sendiri,
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



### Kesiapan C — apa yang sudah ada, apa yang kurang, dan satu koreksi klaim

**Sudah ada dan sudah dites** (jadi C bukan pekerjaan dari nol):

| Fondasi | Di mana | Status |
|---|---|---|
| Penulis header COW v3 (C + Rust, byte-identik) | `src/uml4termuxd.c` `write_cow_header_file`, `rust/src/cow.rs` | parity-gated (`cow-header` hook, `cmp` di CI) |
| Header COW **memuat mtime + size image dasar** | `cow.rs`: `mtime`, `size`, `SECTOR_SIZE`; C: `hdr` mtime/size | **inilah yang dibutuhkan C4**, tak perlu metadata tambahan |
| COW ephemeral per instance | launcher menetapkan `UML4TERMUXD_COW=${rt}/${name}.cow` | dipakai tiap `up`, terbukti di B1 |
| Hentikan guest bersih lewat kanal konsol | daemon `stop` (poweroff 20 s → TERM → KILL) | dipakai `down`, terbukti |
| Registry instance + runtime dir per instance | `lib/registry.sh` | terbukti (G3) |
| Rotasi berkas generasi | `lib/logs.sh` (copy+truncate, `KEEP`) | pola bisa dipakai untuk rotasi snapshot |

**Yang belum ada** (inti pekerjaan C):

1. `snapshot <label>`: belum ada. Perlu: pastikan guest berhenti bersih → salin
   `${rt}/${name}.cow` → `${rt}/snapshots/<label>.cow` → tulis `<label>.json`
   (timestamp, path+size+**digest**+mtime image dasar, `uname` guest dari
   konsol, sha256 + ukuran COW).
2. `up --from <label>`: belum ada. Perlu **copy-on-resume**: snapshot bersifat
   *immutable*, tiap resume menyalinnya menjadi COW kerja baru — tanpa itu,
   resume kedua akan melihat tulisan resume pertama dan kriteria "dua boot
   identik" gagal.
3. `snapshots` (daftar) + `snapshot --rm` + rotasi (simpan N terakhir).
4. Penolakan eksplisit di depan (bukan mengandalkan UML): image dasar berubah
   digest/size/mtime → tolak dengan pesan yang menyebut angka.
5. Gate: `tests/test-snapshot.sh` (level berkas: penolakan image berbeda,
   isolasi copy-on-resume, rotasi) + bukti device lewat kanal `exec`.

**Koreksi klaim yang harus tertulis, bukan disembunyikan.** Tujuan di atas
berbunyi "kembali ke kondisi awal dalam hitungan detik". Snapshot di sini adalah
**state dingin**: guest dimatikan bersih lalu COW-nya disimpan, jadi yang
kembali adalah *isi filesystem*, bukan RAM. Biaya kembali = satu boot
(±20–30 s dengan cache hangat), **bukan** hitungan detik, dan proses yang
sedang berjalan di guest tidak ikut hidup lagi. Yang benar-benar "detik" hanya
bisa dicapai dengan save/restore RAM, yang tidak didukung port ini. Fitur ini
tetap bernilai — "coba sesuatu, lalu kembali ke kondisi awal" dengan satu
perintah dan tanpa boot ulang dari nol — tapi janjinya harus ditulis apa adanya.

**Diverifikasi di device (bukan diasumsikan), dari COW milik soak B1 yang
sedang berjalan:**

```
COW   : v3 mtime=1793373461 size=3221225472 sector=512
IMAGE : mtime=1793373461 size=3221225472      <- mtime dan size COCOK PERSIS
bitmap: 16 bit set (2 byte non-nol)           <- tulisan guest benar lewat COW
ukuran: 3.222.016.512 byte logis, 2.416 KB alokasi disk (sparse)
```

Tiga konsekuensi yang mengubah rencana:

1. **C4 bisa ditopang header, bukan metadata karangan.** Header COW sudah memuat
   mtime + size image dasar dan nilainya **cocok persis** dengan image yang
   dipakai. Metadata snapshot cukup menambahkan digest image (yang tak ada di
   header) + path yang benar-benar dipakai.
2. **`cp` di Termux mempertahankan sparseness** — diukur: berkas 64 MB dengan
   4 KB data → salinan tetap 4 KB alokasi, baik `cp` biasa maupun
   `cp --sparse=always`. Jadi snapshot COW (2,4 MB di sini) murah dan tidak
   membengkak jadi 3,2 GB. Tetap catat **ukuran logis dan ukuran teralokasi**
   di metadata, karena keduanya berbeda arti.
3. **mtime di header merujuk image yang benar-benar di-boot**, bukan path
   default: soak memakai salinan `img-s1.ext4` yang mtime-nya berbeda dari image
   asli di `uml-forensics/`. Karena itu `up --from` harus memeriksa image yang
   **akan dipakai**, dan pesan penolakan menyebut path + mtime + digest
   keduanya supaya bisa dibandingkan langsung oleh pengguna.

**Desain yang dipilih — dikoreksi saat implementasi.** Rencana di atas
mengusulkan `snapshot` sebagai perintah protokol daemon. Setelah dikerjakan,
pembagiannya bergeser ke **launcher**, dan alasannya ditulis di sini: isi snapshot
adalah siklus hidup instance -- hentikan guest dengan bersih, salin COW, catat
metadata -- dan seluruh bahannya sudah dimiliki launcher (registry, nama,
direktori runtime, jalur COW `${rt}/${name}.cow`). Menaruhnya di daemon berarti
menulis logika yang sama dua kali (C dan Rust) untuk keuntungan nol, sekaligus
menambah permukaan protokol yang harus dijaga parity-nya selamanya.

**Satu perubahan daemon tetap diperlukan, dan itulah yang membuat C mungkin.**
Jalur boot dulu menulis header COW **tanpa syarat** setiap boot, sehingga resume
mustahil: keadaan selalu di-reset. Sekarang header hanya ditulis bila berkas COW
hilang atau bukan v3 yang valid, dan keputusan fresh-vs-resume tinggal di satu
tempat -- `up` (fresh) menghapus COW kerja, `up --from` menaruh salinan snapshot di
sana. Perubahan itu parity-gated: hook `cow-ensure` menjalankan kedua implementasi
(C dan Rust) pada COW valid / hilang / rusak, lalu membandingkan **keputusan**
(reuse vs write) sekaligus byte hasilnya.

### Hasil C (2026-10-31) — C1–C4 SELESAI

Bukti: `evidence/20261031-snapshot-resume.json` (11 artefak) + gate
`tests/test-snapshot.sh` (28 asersi; `ci/local-ci.sh` 20/20).

| Item | Bukti di device (3 boot nyata) |
|---|---|
| C1 | snapshot menghentikan guest dengan bersih, menulis `snapshots/snap-a.cow`, mencatat BASE_SIZE (= 3.221.225.472), BASE_MTIME, dan BASE_SHA256 |
| C2 | berkas yang ditulis **sebelum** snapshot terbaca **sesudah** resume dengan md5 identik (`881da598db`); COW snapshot `73c73b83…` tidak berubah setelah dua resume; penanda kedua yang ditulis pada resume-1 **nol kemunculan** pada resume-2 |
| C3 | `snapshots` mendaftar label; `snapshot --rm` menghapus COW + metadata; rotasi menyimpan N terbaru (dibuktikan di gate) |
| C4 | resume dengan image berbeda **ditolak rc=1 sebelum boot**, pesan menyebut `recorded: size …` dan `now : size …`, dan tidak ada daemon baru di registry |
| lain | image dasar tidak berubah (sha256 sama) -- tulisan guest masuk ke COW; 0 proses tersisa milik run ini |
| C2b | `up --from` pada instance yang **masih hidup** ditolak rc=1 (bukan diadopsi diam-diam), pesan menyebut `down`, dan guest yang hidup tidak terganggu |

Verdict record: `pass`. Snapshot tetap **state dingin**: yang kembali adalah
filesystem, bukan RAM; biayanya satu boot; "resume instan" tidak dijanjikan.

**Satu cacat produk lagi, ditemukan justru saat menulis dokumen penutup:** `up --from`
pada instance yang masih hidup **mengadopsi** daemon yang berjalan dan membalas
`rc=0` **tanpa me-resume apa pun** -- laporan sukses untuk pekerjaan yang tidak
dilakukan. Sekarang ia menolak dengan pesan yang menyebut sebabnya dan perintah
`down` yang harus dijalankan; versi barunya diuji di device (langkah 4b) sekaligus
memastikan guest yang hidup tidak ikut terganggu.

**Tiga cacat harness yang harus diperbaiki sebelum angka di atas sah** -- dicatat
karena masing-masing sempat menghasilkan kesimpulan palsu:

1. `up` **mengadopsi** daemon yang masih hidup dan membalas `rc=0` tanpa boot, jadi
   "resume kedua" ternyata menguji guest pertama. Setiap resume kini didahului
   `down`.
2. Menghapus log konsol saat daemon hidup membuat berkas ter-unlink dan seluruh
   keluaran guest lenyap; log diarsipkan **setelah** `down`.
3. Konsol **meng-echo** perintah yang diketik, jadi penanda literal membuktikan
   apa pun. Semua payload dan penanda kini base64 di teks perintah, dan bukti
   terkuatnya adalah **md5 isi berkas** yang tidak pernah diketik sama sekali.

**Biaya nyata.** 1 sesi (bukan 1–2), sebagian besar habis di tiga perbaikan
harness di atas. **Risiko.** Rendah: jalur lama tidak berubah, dan `up` tanpa
`--from` tetap berperilaku sama (COW dihapus sebelum boot).

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

### Hasil D (2026-10-31) — D1, D3 SELESAI; D2 SIAP-PR; D4 terukur

**D1 — varian glibc: SELESAI dengan bukti, bukan klaim.** Bukti:
`evidence/20261031-d1-glibc-arm64.json` (verdict `pass`, dihasilkan CI), log kedua job,
dan `.github/workflows/glibc-arm64.yml` + `ci/glibc/classify.sh`.

Yang pertama harus dijawab adalah **apa sebenarnya yang khas-bionic**. Dari ELF-nya:
kernel `linux-bionic` dan `stub_exe` **statically linked** (tanpa loader → jalan di
Linux aarch64 mana pun), sedangkan `uml4termuxd` dan front end Rust memakai
`/system/bin/linker64` (Android saja). Jadi pekerjaannya bukan membangun ulang kernel,
melainkan membangun daemon di glibc dan **membuktikan** sisanya.

| Yang diukur di runner `ubuntu-24.04-arm` (glibc, aarch64) | Hasil |
|---|---|
| kernel rilis boot di host glibc, guest melaporkan dari dalam | `arch=aarch64`, `7.2.0-rc4-g169b17ff3f66-dirty`, 3 CPU, MemTotal 509.696 KB, marker `DONE` |
| daemon dibangun `cc` terhadap glibc | kontrak runtime v1 **OK**, hardening E3 **lulus (0 skipped)**, parity C-vs-Rust **OK**, Rust `37 passed` |
| klasifikasi artefak | kernel + stub `PORTABLE (static, no loader)`; daemon terlacak `BIONIC-ONLY` |
| verifikasi aset | digest dipin di env workflow + `sha256sum -c SHA256SUMS` (fail-closed) |

Installer/portabilitas ikut diperbaiki sepanjang jalan: `ci/glibc/initramfs.sh`
membangun guest sebagai initramfs busybox (tanpa disk, tanpa loop mount), dan empat
peringatan gcc yang clang tidak pernah munculkan diselesaikan **di kode** — `path_fmt()`
menolak start (exit 64) ketika sebuah path tidak muat, panjang `sun_path` diperiksa
sebelum penyalinan, dan `strncat` dengan batas dari sumber diganti `memcpy` dengan
panjang yang sudah diperiksa. Yang paling nyata: opsi kernel `ubd0=<cow>,<image>`
menggabungkan dua path dari pengguna dalam satu buffer tetap.

**D3 — panel status: SELESAI.** `panel/` (server stdlib + halaman tanpa build step +
`render-check.mjs`), perintah `uml4termux panel`, dan gate `tests/test-panel.sh`
(15 asersi, 0 skip; masuk `ci/local-ci.sh` dan `ci.yml`). Panel menampilkan state nyata
**lewat kontrak** (protokol v1 `status`/`ports` JSON) — bukan dengan membaca berkas
internal daemon — dan **read-only**: endpoint HTTP daemon tanpa autentikasi, jadi
halaman memberi perintah untuk dijalankan, bukan tombol yang memutasi keadaan.

Batasan yang jujur: **tidak ada browser engine di device ini** (Playwright menjawab
`Unsupported platform: android`), jadi tidak ada asersi tingkat render-browser.
Gantinya `panel/render-check.mjs` menjalankan skrip halaman itu sendiri di node
terhadap balasan panel yang hidup, dengan DOM stub, dan mengasersi node yang benar-benar
dibuat. Itu disebut sebagai apa adanya, bukan "uji browser".

**D4 — resep nyata.** `bench/recipes.sh` menjalankan beban sungguhan lewat kanal exec
instance yang hidup; angka di bawah ini hasil ukur di device referensi, bukan taksiran:

| Resep | Terukur |
|---|---|
| `docker run --rm alpine true` ×10, image hangat | **15,7 s per start container** (10 start dalam 157,4 s); image alpine 8,3 MiB |
| nginx di satu container, `ab` di container lain, 500 permintaan konkurensi 10 | **76,3 req/s**, 131,0 ms per permintaan, 0 gagal |
| registry lokal: push lalu pull image hasil build | lihat keluaran harness (jalankan `--wait 600`) |

Angka itu gunanya justru untuk itu: start container di dalam UML di ponsel adalah
**belasan detik**, bukan pecahan detik, dan pembaca yang merencanakan dengan angka
native akan kecewa.

**D2 — paket Termux: siap-PR, belum diajukan.** `packaging/termux/build.sh` (v0.5.0 +
digest tarball rilis) dan `packaging/termux/PR.md` berisi apa yang akan diajukan,
field yang akan diperiksa reviewer, cara memverifikasi, dan batasan yang harus
disebut di badan PR. `termux_step_make_install` kini **mendelegasikan ke
`scripts/install.sh`** alih-alih memelihara daftar berkas kedua yang sudah
menyimpang. Membuka PR ke repositori orang lain adalah tindakan publik: itu
menunggu persetujuan pemilik repo, jadi bagian ini berhenti di "siap".

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

### Hasil E (2026-10-31) — E1–E4 SELESAI

Bukti: `docs/THREAT-MODEL.md` (E1) · `tests/test-signature.sh` (E2, 18 asersi) ·
`tests/test-daemon-security.sh` (E3, 16 asersi + 1 SKIP lokal) ·
`evidence/20261031-security-isolation.json` (E4, dua boot, verdict `pass`).

| Item | Bukti yang benar-benar diukur |
|---|---|
| **E1** | `docs/THREAT-MODEL.md`: aset yang dilindungi, empat aktor beserta kemampuannya, tabel "dilindungi vs tidak", tabel kontrol → tes penegak, dan **risiko sisa** yang tidak dihilangkan (uid sama, guest root, tanpa enkripsi, kunci rilis bocor, endpoint HTTP tanpa autentikasi) |
| **E2** | Tanda tangan atas `SHA256SUMS` (`lib/security.sh`, kunci publik di `packaging/keys/`). Digest cocok + tanda tangan salah → **ditolak**, di tingkat pustaka **dan** lewat `uml4termux fetch` (rc≠0). SUMS diubah sesudah ditandatangani → ditolak. Tanpa tanda tangan + `UML4TERMUX_REQUIRE_SIGNATURE=1` → ditolak. `make-dist` menandatangani hanya bila kunci tersedia, dan menyebut dirinya `UNSIGNED` bila tidak |
| **E3** | Socket `0600`, direktori runtime `0700`, `audit.log` `0600`. `SO_PEERCRED` di **C dan Rust**: koneksi bukan pemilik ditolak daemon sendiri (bukan hanya oleh mode berkas), diuji nyata sebagai root ke daemon milik user lain — di CI, karena di device hanya ada satu uid. `exec` dibatasi (`rate-limited` + `min_interval_ms`), setiap kejadian tercatat satu baris, byte kontrol dinetralkan sehingga perintah tak bisa memalsukan entri kedua |
| **E4** | `--mem 256M` → guest melaporkan **243 MiB**; `--mem 768M` → **752 MiB**; `--cpus 1` vs `--cpus 2` → `nproc` 1 vs 2; cgroup v2 `io.max` menerima `98:0 rbps=1048576` dan membacanya kembali di dalam guest; dua guest dengan memori berbeda → batas melekat **per guest**, bukan global |

**Dua hal yang sengaja tidak diklaim.** (1) Uji "koneksi dari uid lain" **tidak
bisa** dijalankan di device ini — aplikasi Android hanya punya satu uid, jadi
tes itu SKIP dengan alasannya dan dijalankan sungguhan di CI (runner root,
daemon dijalankan sebagai user lain, klien root ditolak `not the owner`).
(2) Pengerasan ini **tidak** melindungi dari proses lain dengan uid yang sama:
aktor itu bisa membaca `~/.ssh` dan menulis ulang audit log tanpa menyentuh
uml4termux. Itu dinyatakan di model ancaman sebagai risiko sisa, bukan diklaim
sebagai perlindungan.

**Biaya nyata.** 1 sesi. **Risiko.** Rendah: semua kontrol baru bersifat menambah
(socket/laju/audit/tanda tangan), dan `fetch` tanpa tanda tangan tetap bekerja
seperti sebelumnya (memberi peringatan, bukan gagal).

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
| ~~1~~ | ~~A (benchmark pin vs HEAD)~~ **SELESAI** | Menentukan pin rilis berikutnya; hasil direksional, pin tetap | — |
| ~~2~~ | ~~B (soak v2)~~ **SELESAI B1/B2/B3 + B1 ulang bersih 31 Okt** | Arsitektur berubah (daemon + COW) → butuh bukti baru | — |
| ~~3~~ | ~~C (snapshot/resume)~~ **SELESAI C1–C4** | Fitur pembeda termurah yang memanfaatkan COW | — |
| ~~4~~ | ~~E (keamanan)~~ **SELESAI E1–E4** | Prasyarat sebelum orang lain menjalankan image | — |
| ~~5~~ | ~~D (ekosistem)~~ **SELESAI D1/D3; D2 siap-PR; D4 terukur** | Perluasan audiens setelah fondasi stabil | — |
| **berikutnya** | F (hulu) | Paralel, tanpa menahan apa pun | Sedang |
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