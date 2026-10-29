# Audit forensik: bagian mana yang layak pindah ke Rust

Metode: inventaris seluruh sumber milik proyek (bukan kernel/upstream), peta
fungsi daemon, dan penghitungan pola rapuh secara mekanis. Semua angka di
bawah dihasilkan dari perintah pada commit `226a58f` — bukan opini.

## 1. Inventaris (baris kode milik proyek)

| Komponen | Bahasa | Baris | Peran |
|---|---|---|---|
| `src/uml4termuxd.c` | C (bionic) | 1.156 | daemon supervisor + client |
| `bin/uml4termux` | shell | 514 | CLI lama (25 cabang `case`) |
| `lib/common.sh` | shell | 439 | helper, pin digest, state |
| `lib/net.sh` | shell | 387 | gvproxy, expose, jaringan |
| `lib/doctor.sh` | shell | 302 | diagnostik |
| `lib/guest.sh` | shell | 291 | cmdline, marker, boot |
| `lib/fetch.sh` | shell | 280 | unduh + verifikasi aset |
| `scripts/build-initramfs.py` | Python | 224 | perakit initramfs deterministik |
| `lib/service.sh` | shell | 153 | glue runit |
| `lib/mobility.sh` | shell | 78 | wake lock, lifecycle |
| `ci/check-evidence.py` | Python | 492 | validator evidence (CI) |
| `ci/yamlcheck.py` | Python | 632 | validator workflow (CI) |
| **Total milik proyek** | | **≈ 4.948** | (1156 C + 2.444 shell + 1.348 Python) |

Tidak dihitung: kernel/UML port (C, milik hulu), `stub_exe` (2 KB, hulu),
`gvproxy` (Go, hulu, proses terpisah).

## 2. Bukti kerapuhan (yang membuat Rust bernilai)

**C daemon (`src/uml4termuxd.c`):**

| Pola | Hitungan | Kenapa berbahaya |
|---|---|---|
| buffer tetap `char x[512]` | **16** | pemotongan path/memori senyap; `snprintf` memotong tanpa error |
| `snprintf` manual | **62** | JSON/argv/state dirakit dengan format string |
| `strstr`/`strncmp`/`strncpy` | **13** | parsing protokol dengan pencocokan string mentah |
| fungsi escape JSON | **0** | ⚠️ lihat di bawah |
| `malloc`/`free` | 1 | bagus (hampir semua statis) — tapi berarti 16 buffer tetap itu memang dipakai |

**Temuan paling konkret:** daemon memancarkan JSON lewat
`snprintf(resp, sizeof(resp), "{\"error\":\"%s\"}\n", err);` **tanpa fungsi
escape apa pun**. Pesan error yang memuat `"` atau `\` (mis. `strerror` atau
path aneh) menghasilkan JSON **tidak valid** yang gagal diparse klien. Ini
bukan hipotesis: `grep -c 'escape' src/uml4termuxd.c` = 0.

**Shell (2.444 baris):**

| Pola | Hitungan | Kenapa berbahaya |
|---|---|---|
| JSON dirakit dari string (`-d "{\"...`) | 2 | nilai berisi kutip/spasi merusak payload |
| subprocess `curl` | **16** (net 8, fetch 7, doctor 1) | dependensi eksternal, penanganan error per-panggilan |
| subprocess `sha256sum` | **11** (common 4, fetch 6, doctor 1) | verifikasi keamanan bergantung pada binary luar |
| `eval` di host | 0 | ✅ bersih (tidak ada vektor injeksi di sini) |
| cabang `case` (parsing argumen) | **76** (CLI 45, common 17, fetch 11, doctor 3) | help/validasi/error ditulis ulang tiap perintah |

**Duplikasi fungsional (drift risk):**
- `expose` ada **dua kali**: daemon (`expose h g` → `exposures.jsonl`,
  di-reapply saat restart) dan shell `cmd_expose` (`UML4TERMUX_INSTANCE_ENV` +
  `curl --unix-socket .../services/forwarder/expose`). Semantik persistensinya
  **berbeda**, dan keduanya masih hidup di tree.
