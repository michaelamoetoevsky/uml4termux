# Kontrak runtime uml4termux — v1

Dokumen ini adalah **kontrak**, bukan deskripsi: apa pun yang tertulis di sini
adalah permukaan yang boleh diandalkan lapisan lain (shell CLI, panel WebUI,
adapter launcher, skrip pengguna). Sebaliknya, apa pun yang **tidak** tertulis
di sini adalah detail implementasi yang bisa berubah tanpa pemberitahuan.

Kontrak ini lahir dari arah **G** (`docs/NEXT-STEPS.md`) dan dipaksakan oleh
`tests/test-runtime-contract.sh` yang menegakkan klaim di bawah terhadap daemon
yang benar-benar hidup.

**Versi**: `protocol = 1`, `runtime_contract = 1`.
Verifikasi cepat: `uml4termuxd protocol` (atau `uml4termux-rs protocol`).

```json
{"protocol":1,"runtime_contract":1,"commands":["status","stop","ports","expose","exec","protocol"]}
```

Balasan di atas **byte-identik** antara daemon C dan daemon Rust — dijaga
`ci/verify-daemon-parity.sh`. Naikkan `protocol` hanya bila klien lama tidak
bisa lagi bekerja dengan benar (perubahan tak-kompatibel); **penambahan**
perintah atau field baru tidak menaikkan versi.

---

## 1. Tata letak direktori runtime

Semua state runtime hidup di `${UML4TERMUX_RUNTIME}` (default
`${TMPDIR:-/tmp}/uml4termux`). Direktori ini boleh dihapus saat tidak ada
daemon; **tidak ada** state yang boleh dianggap persisten selain yang
didaftarkan di bawah.

| Path | Isi | Sifat |
|---|---|---|
| `daemon.sock` | socket kontrol unix | **mode 0600**; umask 0077 saat dibuat |
| `daemon.sock.state` | state JSON satu baris | ditulis atomik (`*.tmp` lalu `rename`) |
| `daemon.log` | stdout/stderr daemon (append) | ditulis oleh spawn launcher; **dirotasi** (lihat §1a) |
| `uml-console.log` | konsol guest mentah (append) | sumber diagnostik utama; **dirotasi** |
| `bess.sock.gv.log` | log gvproxy sendiri (append) | **dirotasi** |
| `exposures.jsonl` | registry exposure, satu JSON per baris | dimiliki **hanya** oleh daemon |
| `bess.sock` | transport BESS ke gvproxy | milik gvproxy |
| `bess.sock.gv.sock` | API kontrol gvproxy | dipakai daemon saat `expose` |

### 1a. Log dibatasi oleh CLI, bukan oleh daemon log

Tiga log di atas adalah **permukaan yang dijanjikan ada**, dan ukurannya dijaga:

- batas `UML4TERMUX_LOG_MAX_BYTES` (default 10 MiB) per berkas;
- retensi `UML4TERMUX_LOG_KEEP` (default 3) generasi `<berkas>.1 .. .K`;
- `uml4termux up` merotasi **sebelum** setiap start, dan
  `uml4termux rotate [--name N | --all] [--max-bytes B] [--keep K]` adalah
  perintah publik untuk tick supervisor atau cron;
- rotasi memakai **copy+truncate**, sehingga inode berkas aktif tidak berubah
  dan proses yang sudah memegangnya tetap menulis ke berkas yang sama. Rename
  tidak dipakai justru karena itu.

Konsekuensi yang boleh diandalkan: sebuah instance tidak pernah mewarisi log tak
terbatas dari run sebelumnya, dan tidak ada daemon log eksternal yang perlu
hidup. Yang **tidak** dijanjikan: rotasi berjalan sendiri saat instance hidup
tanpa pemanggil (tak ada thread rotator di daemon).

### 1b. Kail adapter launcher

Setiap supervisor eksternal harus memakai **satu** kail ini dan tidak yang lain:

