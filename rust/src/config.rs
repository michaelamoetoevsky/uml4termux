// SPDX-License-Identifier: GPL-2.0-only
//
// Paths and environment defaults, ported 1:1 from lib/common.sh so the Rust
// CLI and the shell CLI resolve to the same directories and sockets.

use std::path::{Path, PathBuf};

fn env_nonempty(key: &str) -> Option<String> {
    std::env::var(key).ok().filter(|v| !v.is_empty())
}

#[derive(Debug, Clone)]
// Fields beyond the socket paths are consumed by later phases (state, logs,
// initramfs, guest IP); keeping them here means one source of truth now.
#[allow(dead_code)]
pub struct Config {
    pub prefix: PathBuf,
    pub home: PathBuf,
    pub state_dir: PathBuf,
    pub log_dir: PathBuf,
    pub runtime: PathBuf,
    pub initramfs_dir: PathBuf,
    pub guest_ip: String,
}

impl Config {
    pub fn from_env() -> Self {
        // Termux has no /usr/bin/env and no /etc/resolv.conf; $PREFIX is
        // normally exported. Fall back to the Termux prefix when it exists,
        // otherwise to a harmless /usr (same rule as lib/common.sh).
        let prefix = env_nonempty("PREFIX")
            .map(PathBuf::from)
            .unwrap_or_else(|| {
                let termux = Path::new("/data/data/com.termux/files/usr");
                if termux.is_dir() {
                    termux.to_path_buf()
                } else {
                    PathBuf::from("/usr")
                }
            });

        let home_dir = env_nonempty("HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("."));

        let data_base = env_nonempty("XDG_DATA_HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|| home_dir.join(".local/share"));
        let state_base = env_nonempty("XDG_STATE_HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|| home_dir.join(".local/state"));

        let home = env_nonempty("UML4TERMUX_HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|| data_base.join("uml4termux"));
        let state_dir = env_nonempty("UML4TERMUX_STATE_DIR")
            .map(PathBuf::from)
            .unwrap_or_else(|| state_base.join("uml4termux"));
        let log_dir = env_nonempty("UML4TERMUX_LOG_DIR")
            .map(PathBuf::from)
            .unwrap_or_else(|| state_dir.join("logs"));
        let runtime = env_nonempty("UML4TERMUX_RUNTIME")
            .map(PathBuf::from)
            .unwrap_or_else(|| std::env::temp_dir().join("uml4termux"));
        let initramfs_dir = env_nonempty("UML4TERMUX_INITRAMFS_DIR")
            .map(PathBuf::from)
            .unwrap_or_else(|| state_dir.join("initramfs"));
        let guest_ip =
            env_nonempty("UML4TERMUX_GUEST_IP").unwrap_or_else(|| "192.168.127.2".to_string());

        Config {
            prefix,
            home,
            state_dir,
            log_dir,
            runtime,
            initramfs_dir,
            guest_ip,
        }
    }

    /// The daemon's control socket (see sock_path() in src/uml4termuxd.c).
    pub fn daemon_sock(&self) -> PathBuf {
        self.runtime.join("daemon.sock")
    }

    /// gvproxy's control socket (used by phase 2; kept here so both front
    /// ends agree on the path).
    #[allow(dead_code)]
    pub fn gvnet_sock(&self) -> PathBuf {
        self.runtime.join("gvnet.sock")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn socket_paths_follow_runtime() {
        // Pure computation: build a Config by hand to avoid env races.
        let cfg = Config {
            prefix: PathBuf::from("/usr"),
            home: PathBuf::from("/h"),
            state_dir: PathBuf::from("/s"),
            log_dir: PathBuf::from("/s/logs"),
            runtime: PathBuf::from("/tmp/uml4termux"),
            initramfs_dir: PathBuf::from("/s/initramfs"),
            guest_ip: "192.168.127.2".to_string(),
        };
        assert_eq!(
            cfg.daemon_sock(),
            PathBuf::from("/tmp/uml4termux/daemon.sock")
        );
        assert_eq!(
            cfg.gvnet_sock(),
            PathBuf::from("/tmp/uml4termux/gvnet.sock")
        );
    }
}