- `status`/`stop` juga ada di dua lapisan (daemon client vs `lib/service.sh`).

## 3. Verdict per komponen

| Komponen | Verdict | Alasan | Usaha |
|---|---|---|---|
| `src/uml4termuxd.c` (daemon) | **MIGRATE — Fase 2** | nilai tertinggi: 16 buffer tetap, 62 format string, 0 escape JSON, protokol di-parse manual; ke depan akan tumbuh (snapshot, scheduler multi-guest, API) | ~2.000–2.500 baris Rust, 3–4 sesi |
| `bin/uml4termux` + `lib/common.sh` | **MIGRATE — Fase 1** | 62 cabang `case` di dua file ini; jadi satu CLI `clap` dengan help/validasi gratis | ~600–800 baris, 1 sesi |
| `lib/fetch.sh` | **MIGRATE — Fase 1** | 6 `sha256sum` + 7 `curl` subprocess → `sha2` + HTTP in-process; verifikasi keamanan tak lagi bergantung binary luar | ~400–500 baris (menyatu CLI) |
| `lib/net.sh` | **MIGRATE — Fase 1/2** | 8 `curl` + payload JSON via string; dedup dengan `expose` daemon (hapus jalur ganda) | ~400 baris |
| `lib/guest.sh` | **MIGRATE — Fase 2** | perakitan cmdline + penantian marker dengan polling → jadi tipe & timeout eksplisit | ~300 baris (masuk daemon) |
| `lib/doctor.sh` | **MIGRATE — Fase 3 (opsional)** | banyak subprocess + parsing teks; enak di Rust, tapi bukan jalur kritis | ~300 baris |
| `lib/service.sh` + `lib/mobility.sh` | **KEEP dulu** | glue runit/wakelock tipis; shell adalah bahasa yang tepat di sini | — |
| `scripts/build-initramfs.py` | **OPTIONAL — Fase 3** | Python stdlib sudah memadai dan byte-exact terbukti; nilai Rust = menghapus dependensi Python dari jalur pengguna (rendah, Termux punya Python) | ~350 baris |
| `ci/check-evidence.py`, `ci/yamlcheck.py` | **KEEP** | tooling CI; `jsonschema`/PyYAML adalah implementasi rujukan; Rust hanya menambah dependensi cargo di runner | — |
| kernel + UML port | **KEEP (wajib)** | C, milik hulu, 95% dari yang orang sebut "UML" | — |
| `stub_exe` (2 KB) | **KEEP (wajib)** | di-`exec` kernel saat boot; harus minimal, tanpa runtime | — |
| `gvproxy` (Go, hulu) | **KEEP** | proses terpisah; menulis ulang = proyek jaringan besar tanpa manfaat | — |
| `packaging/{service,termux}` | **KEEP** | runit & paket memang shell | — |

## 4. Yang Rust menangkan secara struktural (bukan selera)

1. **JSON selalu valid** — `serde_json` menggantikan 62 format string dan
   menutup kelas bug "error memuat kutip" yang saat ini nyata.
2. **Tak ada buffer tetap** — `PathBuf`/`String` menghapus 16 titik pemotongan
   senyap.
3. **Nol subprocess di jalur pengguna** — 16 `curl` + 11 `sha256sum` hilang;
   verifikasi aset tidak lagi bergantung pada binary luar yang bisa berbeda
   versi.
4. **Satu biner, satu protokol** — duplikasi `expose`/`status` (daemon vs
   shell) hilang bersama CLI lama.
5. **Error sebagai nilai** (`Result` + `?`) menggantikan `errno` + `logf_`
   tersebar; jalur gagal jadi eksplisit.
6. **Test nyata** — `cargo test` untuk protokol, penulis header COW, parser
   `io.max`/`cpuset`, dibandingkan tes shell yang ada sekarang.

## 5. Yang tetap sulit (jangan dijual berlebihan)

