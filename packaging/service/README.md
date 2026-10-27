# uml4termuxd — menjalankan UML sebagai service runit

UML guest sebagai **service binary** yang diawasi runit: runit menjalankan
run script, run script mengeksekusi daemon, daemon mengawasi gvproxy +
kernel, dan klien bicara lewat control socket.

## Struktur

```
packaging/service/run.uml4termuxd    # runit run script (exec daemon)
packaging/service/daemon.conf.example # konfigurasi (KEY=VALUE, auto-export)
packaging/service/log.run            # log service (svlogd)
```

## Pasang

```sh
# 1. binary + aset
mkdir -p ~/.uml4termux/bin ~/.uml4termux/assets ~/.uml4termux/runtime
cp bin/uml4termuxd ~/.uml4termux/bin/
# taruh linux-bionic, stub_exe, debian-docker.ext4, initramfs-docker.cpio.gz,
# gvproxy di ~/.uml4termux/assets/

# 2. konfigurasi
cp packaging/service/daemon.conf.example ~/.uml4termux/daemon.conf
nano ~/.uml4termux/daemon.conf   # sesuaikan path

# 3. service runit
mkdir -p $PREFIX/var/service/uml4termuxd $PREFIX/var/log/sv/uml4termuxd \
         $PREFIX/var/service/uml4termuxd/log
cp packaging/service/run.uml4termuxd $PREFIX/var/service/uml4termuxd/run
cp packaging/service/log.run         $PREFIX/var/service/uml4termuxd/log/run
chmod +x $PREFIX/var/service/uml4termuxd/run \
         $PREFIX/var/service/uml4termuxd/log/run
sv up uml4termuxd

# 4. kontrol
export UML4TERMUX_RUNTIME=$HOME/.uml4termux/runtime
uml4termuxd status | ports | console | exec <cmd>
sv down uml4termuxd     # shutdown bersih (kernel+gvproxy ikut mati)
```

## Catatan operasional

- **Port 2222**: gvproxy mem-bind `127.0.0.1:2222` (forward SSH default).
  Hanya SATU gvproxy boleh hidup per device; daemon akan gagal dengan error
  jelas bila port bentrok.
- **gvproxy via proot** (Termux): daemon membungkus gvproxy dengan
  `proot -b $PREFIX/etc:/etc` otomatis (butuh /etc/resolv.conf). Daemon
  mem-bunuh **process group** saat shutdown — proot + gvproxy tracee keduanya
  ikut mati (bug deadlock lama sudah diperbaiki, lihat commit A3/A4).
- **Sesi bersih**: guest yang `poweroff` (exit 0) dilaporkan `completed` dan
  TIDAK di-restart; crash → restart backoff cap-5; exec gagal → fatal.
- Wake-lock diambil run script dan dilepas otomatis saat proses mati.
