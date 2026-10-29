// SPDX-License-Identifier: GPL-2.0-only
//
// uml4termux-rs — Rust CLI, phase 1.
//
// Runs BESIDE the shell CLI (bin/uml4termux) so nothing regresses: the daemon
// protocol and the on-disk layout are identical, so either front end can talk
// to the same daemon. See docs/RUST-MIGRATION-AUDIT.md for scope.

mod assets;
mod client;
mod config;
mod cow;
mod fetch;

use assets::Asset;
use clap::{Parser, Subcommand};
use config::Config;
use std::path::PathBuf;
use std::process::ExitCode;

const VERSION: &str = env!("CARGO_PKG_VERSION");

#[derive(Parser)]
#[command(
    name = "uml4termux-rs",
    version = VERSION,
    about = "uml4termux Rust CLI (phase 1): daemon control + pinned-digest asset fetch",
    disable_help_subcommand = false
)]
struct Cli {
    /// Override the daemon control socket (default: $UML4TERMUX_RUNTIME/daemon.sock)
    #[arg(long, global = true, env = "UML4TERMUXD_SOCK")]
    socket: Option<PathBuf>,

    /// Print raw JSON instead of pretty-printing daemon replies
    #[arg(long, global = true)]
    raw: bool,

    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// Show guest/daemon state
    Status,
    /// Ask the daemon to stop the guest cleanly
    Stop,
    /// List persistent port exposures
    Ports,
    /// Run a command inside the guest through the console channel
    Exec {
        #[arg(required = true, trailing_var_arg = true, allow_hyphen_values = true)]
        argv: Vec<String>,
    },
    /// Publish a host port to a guest port (loopback only)
    Expose {
        host_port: String,
        guest_port: String,
    },
    /// Download runtime assets into $UML4TERMUX_HOME, verifying pinned digests
    Fetch {
        /// Re-download even when a verified copy exists
        #[arg(long)]
        force: bool,
        /// Comma-separated subset of: kernel,stub,daemon,disk,disk-gz,base-initramfs,gvproxy
        #[arg(long, value_delimiter = ',')]
        only: Option<Vec<String>>,
    },
    /// Verify an existing file against its pinned digest
    Verify {
        /// Asset id (kernel, stub, daemon, disk, base-initramfs, gvproxy)
        asset: String,
        /// File to check (default: the asset's install path)
        path: Option<PathBuf>,
    },
    /// Show the asset table: id, pinned digest, URL and local state
    Info,
    /// Write a UML v3 COW header for an image (byte-exact with the C daemon)
    CowHeader { cow: PathBuf, image: PathBuf },
}

fn main() -> ExitCode {
    let cli = Cli::parse();
    let cfg = Config::from_env();
    let sock = cli.socket.clone().unwrap_or_else(|| cfg.daemon_sock());

    match cli.cmd {
        Cmd::Status => daemon(&sock, client::status(&sock), cli.raw),
        Cmd::Stop => daemon(&sock, client::stop(&sock), cli.raw),
        Cmd::Ports => daemon(&sock, client::ports(&sock), cli.raw),
        Cmd::Exec { argv } => daemon(&sock, client::exec(&sock, &argv), cli.raw),
        Cmd::Expose {
            host_port,
            guest_port,
        } => daemon(
            &sock,
            client::expose(&sock, &host_port, &guest_port),
            cli.raw,
        ),
        Cmd::Fetch { force, only } => cmd_fetch(&cfg, force, only),
        Cmd::Verify { asset, path } => cmd_verify(&cfg, &asset, path),
        Cmd::Info => cmd_info(&cfg),
        Cmd::CowHeader { cow, image } => cmd_cow_header(&cow, &image),
    }
}

/// Exit code 3 on unreachable daemon matches the C client, so scripts can
/// treat both front ends interchangeably.
fn daemon(
    sock: &std::path::Path,
    reply: Result<String, client::ClientError>,
    raw: bool,
) -> ExitCode {
    match reply {
        Ok(r) => {
            let text = if raw { r.clone() } else { client::present(&r) };
            println!("{text}");
            // The daemon reports failures as {"error": ...} with exit 0;
            // signalling it through the exit code would change the contract.
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("{e}");
            eprintln!("hint: start it with `uml4termuxd daemon` or `sv start uml4termuxd`");
            let _ = sock;
            ExitCode::from(3)
        }
    }
}