- `fork` + `exec` + PTY + sinyal **tetap** memerlukan `unsafe`/`libc`/`nix`
  (perkiraan 15–20% baris). Yang berkurang adalah permukaan bug, bukan hilang.
- **Performa UML tidak berubah** sama sekali — daemon bukan bottleneck;
  overhead ada di kernel (arah A pada `docs/NEXT-STEPS.md`).
- Biner naik dari 32 KB → ~1–1,5 MB (tidak penting untuk Termux).
- `cargo build` di device lambat → build tetap dilakukan di CI (sudah ada
  polanya: NDK + runner x86_64).

## 6. Rencana bertahap (dengan gerbang parity)

| Fase | Isi | Gerbang lulus | Risiko |
|---|---|---|---|
| **1** | Biner Rust `uml4termux` (CLI + fetch + verifikasi + net) hidup **berdampingan** dengan shell lama; hanya perintah baru yang diarahkan ke sana | sha256 aset cocok vs `sha256sum`; exit code identik untuk kasus galat; `ci/local-ci.sh` tetap 12/0 | Rendah |
| **2** | Port daemon ke Rust; protokol socket & file state **identik byte-per-byte**; C tetap di tree sebagai referensi | selftest identik; `stop` bersih ≤20 s; COW header byte-exact vs C; soak arah B lulus; 0 proses yatim | Sedang |
| **3** | Pindahkan doctor, build-initramfs, service glue bila masih ada nilai | artefak initramfs byte-identik; diagnostik setara | Rendah |
| — | **Tidak pernah** | kernel, stub, gvproxy | — |

## 7. Ukuran keberhasilan

- Satu biner Rust untuk semua perintah pengguna; `bin/uml4termux` + `lib/*.sh`
  tinggal sebagai pembungkus kompatibilitas atau dihapus.
- `grep -r 'curl \|sha256sum' ` pada jalur pengguna = **0**.
- Klien JSON apa pun bisa memparse keluaran daemon tanpa kasus tepi.
- Semua bukti lama (evidence schema 1.1) tetap lulus, dan soak arah B lulus
  dengan biner Rust.

## 8. Status pelaksanaan

### Fase 1 — CLI (`rust/`, biner `uml4termux-rs`) — SELESAI

Bangunan: `clap` + `serde_json` + `sha2` + `ureq`/rustls. Modul `config`
(path sama dengan `lib/common.sh`), `assets` (tabel + pin), `client` (protokol
socket), `fetch` (unduh + verifikasi). Biner **1,6 MB** (release, LTO, strip)
dan dibangun **native untuk `aarch64-linux-android`** — host triple rustc
Termux memang bionic, jadi build di device = build target sebenarnya.

Bukti yang dihasilkan:

| Uji | Hasil |
|---|---|
| `cargo test --release` | **13/13 lulus** (protokol, digest NIST, fail-closed tanpa pin, mismatch fatal) |
| `cargo clippy -D warnings` + `cargo fmt --check` | bersih |
| Parity klien C vs Rust (satu socket, daemon selftest) | **byte-identik** untuk `status`, `ports`, `expose`, `exec` |
| Exit code daemon tak terjangkau | `3` di kedua klien |
| `fetch --only daemon` | digest cocok pin, `chmod 0755`, 1,4 s, **0 subprocess** curl/sha256sum |

Dua bug nyata ditemukan justru karena port ini:

1. **`uml4termux_asset_sha` tidak punya kasus `daemon`** → jalur shell memasang
   biner daemon **tanpa verifikasi** (`[warn] NOT VERIFIED`). Diperbaiki.
2. **Pin `UML4TERMUX_DISK_SHA256` (`2807979f…`) adalah digest `.gz`, bukan
   `.ext4`** (terukur: `.ext4` = `83f46631…`). Tabel Rust dikoreksi: `disk`
   tanpa pin (turunan hasil dekompresi), `disk-gz` memegang pin.

