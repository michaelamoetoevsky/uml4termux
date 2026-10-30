// SPDX-License-Identifier: GPL-2.0-only
//
// UML copy-on-write header (v3, "bitmap" format), byte-exact port of
// write_cow_header_file() in src/uml4termuxd.c.
//
// Layout (all big-endian, packed -- 4128 bytes total):
//   0    magic "MOOO"
//   4    version      u32 = 3
//   8    backing mtime u32
//   12   backing size  u64
//   20   sector size   u32 = 512
//   24   alignment     u32 = 512
//   28   cow format    u32 = 0 (COW_BITMAP)
//   32   backing path, NUL padded to 4096 bytes
//
// The file then stays sparse: EOF is poked to
//   round_up(4128, 512) + size/4096 + size - 1
// which leaves the whole bitmap zeroed without writing it.

use std::fs::{self, OpenOptions};
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::os::unix::fs::PermissionsExt;
use std::path::Path;

// On-disk magic is the LITTLE-endian encoding of the u32 0x4D4F4F4F ("MOOO"
// read as a big-endian word), i.e. the bytes 4F 4F 4F 4D. UML writes/reads it
// as a native __u32, which is why the byte order looks reversed in a hex dump.
pub const MAGIC: [u8; 4] = [0x4f, 0x4f, 0x4f, 0x4d];
pub const VERSION: u32 = 3;
pub const SECTOR_SIZE: u32 = 512;
pub const ALIGNMENT: u32 = 512;
pub const COW_FORMAT_BITMAP: u32 = 0;
pub const PATH_LEN: usize = 4096;
pub const HEADER_LEN: usize = 12 + 8 + 12 + PATH_LEN; // 4128
/// round_up(HEADER_LEN, SECTOR_SIZE)
pub const DATA_START: u64 = 4608;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CowHeader {
    pub mtime: u32,
    pub size: u64,
    pub backing: String,
}

impl CowHeader {
    pub fn new(backing: &str, size: u64, mtime: u32) -> Self {
        CowHeader {
            mtime,
            size,
            backing: backing.to_string(),
        }
    }

    /// Serialize to the exact on-disk v3 header.
    pub fn to_bytes(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(HEADER_LEN);
        out.extend_from_slice(&MAGIC);
        out.extend_from_slice(&VERSION.to_be_bytes());
        out.extend_from_slice(&self.mtime.to_be_bytes());
        out.extend_from_slice(&self.size.to_be_bytes());
        out.extend_from_slice(&SECTOR_SIZE.to_be_bytes());
        out.extend_from_slice(&ALIGNMENT.to_be_bytes());
        out.extend_from_slice(&COW_FORMAT_BITMAP.to_be_bytes());

        // Backing path: at most PATH_LEN-1 bytes plus a NUL, exactly as
        // strncpy(hdr + 32, absimage, sizeof(hdr) - 32 - 1) does.
        let raw = self.backing.as_bytes();
        let take = raw.len().min(PATH_LEN - 1);
        out.extend_from_slice(&raw[..take]);
        out.resize(HEADER_LEN, 0);
        debug_assert_eq!(out.len(), HEADER_LEN);
        out
    }

    /// Byte offset of the last byte of the data area (EOF after the poke).
    pub fn eof_offset(&self) -> u64 {
        let bitmap_len = self.size / 4096; // (size / 512) / 8
        DATA_START + bitmap_len + self.size - 1
    }
}

/// Write the header for `image` into `cow`, leaving the file sparse.
/// Mirrors the C function: realpath(), stat(), header, then the EOF poke.
/// What the boot path did with the COW: reused an existing header (resume) or
/// wrote a fresh one (clean state).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CowEnsure {
    Reused,
    Written,
}

/// True when `cow` already carries a v3 header this code wrote; mirrors
/// cow_is_formatted() in src/uml4termuxd.c.
pub fn cow_is_formatted(cow: &Path) -> bool {
    let Ok(mut f) = fs::File::open(cow) else {
        return false;
    };
    let Ok(meta) = f.metadata() else {
        return false;
    };
    if meta.len() < HEADER_LEN as u64 {
        return false;
    }
    let mut head = [0u8; 8];
    if f.read_exact(&mut head).is_err() {
        return false;
    }
    head[0..4] == MAGIC && head[4..8] == [0, 0, 0, VERSION as u8]
}

