# Model ancaman uml4termux

Dokumen ini menjawab satu pertanyaan: **terhadap siapa uml4termux melindungi apa,
dan terhadap siapa ia tidak bisa melindungi apa pun.** Ia sengaja sempit dan tidak
menjanjikan lebih dari yang ditegakkan kode. Setiap kontrol menyebut di mana ia
hidup dan tes mana yang menegakkannya; yang tidak ditegakkan disebut sebagai
risiko sisa, bukan dihilangkan dari daftar.

Berlaku untuk: daemon (`src/uml4termuxd.c`, `rust/src/daemon.rs`), launcher
(`lib/*.sh`), `fetch`, dan guest UML. Tidak berlaku untuk aplikasi lain di HP.

---

## 1. Aset yang dilindungi

| Aset | Mengapa |
|---|---|
| Data aplikasi Termux: `~/.ssh`, `~/.hermes/.env`, `~/workspace` | Ini yang ada di luar guest dan tidak boleh bisa dibaca atau diubah dari dalam guest |
| Integritas artefak rilis (kernel, image, stub, daemon, gvproxy) | Guest menjalankan kernel dan image; artefak palsu = kode asing dengan hak root di dalam guest |
| Permukaan jaringan HP | Guest tidak boleh membuka port ke LAN/internet tanpa keputusan operator |
| Data di dalam guest (container, volume) | Tidak boleh bocor ke guest lain, dan tidak boleh diam-diam ditimpa |
| Jejak audit | Setelah kejadian, harus ada catatan perintah apa yang dijalankan |

## 2. Aktor dan kemampuannya

**A. Proses lain dengan uid yang SAMA di HP (aplikasi Termux itu sendiri).**
Android memberi satu uid per aplikasi, dan semua yang berjalan di Termux berbagi
uid itu. Aktor ini **tidak bisa** ditahan oleh uml4termux: ia bisa membaca
`~/.ssh` dan menulis ke `~/workspace` tanpa menyentuh uml4termux sama sekali.
Yang bisa dilakukan uml4termux hanyalah membuat **kecelakaan** terlihat: socket
milik pemilik saja, batas laju, dan log audit.

**B. Kode di dalam guest (container, image pihak ketiga).**
Guest root = root **di dalam guest**. Ia tidak punya jalur ke filesystem host
kecuali lewat apa yang sengaja dibuka. Batasnya:

- `hostfs` **tidak dipakai** dan tidak boleh dipakai untuk kode tak tepercaya: itu
  jalur langsung ke filesystem Termux.
- Jaringan guest hanya lewat gvproxy; exposure hanya ke `127.0.0.1` host, dan hanya
  port yang diminta operator.
- Guest tidak bisa menyalakan guest lain: satu guest per image ditegakkan
  `F_SETLK`, satu runtime per instance, satu gvproxy per port ssh.

**C. Rekan di jaringan (LAN, internet, host lain).**
Tidak ada yang mendengarkan di alamat non-loopback secara default:
gvproxy mem-bind `127.0.0.1`, endpoint HTTP kesehatan default `127.0.0.1`. Port
masuk dari host sungguhan pernah diuji dan **diblokir** oleh sandbox Android, jadi
jalur masuknya adalah loopback HP itu sendiri.

**D. Mirror/artefak yang tidak jujur (supply chain).**
Ini yang paling mungkin dan paling murah ditutup. Dua lapis:

1. **Digest ter-pin** (`lib/common.sh`): byte yang dijalankan harus cocok dengan
   digest yang tertanam di build ini — fail closed.
2. **Tanda tangan atas `SHA256SUMS`** (`lib/security.sh` + `packaging/keys/`):
   membuat daftar digest itu *dapat diatribusikan*, karena pin tinggal di pohon
   yang sama dengan kode sehingga siapa pun yang bisa menulis di sini bisa
   menulis ulang keduanya. Tanda tangan yang salah **fatal**, bukan alasan jatuh
   ke pin.

## 3. Yang dilindungi vs yang tidak