Gerbang CI baru `rust`: fmt + clippy `-D warnings` + 13 tes + build + **parity
daemon** (klien C vs Rust pada satu socket). Duplikasi jalur `expose`/`status`
belum dihapus karena itu menuntut daemon menjadi satu-satunya pemilik state —
dikerjakan di Fase 2, bukan dengan mengubah shell lebih dulu.

### Fase 2a — server daemon di Rust — SELESAI

`rust/src/daemon.rs` mem-port paruh daemon: socket kontrol (`0600`, umask 0077),
file state atomik (`tmp` + `rename`), penjadwalan anak di PTY (`forkpty` +
`execv`), drain konsol ke `uml-console.log`, kebijakan restart (backoff 2s×n,
batas 5, exit 0 = sesi selesai tanpa restart, 126/127 = menyerah), shutdown
bersih (perintah mati-bersih lewat konsol dengan anggaran 20 s, lalu SIGTERM,
lalu SIGKILL) dan seluruh protokol klien.

**Gerbang parity baru** `ci/verify-daemon-parity.sh`: daemon C dan daemon Rust
dijalankan bergantian pada runtime yang sama, dikueri klien yang sama, lalu
dibandingkan baris per baris (hanya PID yang dinormalisasi). Hasil di device:

```
daemon parity OK (C vs Rust, 5 normalised lines)
  {"state":"running","child_pid":PID,"restarts":0,"mode":"selftest"}
  {"exposures":[]}
  {"error":"guest not running"}
  {"error":"gvproxy not running"}
  {"phase":"running","child_pid":PID,"restarts":0,"detail":"spawned","ts":TS}
```

Satu beda ditemukan dan diperbaiki justru oleh gerbang ini: `serde_json::json!`
mengurutkan kunci secara alfabetis, sedangkan daemon C menulisnya dalam urutan
`phase, child_pid, restarts, detail, ts`. State JSON sekarang dibangun dengan
urutan eksplisit agar byte-identik — **sementara escaping nilainya tetap dari
serde**, yang menutup bug daemon C (`snprintf("%s")` pada `detail` dapat
menghasilkan JSON tidak valid).

Fase 2b (gvproxy, registry exposure, endpoint HTTP) menyusul di bawah dan
sudah selesai.

25 tes Rust lulus (termasuk 8 tes daemon: bentuk `status` selftest, `ports`
kosong, dua jalur galat, perintah tak dikenal, `stop`, round-trip state file
dengan `detail` berisi kutip/backslash, dan penempatan COW di depan `ubd0=`).

### Fase 2b — gvproxy, registry exposure, endpoint HTTP — SELESAI

Sisa paruh daemon kini juga di Rust: siklus hidup `gvproxy` (argv
`-listen=unix://<bess>.gv.sock` / `-listen-bess=unixpacket://<bess>` /
`-log-file`, pembungkus `proot -b $PREFIX/etc:/etc` bila host tak punya
`/etc/resolv.conf`, `setsid` sebelum exec, tunggu socket bess ≤5 s), shutdown
per-grup (`kill(-pid)` → SIGKILL, karena tracee proot yatim bila hanya pid proot
yang dibunuh), klien HTTP-over-unix ke API gvproxy, registry exposure JSONL
(dedup per port host, tulis atomik), re-apply exposure saat start, dan endpoint
kesehatan HTTP opsional `UML4TERMUXD_HTTP` (balasan `HTTP/1.0` byte-identik
dengan C, termasuk mode `ephemeral-cow`/`persistent`).

Gerbang parity kini memeriksa **6 baris** (4 perintah + state file + body HTTP):

```
daemon parity OK (C vs Rust, 6 normalised lines)
  ...
  {"ok":true,"state":"running","child_pid":PID,"exposures":0,"mode":"persistent"}
```

Dua bug ditemukan lewat tes ini sendiri:

1. **Endianness `sin_addr`** — `u32::from_be_bytes(ip.octets())` menghasilkan
   `01 00 00 7F` untuk `127.0.0.1` → `bind()` gagal `EADDRNOTAVAIL (os error 99)`;
   yang benar `u32::from_ne_bytes` (memori `s_addr` memang urutan jaringan).