```
uml4termux up --foreground [--name NAME] [opsi up lain]
```

- proses tetap di depan sampai instance benar-benar berhenti;
- **exit 0** = penghentian yang disengaja (`uml4termux down`) → supervisor tidak
  boleh menyalakan ulang;
- exit selain 0 = crash → supervisor boleh menyalakan ulang dengan backoff;
- catatan registry ditulis **sebelum** `exec` (memakai `$$`, yang menjadi pid
  daemon setelah exec), jadi instance yang dijalankan supervisor tetap terlihat
  oleh `status`, `ls` dan `down`.

Adapter rujukan ada di `packaging/adapters/{systemd,s6,plain,runit}`; hanya
adapter runit yang boleh menyebut alat runit.
| `bess.sock.gv.log` | log gvproxy | milik gvproxy |
| `<label>.pid` | pid proses yang dilacak shell (`gvproxy`, `uml`) | jalur shell lama |

## 2. Protokol kontrol (socket unix, baris-perintah)

Klien menulis **satu baris** perintah, daemon membalas **satu baris JSON**
(diakhiri `\n`). Tidak ada autentikasi selain izin filesystem socket (0600):
pemilik direktori runtime = pemilik daemon.

| Perintah | Balasan sukses | Balasan galat |
|---|---|---|
| `protocol` | `{"protocol":1,"runtime_contract":1,"commands":[...]}` | — |
| `status` | `{"state":"running","child_pid":N,"restarts":N,"mode":"selftest\|persistent"}` | — |
| `stop` | `{"state":"stopping"}` | — |
| `ports` | `{"exposures":[...]}` (dari `exposures.jsonl`) | — |
| `expose <host> <guest>` | `{"exposed":"127.0.0.1:<host> -> 192.168.127.2:<guest>"}` | `{"error":"..."}` |
| `exec <argv...>` | keluaran perintah dari kanal konsol | `{"error":"guest not running"}` |

Aturan yang mengikat:

- **Loopback saja.** `expose` hanya boleh memetakan `127.0.0.1`; tidak ada
  jalur untuk membuka port ke LAN dari kontrak ini.
- **Satu penulis per state.** `exposures.jsonl` hanya ditulis daemon; front end
  lain **wajib** mengirim perintah `expose`, bukan menulis berkasnya. Ini bukan
  preferensi gaya — dua penulis = drift (lihat `docs/RUST-MIGRATION-AUDIT.md` §Fase 2e).
- Galat dilaporkan sebagai field `error` di JSON, bukan lewat kode keluar
  protokol.

## 3. Exit code front end (wajib sama untuk C dan Rust)

| Kode | Arti |
|---|---|
| `0` | sukses |
| `3` | daemon tidak terjangkau (socket tidak ada / koneksi ditolak) |
| `64` | galat pemakaian: perintah tak dikenal, argumen kurang/salah |

Nilai ini **terukur**, bukan asumsi: klien Rust awalnya keluar `2` (default
clap) untuk perintah tak dikenal sementara klien C keluar `64` — perbedaan itu
ditemukan oleh probe dan diperbaiki agar kedua front end sama.

## 4. Skema state file

Satu baris JSON, ditulis atomik:

```json
{"phase":"running","child_pid":12345,"restarts":0,"detail":"spawned","ts":1761800000}
```

`phase` ∈ `running` · `stopped` · `completed` · `exited` · `failed`
(vokabuler ini identik di daemon C dan Rust dan ikut diverifikasi gate parity).

Arti fase (dipakai supervisor dan skrip kesehatan):

- `running` — anak (guest/child selftest) hidup.
- `stopped` — dihentikan atas permintaan (`stop`), bukan kegagalan.
- `completed` — sesi selesai sendiri dengan exit 0 (kasus normal `poweroff`).
- `exited` — anak keluar dengan kode bukan nol yang masih dalam kebijakan restart.
- `failed` — menyerah: exit 126/127, batas restart terlampaui, atau guard
  fatal (`UML4TERMUXD_STRICT_UBD=1` saat disk gagal attach).

