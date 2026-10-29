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
