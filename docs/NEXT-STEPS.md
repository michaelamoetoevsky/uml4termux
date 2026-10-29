# Next steps — arah pengembangan pasca v0.5.0

Status dasar (terverifikasi, lihat `docs/ROADMAP-0.4.md` dan `evidence/`):
Docker berjalan penuh di UML arm64 dalam Termux tanpa root; daemon biner
menjalankan/mengawasi guest; boot ephemeral COW; multi-guest; kernel
byte-reproducible; rilis v0.5.0 terbit dengan 6 asset.

Dokumen ini menetapkan **enam arah** pengembangan berikutnya. Aturan main:

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

**Kriteria lulus.** Tabel sebelum/sesudah dengan ≥3 run per sel, median +
rentang, dan pernyataan jelas: "HEAD lebih cepat X% / lebih lambat / setara"
pada tiap profil. Keputusan pin rilis berikutnya mengikuti hasil ini.

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

## Urutan yang direkomendasikan

| Urut | Item | Alasan | Risiko |
|---|---|---|---|
| 1 | A (benchmark pin vs HEAD) | Menentukan pin rilis berikutnya; data sudah setengah tersedia | Nol |
| 2 | B (soak v2) | Arsitektur berubah (daemon + COW) → butuh bukti baru | Nol |
| 3 | C (snapshot/resume) | Fitur pembeda termurah yang memanfaatkan COW | Rendah |
| 4 | E (keamanan) | Prasyarat sebelum orang lain menjalankan image | Rendah |
| 5 | D (ekosistem) | Perluasan audiens setelah fondasi stabil | Rendah |
| 6 | F (hulu) | Paralel, tanpa menahan apa pun | Sedang |

## Di luar lingkup (jangan dijanjikan)

- **Mengganti kernel/port UML dengan bahasa lain.** UML adalah sub-arsitektur
  kernel Linux (C). Yang bisa ditulis ulang hanyalah *userspace*: daemon, CLI,
  tooling.
- **systemd/OpenRC sebagai PID 1** di guest (terbukti hang).
- **Docker rootless di dalam guest** (butuh pemetaan UID yang tidak didukung
  port ini); dockerd tetap root-di-dalam-guest.
- **`hostfs`** untuk kode tak tepercaya.
- **Menyamai performa native** — batas arsitektural, bukan bug.