| Klaim | Status |
|---|---|
| Guest tidak bisa membaca filesystem Termux | **Ya**, selama `hostfs` tidak dipakai; tidak ada kontrol lain yang diperlukan |
| Guest tidak membuka port ke LAN tanpa diminta | **Ya**: bind loopback, exposure eksplisit |
| Artefak yang dijalankan adalah yang dipublikasikan | **Ya** untuk digest; **ya** untuk atribusi selama kunci rilis tidak bocor |
| Kode di guest tidak bisa keluar dari guest | **Tidak dijanjikan.** yang dijanjikan adalah ia tidak punya jalur langsung ke host |
| Proses lain ber-uid sama tidak bisa mengganggu | **Tidak.** Tidak ada isolasi antar-proses ber-uid sama di Android |
| Data guest terenkripsi saat diam | **Tidak.** Image dan COW adalah berkas biasa di `~/.uml4termux` |
| Guest tidak bisa menghabiskan baterai/CPU HP | **Sebagian**: `mem=`, `ncpus=`, dan `io.max` dibatasi; tidak ada penjadwalan CPU host |

## 4. Kontrol, lokasi, dan tes penegaknya

| Kontrol | Di mana | Ditegakkan oleh |
|---|---|---|
| Socket hanya untuk pemilik | `chmod 0600` + `umask 0077` sebelum `bind()` di daemon | `tests/test-daemon-security.sh` (mode 600, direktori 700) |
| Koneksi dari uid lain ditolak daemon | `SO_PEERCRED` → `peer_is_owner()` (C dan Rust) | `tests/test-daemon-security.sh` (dijalankan sebagai root: daemon milik user lain, klien root ditolak `not the owner`) |
| `exec` tidak bisa dibanjiri | `UML4TERMUXD_EXEC_MIN_INTERVAL_MS` (default 100 ms) + balasan `rate-limited` | idem: dua exec berurutan, yang kedua ditolak |
| Jejak perintah | `audit.log` (`0600`), satu baris per kejadian, byte kontrol dinetralkan | idem: isi baris, hitungan baris, injeksi ESC, dan `stop` |
| Digest artefak ter-pin | `lib/common.sh` (tabel pin) | `ci/local-ci.sh`, job `dist` |
| Tanda tangan `SHA256SUMS` | `lib/security.sh`, dipanggil `lib/fetch.sh` sebelum sums dipakai | `tests/test-signature.sh` (kunci salah, sums diubah sesudah ditandatangani, tanpa tanda tangan saat wajib) |
| Batas memori/CPU per guest | `mem=`, `ncpus=` pada argv kernel | `soak/limits-check.sh` di device (dua boot) |
| Batas I/O per cgroup | cgroup v2 `io.max` di dalam guest | idem (`rbps=1048576` diterima dan terbaca kembali) |
| Satu guest per image | `F_SETLK` UML + launcher menolak image yang dipakai | `tests/test-launcher.sh` |
| Exposure hanya loopback | gvproxy + `expose` | `tests/test-expose-routing.sh` |

## 5. Risiko sisa (jangan dibaca sebagai "aman")

1. **Kunci rilis yang bocor** membatalkan atribusi. Rotasi kunci = ganti
   `packaging/keys/release.pub.pem` dan publikasikan ulang artefak.
2. **Aktor ber-uid sama** bisa melakukan apa saja, termasuk memalsukan audit log
   atau mengganti biner. Audit dirancang untuk operator yang jujur, bukan untuk
   menahan penyerang dengan uid yang sama.
3. **Guest root adalah root di dalam guest.** Container dengan hak penuh di dalam
   guest bisa menghabiskan sumber daya guest; `mem=`/`ncpus=` membatasi guest,
   bukan container di dalamnya.
4. **Tidak ada isolasi kernel tambahan**: tidak ada seccomp filter kustom,
   Landlock, atau namespace host. Yang ada adalah mode `seccomp=on` bawaan UML.
5. **Endpoint HTTP `GET /status`** (bila `UML4TERMUXD_HTTP` dinyalakan) **tanpa
   autentikasi** di loopback: siapa pun yang bisa bicara ke `127.0.0.1` di HP itu
   bisa membacanya.
6. **Tanda tangan hanya menutup `SHA256SUMS`**, bukan setiap artefak satu per satu:
   kepercayaan berpindah ke kunci, bukan hilang.

## 6. Yang tidak boleh dijanjikan ke pengguna lain

- "Guest terisolasi dari HP" — tidak; yang benar: guest tidak punya jalur langsung
  ke filesystem Termux, dan hanya bisa keluar lewat port yang di-expose.
- "Aman menjalankan image apa pun" — tidak; gambar pihak ketiga berarti kode asing
  dengan root di dalam guest, dan kernel UML adalah bagian dari permukaan itu.
- "Terenkripsi" — tidak; image dan COW adalah berkas biasa.
- "Audit log tahan manipulasi" — tidak; ia berkas milik uid yang sama.