// SPDX-License-Identifier: GPL-2.0-only
//
// Daemon control client: one newline-terminated command in, one JSON line out.
// Wire format is unchanged from src/uml4termuxd.c (handle_client), so the Rust
// CLI and the C client are interchangeable against the same daemon.

use std::io::{self, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::time::Duration;

const MAX_RESPONSE: u64 = 1 << 20;
const TIMEOUT: Duration = Duration::from_secs(10);

#[derive(Debug)]
pub enum ClientError {
    Unreachable(String, io::Error),
    Io(io::Error),
}

impl std::fmt::Display for ClientError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ClientError::Unreachable(path, e) => {
                write!(f, "daemon not reachable at {path}: {e}")
            }
            ClientError::Io(e) => write!(f, "{e}"),
        }
    }
}

/// Send one command line and return the daemon's reply (trailing newline
/// trimmed). The caller decides how to present the JSON.
pub fn request(sock: &Path, line: &str) -> Result<String, ClientError> {
    let mut stream = UnixStream::connect(sock)
        .map_err(|e| ClientError::Unreachable(sock.display().to_string(), e))?;
    stream
        .set_read_timeout(Some(TIMEOUT))
        .map_err(ClientError::Io)?;
    stream
        .set_write_timeout(Some(TIMEOUT))
        .map_err(ClientError::Io)?;

    let mut payload = String::with_capacity(line.len() + 1);
    payload.push_str(line);
    payload.push('\n');
    stream
        .write_all(payload.as_bytes())
        .map_err(ClientError::Io)?;
    stream.flush().map_err(ClientError::Io)?;
    // The daemon answers once and closes; half-close lets it see EOF early.
    let _ = stream.shutdown(std::net::Shutdown::Write);

    let mut out = String::new();
    stream
        .take(MAX_RESPONSE)
        .read_to_string(&mut out)
        .map_err(ClientError::Io)?;
    Ok(out.trim_end_matches(['\n', '\r']).to_string())
}

/// Pretty-print a JSON reply when it parses; otherwise emit it verbatim so a
/// malformed answer from an old daemon is still visible instead of swallowed.
pub fn present(reply: &str) -> String {
    match serde_json::from_str::<serde_json::Value>(reply) {
        Ok(v) => serde_json::to_string_pretty(&v).unwrap_or_else(|_| reply.to_string()),
        Err(_) => reply.to_string(),
    }
}

pub fn status(sock: &Path) -> Result<String, ClientError> {
    request(sock, "status")
}

pub fn stop(sock: &Path) -> Result<String, ClientError> {
    request(sock, "stop")
}

pub fn ports(sock: &Path) -> Result<String, ClientError> {
    request(sock, "ports")
}

pub fn exec(sock: &Path, cmd: &[String]) -> Result<String, ClientError> {
    request(sock, &format!("exec {}", cmd.join(" ")))
}

pub fn expose(sock: &Path, host_port: &str, guest_port: &str) -> Result<String, ClientError> {
    request(sock, &format!("expose {host_port} {guest_port}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::BufRead;
    use std::os::unix::net::UnixListener;
    use std::path::PathBuf;

    fn temp_sock(tag: &str) -> PathBuf {
        std::env::temp_dir().join(format!(
            "u4t-test-{tag}-{}-{}.sock",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .subsec_nanos()
        ))
    }

    /// A fake daemon: records the command line it received, replies once.
    fn serve_once(path: &Path, reply: &'static str) -> std::thread::JoinHandle<String> {
        let listener = UnixListener::bind(path).expect("bind");
        std::thread::spawn(move || {
            let (stream, _) = listener.accept().expect("accept");
            let mut line = String::new();
            let mut r = std::io::BufReader::new(stream);
            r.read_line(&mut line).expect("read");
            let mut w = r.into_inner();
            w.write_all(reply.as_bytes()).expect("write");
            w.flush().ok();
            line.trim_end().to_string()
        })
    }

    #[test]
    fn exec_joins_argv_on_one_line() {
        let p = temp_sock("exec");
        let h = serve_once(&p, "{\"started\":true,\"seq\":1}\n");
        let out = exec(&p, &["uname".into(), "-a".into()]).expect("exec");
        let got = h.join().expect("join");
        assert_eq!(got, "exec uname -a");
        assert_eq!(out, "{\"started\":true,\"seq\":1}");
        std::fs::remove_file(&p).ok();
    }

    #[test]
    fn expose_sends_two_ports() {
        let p = temp_sock("expose");
        let h = serve_once(&p, "{\"exposed\":\"127.0.0.1:8124 -> 192.168.127.2:80\"}\n");
        let _ = expose(&p, "8124", "80").expect("expose");
        assert_eq!(h.join().unwrap(), "expose 8124 80");
        std::fs::remove_file(&p).ok();
    }

    #[test]
    fn unreachable_is_reported_as_such() {
        let p = temp_sock("none");
        match status(&p) {
            Err(ClientError::Unreachable(path, _)) => assert!(path.contains("u4t-test-none")),
            other => panic!("expected Unreachable, got {other:?}"),
        }
    }

    #[test]
    fn malformed_reply_is_passed_through() {
        assert_eq!(present("not json"), "not json");
        let pretty = present("{\"state\":\"running\"}");
        assert!(pretty.contains("\"state\""));
        assert!(pretty.contains("running"));
    }
}
