// SPDX-License-Identifier: GPL-2.0-only
//
// Asset table: file names, download URLs and PINNED digests, ported from
// lib/common.sh. The pin is the authority (fail closed); an upstream
// SHA256SUMS file is only ever an additional cross-check.

use std::env;

fn env_nonempty(key: &str) -> Option<String> {
    env::var(key).ok().filter(|v| !v.is_empty())
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Asset {
    Kernel,
    Stub,
    Daemon,
    Disk,
    DiskGz,
    BaseInitramfs,
    Gvproxy,
}

impl Asset {
    pub const ALL: [Asset; 7] = [
        Asset::Kernel,
        Asset::Stub,
        Asset::Daemon,
        Asset::Disk,
        Asset::DiskGz,
        Asset::BaseInitramfs,
        Asset::Gvproxy,
    ];

    /// Stable identifier used by --only and by state/evidence files.
    pub fn id(self) -> &'static str {
        match self {
            Asset::Kernel => "kernel",
            Asset::Stub => "stub",
            Asset::Daemon => "daemon",
            Asset::Disk => "disk",
            Asset::DiskGz => "disk-gz",
            Asset::BaseInitramfs => "base-initramfs",
            Asset::Gvproxy => "gvproxy",
        }
    }

    pub fn parse(s: &str) -> Option<Asset> {
        Asset::ALL.into_iter().find(|a| a.id() == s)
    }

    /// File name inside $UML4TERMUX_HOME (env-overridable where the shell
    /// allows it, so a user can run two versions side by side).
    pub fn file_name(self) -> String {
        match self {
            Asset::Kernel => {
                env_nonempty("UML4TERMUX_KERNEL_FILE").unwrap_or_else(|| "linux-bionic".into())
            }
            Asset::Stub => "stub_exe".into(),
            Asset::Daemon => {
                env_nonempty("UML4TERMUXD_FILE").unwrap_or_else(|| "uml4termuxd".into())
            }
            Asset::Disk => "debian-docker.ext4".into(),
            Asset::DiskGz => "debian-docker.ext4.gz".into(),
            Asset::BaseInitramfs => "initramfs-alpine.cpio.gz".into(),
            Asset::Gvproxy => "gvproxy".into(),
        }
    }

    fn release_base() -> String {
        env_nonempty("UML4TERMUX_RELEASE_BASE_URL").unwrap_or_else(|| {
            "https://github.com/michaelamoetoevsky/uml4termux/releases/download/v0.5.0".into()
        })
    }

    fn upstream_base() -> String {
        env_nonempty("UML4TERMUX_UPSTREAM_BASE_URL").unwrap_or_else(|| {
            "https://github.com/zalexdev/linux-um-arm64/releases/download/prebuilt-20260816".into()
        })
    }

    fn gvproxy_base() -> String {
        env_nonempty("UML4TERMUX_GVPROXY_BASE_URL").unwrap_or_else(|| {
            "https://github.com/containers/gvisor-tap-vsock/releases/download/v0.9.0".into()
        })
    }

    pub fn url(self) -> String {
        match self {
            Asset::Kernel => env_nonempty("UML4TERMUX_KERNEL_URL")
                .unwrap_or_else(|| format!("{}/linux-bionic", Self::release_base())),
            Asset::Stub => env_nonempty("UML4TERMUX_STUB_URL")
                .unwrap_or_else(|| format!("{}/stub_exe", Self::release_base())),
            Asset::Daemon => env_nonempty("UML4TERMUXD_URL")
                .unwrap_or_else(|| format!("{}/uml4termuxd", Self::release_base())),
            Asset::Disk => env_nonempty("UML4TERMUX_DISK_URL")
                .unwrap_or_else(|| format!("{}/debian-docker.ext4.gz", Self::upstream_base())),
            Asset::DiskGz => env_nonempty("UML4TERMUX_DISK_URL")
                .unwrap_or_else(|| format!("{}/debian-docker.ext4.gz", Self::upstream_base())),
            Asset::BaseInitramfs => env_nonempty("UML4TERMUX_BASE_INITRAMFS_URL")
                .unwrap_or_else(|| format!("{}/initramfs-alpine.cpio.gz", Self::upstream_base())),
            Asset::Gvproxy => env_nonempty("UML4TERMUX_GVPROXY_URL")
                .unwrap_or_else(|| format!("{}/gvproxy-linux-arm64", Self::gvproxy_base())),
        }
    }

    /// Pinned digest (lowercase hex). Empty means "no pin": such an asset can
    /// only be cross-checked against an upstream SHA256SUMS file.
    pub fn pin(self) -> &'static str {
        match self {
            Asset::Kernel => env_pin(
                "UML4TERMUX_KERNEL_SHA256",
                "6970ada592e49c03f90e1b422ffb38ea0ceced9d9d1de1c5120542126a426c02",
            ),
            Asset::Stub => env_pin(
                "UML4TERMUX_STUB_SHA256",
                "731c48d5bf42ef25e26625af6a02627a5d658bf9f67d6f7fc443d6d644d6e52e",
            ),
            Asset::Daemon => env_pin(
                "UML4TERMUXD_SHA256",
                "d86f1c4d41f7ac7ce30841137fa291737d18e8b2d2a68a2b7de48f6696e34335",
            ),
            // The published pin covers the .gz: debian-docker.ext4 is produced
            // by decompressing it, so there is nothing to compare before that.
            Asset::Disk => "",
            Asset::DiskGz => env_pin(
                "UML4TERMUX_DISK_SHA256",
                "2807979f76021fadf1f76f0c827fbe1eab4df51e33bfeca0c840c5181c610be3",
            ),
            Asset::BaseInitramfs => env_pin(
                "UML4TERMUX_BASE_INITRAMFS_SHA256",
                "15238a37328b99b3206a58c7ab69b853139c40b8ca35f8acacf6226a4c1cf94f",
            ),
            Asset::Gvproxy => env_pin(
                "UML4TERMUX_GVPROXY_SHA256",
                "c1ea864636182a774235c8866c70f2a0223dfcd4f08d24e37a7e82d9882beb9c",
            ),
        }
    }

    pub fn executable(self) -> bool {
        !matches!(self, Asset::Disk | Asset::DiskGz | Asset::BaseInitramfs)
    }

    /// Assets fetched by default: the small, security-critical ones. The
    /// multi-hundred-MB disk image stays opt-in (--only disk-gz).
    pub fn default_set() -> Vec<Asset> {
        vec![Asset::Kernel, Asset::Stub, Asset::Daemon, Asset::Gvproxy]
    }
}

/// Compile-time defaults with a runtime override, leaked to 'static so the
/// table stays allocation-free and testable.
fn env_pin(key: &str, default: &'static str) -> &'static str {
    match env::var(key) {
        Ok(v) if !v.trim().is_empty() => Box::leak(v.trim().to_string().into_boxed_str()),
        _ => default,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ids_round_trip() {
        for a in Asset::ALL {
            assert_eq!(Asset::parse(a.id()), Some(a));
        }
        assert_eq!(Asset::parse("nope"), None);
    }

    #[test]
    fn pins_are_hex64_or_empty() {
        for a in Asset::ALL {
            let p = a.pin();
            if matches!(a, Asset::Disk) {
                assert!(p.is_empty(), "disk (decompressed) must have no pin");
            } else {
                assert_eq!(p.len(), 64, "{} pin must be 64 hex chars", a.id());
                assert!(
                    p.chars().all(|c| c.is_ascii_hexdigit()),
                    "{} pin not hex",
                    a.id()
                );
            }
        }
    }

    #[test]
    fn urls_are_https() {
        for a in Asset::ALL {
            assert!(
                a.url().starts_with("https://"),
                "{} url must be https",
                a.id()
            );
        }
    }
}