/// Boot-path policy: never overwrite a valid header, because a COW staged by
/// the launcher is exactly the state a resume means to boot from.
pub fn ensure_cow_header(cow: &Path, image: &Path) -> io::Result<CowEnsure> {
    if cow_is_formatted(cow) {
        return Ok(CowEnsure::Reused);
    }
    write_cow_header(cow, image).map(|_| CowEnsure::Written)
}

pub fn write_cow_header(cow: &Path, image: &Path) -> io::Result<CowHeader> {
    let abs = fs::canonicalize(image)?;
    let meta = fs::metadata(&abs)?;
    let backing = abs
        .to_str()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "backing path is not UTF-8"))?
        .to_string();
    let header = CowHeader::new(&backing, meta.len(), mtime_u32(&meta));

    if let Some(parent) = cow.parent() {
        if !parent.as_os_str().is_empty() {
            fs::create_dir_all(parent)?;
        }
    }
    let mut f = OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .open(cow)?;
    // open(..., 0644): the daemon runs under umask 0077, so this is the same
    // effective mode the C code ends up with.
    f.set_permissions(fs::Permissions::from_mode(0o644))?;
    f.write_all(&header.to_bytes())?;

    let eof = header.eof_offset();
    f.seek(SeekFrom::Start(eof))?;
    f.write_all(&[0u8])?;
    f.sync_all()?;
    Ok(header)
}

fn mtime_u32(meta: &fs::Metadata) -> u32 {
    use std::os::unix::fs::MetadataExt;
    meta.mtime() as u32
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::MetadataExt;

    #[test]
    fn layout_is_packed_and_big_endian() {
        let h = CowHeader::new("/data/base.ext4", 3_221_301_248, 0x11223344);
        let b = h.to_bytes();
        assert_eq!(b.len(), 4128);
        assert_eq!(&b[0..4], &MAGIC);
        assert_eq!(&b[4..8], &3u32.to_be_bytes());
        assert_eq!(&b[8..12], &0x11223344u32.to_be_bytes());
        assert_eq!(&b[12..20], &3_221_301_248u64.to_be_bytes());
        assert_eq!(&b[20..24], &512u32.to_be_bytes());
        assert_eq!(&b[24..28], &512u32.to_be_bytes());
        assert_eq!(&b[28..32], &0u32.to_be_bytes());
        assert_eq!(&b[32..32 + 16], b"/data/base.ext4\0");
        // Everything after the path is zero.
        assert!(b[32 + 17..].iter().all(|&x| x == 0));
    }

    #[test]
    fn eof_math_matches_c() {
        // bitmap = size/4096; eof = 4608 + bitmap + size - 1
        let h = CowHeader::new("/x", 3_221_301_248, 0);
        assert_eq!(
            h.eof_offset(),
            4608 + 3_221_301_248 / 4096 + 3_221_301_248 - 1
        );
        let small = CowHeader::new("/x", 0, 0);
        // size 0 -> bitmap 0, so EOF sits one byte before DATA_START.
        assert_eq!(small.eof_offset(), 4607);
    }

    #[test]
    fn long_path_is_truncated_at_4095_bytes_plus_nul() {
        let long = format!("/{}", "a".repeat(5000));
        let h = CowHeader::new(&long, 512, 0);
        let b = h.to_bytes();
        assert_eq!(b.len(), 4128);
        assert_eq!(b[32 + 4095], 0, "byte 4095 of the path field must be NUL");
    }

    #[test]
    fn write_produces_sparse_file_with_expected_size_and_header() {
        let d = std::env::temp_dir().join(format!(
            "u4t-cow-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .subsec_nanos()
        ));
        fs::create_dir_all(&d).unwrap();
        let img = d.join("base.ext4");
        fs::write(&img, vec![0u8; 2 * 1024 * 1024]).unwrap();
        let cow = d.join("guest.cow");

        let h = write_cow_header(&cow, &img).unwrap();
        let meta = fs::metadata(&cow).unwrap();
        assert_eq!(meta.len(), h.eof_offset() + 1);
        assert_eq!(meta.mtime(), fs::metadata(&img).unwrap().mtime());

        let bytes = fs::read(&cow).unwrap();
        assert_eq!(&bytes[0..4], &MAGIC);
        assert_eq!(&bytes[12..20], &(2 * 1024 * 1024u64).to_be_bytes());
        let path = String::from_utf8_lossy(&bytes[32..32 + 200]);
        assert!(path.starts_with(img.to_str().unwrap()));

        fs::remove_dir_all(&d).ok();
    }
}