fn cmd_fetch(cfg: &Config, force: bool, only: Option<Vec<String>>) -> ExitCode {
    let wanted = match only {
        None => Asset::default_set(),
        Some(ids) => {
            let mut out = Vec::new();
            for id in ids {
                match Asset::parse(id.trim()) {
                    Some(a) => out.push(a),
                    None => {
                        eprintln!("[err] unknown asset id: {id}");
                        return ExitCode::from(2);
                    }
                }
            }
            out
        }
    };

    let mut failed = 0usize;
    for asset in wanted {
        let dest = cfg.home.join(asset.file_name());
        match fetch::fetch_asset(asset, &dest, force) {
            Ok(_) => {}
            Err(e) => {
                eprintln!("[err] {}: {e}", asset.id());
                failed += 1;
            }
        }
    }
    if failed == 0 {
        ExitCode::SUCCESS
    } else {
        eprintln!("[err] {failed} asset(s) failed");
        ExitCode::FAILURE
    }
}

fn cmd_verify(cfg: &Config, id: &str, path: Option<PathBuf>) -> ExitCode {
    let asset = match Asset::parse(id) {
        Some(a) => a,
        None => {
            eprintln!("[err] unknown asset id: {id}");
            return ExitCode::from(2);
        }
    };
    let file = path.unwrap_or_else(|| cfg.home.join(asset.file_name()));
    if !file.is_file() {
        eprintln!("[err] not a file: {}", file.display());
        return ExitCode::FAILURE;
    }
    match fetch::verify_pin(asset, &file) {
        Ok(digest) => {
            eprintln!("[ok] sha256 ok  {}  {digest}", asset.id());
            println!("{digest}");
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("[err] {}", asset.id());
            eprintln!("[err] {e}");
            ExitCode::FAILURE
        }
    }
}

fn cmd_info(cfg: &Config) -> ExitCode {
    println!(
        "{:<16} {:<12} {:<10} pinned sha256 / note",
        "asset", "state", "size"
    );
    for asset in Asset::ALL {
        let dest = cfg.home.join(asset.file_name());
        let (state, size) = if dest.is_file() {
            let sz = std::fs::metadata(&dest).map(|m| m.len()).unwrap_or(0);
            ("present", human(sz))
        } else {
            ("missing", "-".to_string())
        };
        let pin = asset.pin();
        let note = if pin.is_empty() {
            "no pin (cross-check only)".to_string()
        } else {
            pin.to_string()
        };
        println!("{:<16} {:<12} {:<10} {}", asset.id(), state, size, note);
    }
    println!("\nUML4TERMUX_HOME = {}", cfg.home.display());
    println!("daemon socket   = {}", cfg.daemon_sock().display());
    ExitCode::SUCCESS
}

fn cmd_cow_header(cow: &std::path::Path, image: &std::path::Path) -> ExitCode {
    match cow::write_cow_header(cow, image) {
        Ok(h) => {
            eprintln!(
                "[ok] cow header written: {} (backing {}, {} bytes)",
                cow.display(),
                h.backing,
                h.size
            );
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("[err] cow header: {e}");
            ExitCode::FAILURE
        }
    }
}

fn human(bytes: u64) -> String {
    const UNITS: [&str; 5] = ["B", "KiB", "MiB", "GiB", "TiB"];
    let mut value = bytes as f64;
    let mut unit = 0;
    while value >= 1024.0 && unit < UNITS.len() - 1 {
        value /= 1024.0;
        unit += 1;
    }
    format!("{value:.1} {}", UNITS[unit])
}

#[cfg(test)]
mod tests {
    use super::human;

    #[test]
    fn human_sizes() {
        assert_eq!(human(512), "512.0 B");
        assert_eq!(human(2048), "2.0 KiB");
        assert_eq!(human(222_203), "217.0 KiB");
    }
}