2. Payload expose kini dirakit `serde_json` (bukan konkatenasi string seperti
   C), jadi port aneh tidak bisa merusak JSON.

30 tes Rust lulus.

### Fase 2b — verifikasi device: daemon Rust mem-boot guest nyata — SELESAI (dengan koreksi)

**Versi pertama klaim ini salah, dan koreksinya bagian terpenting di sini.**
Boot pertama hari itu memang menjalankan supervisor Rust, tetapi guest-nya
**TIDAK punya disk**: kernel mencetak

```
F_SETLK failed, file already locked by pid 30053
Failed to lock '<image>', err = 11
Failed to initialize ubd device 0
UML4TERMUX_INIT NO_DISK: no /dev/ubda, running /forensic.sh inside the initramfs
```

UML memegang **lock eksklusif (`F_SETLK`) pada image backing**, dan pemegangnya
adalah guest milik layanan runit lama yang memakai image yang sama. Karena init
guest jatuh ke mode tanpa-disk, semua marker tetap tercetak dan "boot sukses"
terlihat benar — padahal tidak ada disk, tidak ada COW, dan setiap tulisan guest
hilang. Direproduksi pada **kedua daemon** (C rilis v0.5.0 dan Rust): jadi sifat
lingkungan/kernel, bukan bug port.

Setelah diuji ulang dengan **image privat** (`uml-forensics/cap7/debian-docker.ext4`,
tidak dipakai service), barulah jalur disk terbukti:

| Bukti | Hasil |
|---|---|
| Attach disk | `UML4TERMUX_INIT root_mounted /dev/ubda -> /newroot` |
| Pindah root | `UML4TERMUX_INIT SWITCH_ROOT_NOW /forensic.sh` |
| Userspace guest | `RUSTDAEMON_UNAME … aarch64 GNU/Linux` (Debian, bukan initramfs) |
| Tulisan masuk COW | **760 sektor** tercatat di bitmap, **592 KB** teralokasi |
| Image backing | hash `7e1127d1…` **dan mtime identik** sebelum/sesudah |
| Akhir sesi | guest `poweroff` sendiri → `phase=completed`, `detail=exit=0`, 0 yatim |
| A/B vs daemon C | marker guest identik; COW kedua daemon **byte-identik** (`052c0be9…`) |
| `ci/local-ci.sh` / CI | 14/14 · job rust + device-evidence **hijau** |

**Perbaikan produk dari temuan ini** (khusus daemon Rust):
`UML4TERMUXD_STRICT_UBD=1` menyalakan pemindai konsol yang mengenali kegagalan
attach ubd (termasuk saat baris kernel terbelah antar-read), lalu menulis
`state=failed detail=ubd-attach` dan **membatalkan** boot alih-alih melanjutkan
tanpa disk. Terverifikasi di device: guard menyala, skrip guest **tidak pernah
jalan** (`GUEST_MARKERS_RAN 0`), 0 proses tersisa.

Evidence: `evidence/20261030-rust-daemon-parity.json` (verdict `partial`, lulus
checker, `ubd_lock_contention.ok=false`) + 7 artefak log mentah.

Belum tertutup dan disebut apa adanya: gvproxy hidup yang menempel ke guest
nyata, soak dengan disk terpasang, dan biner C masih yang dikirim di rilis
v0.5.0.

**Catatan operasional yang menyatu dengan temuan di atas**: layanan runit
`uml4termux` (flow shell lama) memakai image backing **yang sama**, memegang
lock eksklusifnya selama guest hidup, dan mem-boot dalam mode **persistent
(tanpa COW)** sehingga bisa mengubah digest image. Karena itu: matikan
service sebelum pengukuran digest atau uji COW, dan jangan menjalankan dua
guest pada satu image.

Catatan jujur yang belum tertutup: registry exposure + gvproxy belum diuji
dengan gvproxy hidup yang menempel ke guest nyata, dan soak belum dijalankan
untuk daemon Rust. Biner C masih yang dikirim di rilis v0.5.0.