## 5. Definisi *ready*

Sebuah instance dianggap **siap** bila ketiganya benar:

1. socket `daemon.sock` ada, dan
2. `protocol` menjawab dengan `protocol = 1`, dan
3. state file ber-`phase` `running`.

Tidak ada penantian dengan `sleep` tetap di lapisan atas: supervisor harus
memutar ketiga kondisi di atas. (Ini yang menggantikan "tunggu 5 detik lalu
anggap siap".)

## 6. Invarian

Invarian berikut **bukan** saran; pelanggarannya menghasilkan kegagalan diam
yang sudah pernah terjadi di proyek ini:

1. **Satu guest per image.** UML memegang lock eksklusif (`F_SETLK`) pada image
   backing. Boot kedua pada image yang sama berjalan **tanpa disk** dan semua
   tulisan hilang. Gunakan image privat per instance, dan nyalakan
   `UML4TERMUXD_STRICT_UBD=1` agar pelanggaran jadi kegagalan eksplisit.
2. **Satu gvproxy per port ssh host.** gvproxy mem-bind `127.0.0.1:2222` tanpa
   syarat; instance kedua mati dengan `address already in use`. Atur
   `UML4TERMUXD_GVPROXY_SSH_PORT` per instance.
3. **Satu supervisor per lapisan.** Daemon mengawasi tumpukan guest; lapisan
   atas hanya menjaga daemon tetap hidup. Jangan menyusun dua supervisor pada
   level yang sama.

## 7. Kompatibilitas & perubahan

- **Penambahan** perintah/field: tidak menaikkan versi; klien lama harus tetap
  bekerja (field tak dikenal diabaikan).
- **Perubahan tak-kompatibel**: naikkan `protocol`, dan front end harus menolak
  berbicara dengan daemon yang lebih tua/lebih baru secara eksplisit.
- Nama berkas, path socket, dan exit code di dokumen ini adalah bagian dari
  kontrak — mengubahnya berarti perubahan tak-kompatibel.

## 8. Launcher dan registry instance

Kontrak ini dipakai `uml4termux up|down|status|logs|ls` (`lib/launch.sh`,
`lib/registry.sh`) — perintah yang menjalankan daemon **tanpa runit**:

- `up` menyalakan daemon, menunggu kesiapan §5, dan menulis catatan registry
  (`$UML4TERMUX_STATE_DIR/instances/<name>.env`: NAME, RUNTIME, IMAGE,
  SSH_PORT, PID, STARTED).
- `up` **menolak** tiga hal, bukan sekadar memperingatkan: image yang sudah
  dipakai instance hidup (invarian §6.1), port ssh host yang sudah dipegang
  (§6.2), dan direktori runtime milik instance lain.
- `--foreground` adalah kail adapter: supervisor apa pun (runit, systemd, s6)
  cukup meng-`exec` dan me-restart perintah itu.
- Liveness sebuah catatan = pid hidup **dan** socket instance menjawab
  `protocol`; catatan basi dibuang otomatis oleh `ls`/`down`.
- Port ssh default dipilih dari daftar bebas (2222, lalu 12222–12229) dan
  dicatat per instance, sehingga invarian §6.2 ditegakkan mesin, bukan ingatan.

## 9. Batas yang tidak dijanjikan

- Tidak ada **PID 1**: kontrak ini mengatur launcher, bukan boot Android.
- Tidak ada **D-Bus** di jalur kritis (opsional di masa depan, feature-gated).
- Tidak ada penjaminan **persistensi** di luar bagian runtime: state guest ada
  di COW/image, bukan di direktori runtime.
- Bukan janji **isolasi** terhadap kode guest: guest root = root di dalam guest.
