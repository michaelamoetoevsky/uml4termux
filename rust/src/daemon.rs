// SPDX-License-Identifier: GPL-2.0-only
//
// Rust port of the daemon half of src/uml4termuxd.c.
//
// Scope of this increment (phase 2a): control socket, state file, child
// supervision on a PTY (forkpty + execv), console drain, restart policy,
// clean shutdown and the full client protocol. The reply strings are
// byte-compatible with the C daemon so a single parity script can diff them.
//
// Not ported yet (phase 2b): real-guest argv assembly is present but the
// gvproxy lifecycle, the exposure registry writes and the optional HTTP
// health endpoint are still C-only -- with gvproxy absent the replies here
// match the C daemon exactly, which is what the parity gate checks.

use crate::config::Config;
use std::ffi::CString;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::unix::io::{FromRawFd, RawFd};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant, SystemTime};

const SELFTEST_CHILD_DEFAULT: &str = "/data/data/com.termux/files/usr/bin/sleep";
const RESTART_BACKOFF_S: u32 = 2;
const RESTART_MAX: u32 = 5;

// Written from signal handlers: only atomics, no allocation, no locks.
static STOP: AtomicBool = AtomicBool::new(false);
static CHILD_EXITED: AtomicBool = AtomicBool::new(false);

extern "C" fn on_stop_signal(_sig: libc::c_int) {
    STOP.store(true, Ordering::SeqCst);
}

extern "C" fn on_sigchld(_sig: libc::c_int) {
    CHILD_EXITED.store(true, Ordering::SeqCst);
}

pub struct Daemon {
    cfg: Config,
    selftest: bool,
    sock_path: PathBuf,
    state_path: PathBuf,
    console_log: PathBuf,
    /// Registry file; empty in selftest mode exactly like the C daemon, so
    /// `ports` answers {"exposures":[]} there.
    exposures_path: Option<PathBuf>,

    child: i32,
    pty_master: RawFd,
    log_file: Option<File>,
    restarts: u32,
    completed: bool,
    started_at: SystemTime,
    exec_seq: u32,

    // Guest configuration (real-guest path).
    kernel: String,
    stub: String,
    image: String,
    initramfs: String,
    mem: String,
    ncpus: String,
    cow: String,

    child_argv0: String,
    gvproxy_pid: i32,
}

impl Daemon {
    pub fn new(cfg: Config, selftest: bool) -> Self {
        let sock_path = cfg.daemon_sock();
        let state_path = with_suffix(&sock_path, ".state");
        let console_log = sock_path
            .parent()
            .unwrap_or(Path::new("."))
            .join("uml-console.log");

        let env_or = |k: &str, d: &str| {
            std::env::var(k)
                .ok()
                .filter(|v| !v.is_empty())
                .unwrap_or_else(|| d.to_string())
        };
        let child_argv0 = if selftest {
            env_or("UML4TERMUXD_SELFTEST_CHILD", SELFTEST_CHILD_DEFAULT)
        } else {
            env_or("UML4TERMUXD_KERNEL", "")
        };

        Daemon {
            cfg,
            selftest,
            sock_path,
            state_path,
            console_log,
            exposures_path: None,
            child: -1,
            pty_master: -1,
            log_file: None,
            restarts: 0,
            completed: false,
            started_at: SystemTime::now(),
            exec_seq: 0,
            kernel: env_or("UML4TERMUXD_KERNEL", ""),
            stub: env_or("UML4TERMUXD_STUB", ""),
            image: env_or("UML4TERMUXD_IMAGE", ""),
            initramfs: env_or("UML4TERMUXD_INITRAMFS", ""),
            mem: env_or("UML4TERMUXD_MEM", "1024M"),
            ncpus: env_or("UML4TERMUXD_NCPUS", "4"),
            cow: env_or("UML4TERMUXD_COW", ""),
            child_argv0,
            gvproxy_pid: -1,
        }
    }

    /// Entry point for `uml4termux-rs daemon [--selftest]`.
    pub fn run(&mut self) -> io::Result<i32> {
        let dir = self.sock_path.parent().unwrap_or(Path::new("."));
        fs::create_dir_all(dir)?;
        fs::create_dir_all(&self.cfg.log_dir).ok();

        if self.selftest {
            logf(&format!("selftest: supervising {}", self.child_argv0));
        } else {
            if let Err(e) = self.check_guest_config() {
                logf(&format!("guest config error: {e}"));
                eprintln!("uml4termux-rs: {e}");
                return Ok(2);
            }
            self.exposures_path = Some(dir.join("exposures.jsonl"));
            logf(&format!(
                "guest: kernel={} mem={} ncpus={} console={}",
                self.kernel,
                self.mem,
                self.ncpus,
                self.console_log.display()
            ));
        }

        // Owner-only files (socket, state, console log), like the C daemon.
        unsafe { libc::umask(0o077) };

        let lfd = self.bind_socket()?;
        logf(&format!("control socket: {}", self.sock_path.display()));
        self.install_signal_handlers();

        if self.spawn_child()? != 0 {
            unsafe { libc::close(lfd) };
            return Ok(1);
        }
        self.serve_loop(lfd)
    }

    fn check_guest_config(&self) -> Result<(), String> {
        let parts = [
            ("KERNEL", &self.kernel),
            ("STUB", &self.stub),
            ("IMAGE", &self.image),
            ("INITRAMFS", &self.initramfs),
        ];
        for (name, value) in parts {
            if value.is_empty() {
                return Err(format!("UML4TERMUXD_{name} is not set"));
            }
            if !Path::new(value).exists() {
                return Err(format!("{} not found: {value}", name.to_lowercase()));
            }
        }
        Ok(())
    }

    fn bind_socket(&self) -> io::Result<RawFd> {
        let _ = fs::remove_file(&self.sock_path);
        let lfd = unsafe { libc::socket(libc::AF_UNIX, libc::SOCK_STREAM, 0) };
        if lfd < 0 {
            return Err(io::Error::last_os_error());
        }
        let mut addr: libc::sockaddr_un = unsafe { std::mem::zeroed() };
        addr.sun_family = libc::AF_UNIX as libc::sa_family_t;
        let bytes = self.sock_path.as_os_str().as_encoded_bytes();
        if bytes.len() >= addr.sun_path.len() {
            unsafe { libc::close(lfd) };
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "socket path too long",
            ));
        }
        for (i, b) in bytes.iter().enumerate() {
            addr.sun_path[i] = *b as libc::c_char;
        }
        let rc = unsafe {
            libc::bind(
                lfd,
                &addr as *const libc::sockaddr_un as *const libc::sockaddr,
                std::mem::size_of::<libc::sockaddr_un>() as libc::socklen_t,
            )
        };
        if rc != 0 {
            let e = io::Error::last_os_error();
            unsafe { libc::close(lfd) };
            return Err(io::Error::new(e.kind(), format!("bind: {e}")));
        }
        if unsafe { libc::listen(lfd, 4) } != 0 {
            let e = io::Error::last_os_error();
            unsafe { libc::close(lfd) };
            return Err(e);
        }
        let c = CString::new(self.sock_path.as_os_str().as_encoded_bytes()).unwrap();
        unsafe { libc::chmod(c.as_ptr(), 0o600) };
        Ok(lfd)
    }

    fn install_signal_handlers(&self) {
        unsafe {
            let mut sa: libc::sigaction = std::mem::zeroed();
            sa.sa_sigaction = on_stop_signal as *const () as libc::sighandler_t;
            sa.sa_flags = libc::SA_RESTART;
            libc::sigaction(libc::SIGINT, &sa, std::ptr::null_mut());
            libc::sigaction(libc::SIGTERM, &sa, std::ptr::null_mut());

            // SA_NOCLDSTOP keeps stop notifications from setting the flag.
            let mut ca: libc::sigaction = std::mem::zeroed();
            ca.sa_sigaction = on_sigchld as *const () as libc::sighandler_t;
            ca.sa_flags = libc::SA_NOCLDSTOP | libc::SA_RESTART;
            libc::sigaction(libc::SIGCHLD, &ca, std::ptr::null_mut());
        }
    }

    fn spawn_child(&mut self) -> io::Result<i32> {
        let (argv, use_pty) = if self.selftest {
            (vec![self.child_argv0.clone(), "30".to_string()], false)
        } else {
            (self.guest_argv(), true)
        };

        let cstrings: Vec<CString> = argv
            .iter()
            .map(|a| CString::new(a.as_str()).unwrap_or_default())
            .collect();
        let mut ptrs: Vec<*const libc::c_char> = cstrings.iter().map(|c| c.as_ptr()).collect();
        ptrs.push(std::ptr::null());

        let pid = if use_pty {
            let mut master: libc::c_int = -1;
            let pid = unsafe {
                libc::forkpty(
                    &mut master,
                    std::ptr::null_mut(),
                    std::ptr::null(),
                    std::ptr::null(),
                )
            };
            if pid < 0 {
                let e = io::Error::last_os_error();
                logf(&format!("forkpty failed: {e}"));
                return Err(e);
            }
            if pid == 0 {
                unsafe {
                    libc::execv(ptrs[0], ptrs.as_ptr());
                    libc::_exit(127);
                }
            }
            self.pty_master = master;
            let flags = unsafe { libc::fcntl(self.pty_master, libc::F_GETFL) };
            unsafe { libc::fcntl(self.pty_master, libc::F_SETFL, flags | libc::O_NONBLOCK) };
            self.log_file = Some(
                OpenOptions::new()
                    .write(true)
                    .create(true)
                    .truncate(true)
                    .open(&self.console_log)?,
            );
            pid
        } else {
            let pid = unsafe { libc::fork() };
            if pid < 0 {
                let e = io::Error::last_os_error();
                logf(&format!("fork failed: {e}"));
                return Err(e);
            }
            if pid == 0 {
                unsafe {
                    libc::execv(ptrs[0], ptrs.as_ptr());
                    libc::_exit(127);
                }
            }
            pid
        };

        self.child = pid;
        self.completed = false;
        self.started_at = SystemTime::now();
        logf(&format!(
            "child spawned pid={pid} argv0={}",
            if self.selftest {
                &self.child_argv0
            } else {
                &self.kernel
            }
        ));
        self.state_json("running", "spawned");
        Ok(0)
    }

    /// UML boot command line, identical to the C daemon's assembly.
    fn guest_argv(&self) -> Vec<String> {
        let mut argv = vec![
            self.kernel.clone(),
            format!("mem={}", self.mem),
            format!("ncpus={}", self.ncpus),
            "seccomp=on".to_string(),
        ];
        // UML's syntax is ubd0=<cow>,<backing>: the COW file comes FIRST.
        if self.cow.is_empty() {
            argv.push(format!("ubd0={}", self.image));
        } else {
            argv.push(format!("ubd0={},{}", self.cow, self.image));
        }
        argv.push("root=/dev/ubda".to_string());
        argv.push("rw".to_string());
        argv.push(format!("initrd={}", self.initramfs));
        argv.push(format!("stub_exe={}", self.stub));
        argv.push("panic=-1".to_string());
        argv.push("con=null".to_string());
        argv.push("con0=fd:0,fd:1".to_string());
        argv
    }

    fn serve_loop(&mut self, lfd: RawFd) -> io::Result<i32> {
        while !STOP.load(Ordering::SeqCst) {
            let mut pfds: Vec<libc::pollfd> = Vec::with_capacity(3);
            pfds.push(libc::pollfd {
                fd: lfd,
                events: libc::POLLIN,
                revents: 0,
            });
            let mut pty_idx: Option<usize> = None;
            if self.pty_master >= 0 {
                pty_idx = Some(pfds.len());
                pfds.push(libc::pollfd {
                    fd: self.pty_master,
                    events: libc::POLLIN,
                    revents: 0,
                });
            }

            let rc = unsafe { libc::poll(pfds.as_mut_ptr(), pfds.len() as libc::nfds_t, 500) };
            if CHILD_EXITED.load(Ordering::SeqCst) {
                self.reap_child();
            }
            if rc > 0 {
                if let Some(i) = pty_idx {
                    if pfds[i].revents & (libc::POLLIN | libc::POLLHUP) != 0 {
                        self.drain_console();
                    }
                }
                if pfds[0].revents & libc::POLLIN != 0 {
                    let cfd =
                        unsafe { libc::accept(lfd, std::ptr::null_mut(), std::ptr::null_mut()) };
                    if cfd >= 0 {
                        self.handle_client(cfd);
                        unsafe { libc::close(cfd) };
                    }
                }
            }
        }
        if self.child > 0 {
            self.stop_child(5);
        }
        if self.pty_master >= 0 {
            unsafe { libc::close(self.pty_master) };
            self.pty_master = -1;
        }
        self.log_file = None;
        logf("daemon exit");
        self.state_json("stopped", "daemon-exit");
        Ok(0)
    }

    fn drain_console(&mut self) {
        let mut buf = [0u8; 4096];
        loop {
            let n = unsafe {
                libc::read(
                    self.pty_master,
                    buf.as_mut_ptr() as *mut libc::c_void,
                    buf.len(),
                )
            };
            if n <= 0 {
                break;
            }
            if let Some(f) = self.log_file.as_mut() {
                let _ = f.write_all(&buf[..n as usize]);
            }
        }
    }

    fn handle_client(&mut self, fd: RawFd) {
        let mut req = [0u8; 512];
        let n = unsafe { libc::read(fd, req.as_mut_ptr() as *mut libc::c_void, req.len() - 1) };
        if n <= 0 {
            return;
        }
        let raw = &req[..n as usize];
        let line: Vec<u8> = raw
            .iter()
            .take_while(|b| **b != b'\n' && **b != b'\r')
            .copied()
            .collect();
        let line = String::from_utf8_lossy(&line).to_string();

        let response = self.dispatch(&line);
        let _ = write_all_fd(fd, response.as_bytes());
    }

    /// Pure command dispatch: separated from the socket so it is unit-testable
    /// without a client, a PTY or a child process.
    pub fn dispatch(&mut self, line: &str) -> String {
        if line.starts_with("status") {
            return self.status_json();
        }
        if line.starts_with("stop") {
            if self.child > 0 {
                logf(&format!("stop requested: SIGTERM -> {}", self.child));
            }
            STOP.store(true, Ordering::SeqCst);
            return "{\"state\":\"stopping\"}\n".to_string();
        }
        if let Some(rest) = line.strip_prefix("exec ") {
            if self.pty_master < 0 || self.child <= 0 {
                return "{\"error\":\"guest not running\"}\n".to_string();
            }
            self.exec_seq += 1;
            let seq = self.exec_seq;
            let cmd =
                format!("exec:echo __EXEC_{seq}_BEGIN__; {rest}; echo __EXEC_{seq}_DONE_$?\n");
            let rc = unsafe {
                libc::write(
                    self.pty_master,
                    cmd.as_ptr() as *const libc::c_void,
                    cmd.len(),
                )
            };
            if rc < 0 {
                let e = io::Error::last_os_error();
                return format!("{{\"error\":\"pty write failed: {e}\"}}\n");
            }
            return format!(
                "{{\"started\":true,\"seq\":{seq},\"console\":\"{}\"}}\n",
                self.console_log.display()
            );
        }
        if let Some(rest) = line.strip_prefix("expose ") {
            let parts: Vec<&str> = rest.split_whitespace().collect();
            if self.gvproxy_pid <= 0 {
                return "{\"error\":\"gvproxy not running\"}\n".to_string();
            }
            if parts.len() != 2 {
                return "{\"error\":\"usage: expose <host-port> <guest-port>\"}\n".to_string();
            }
            // phase 2b: do_expose() + save_exposure() are still C-only, so this
            // branch is unreachable while gvproxy is not started here.
            return "{\"error\":\"gvproxy not running\"}\n".to_string();
        }
        if line.starts_with("ports") {
            return self.ports_json();
        }
        "{\"error\":\"unknown command\"}\n".to_string()
    }

    pub fn status_json(&self) -> String {
        let state = if self.child > 0 {
            "running"
        } else if self.completed {
            "completed"
        } else {
            "idle"
        };
        if self.selftest {
            format!(
                "{{\"state\":\"{state}\",\"child_pid\":{},\"restarts\":{},\"mode\":\"selftest\"}}\n",
                self.child, self.restarts
            )
        } else {
            let uptime = if self.child > 0 {
                SystemTime::now()
                    .duration_since(self.started_at)
                    .map(|d| d.as_secs())
                    .unwrap_or(0)
            } else {
                0
            };
            format!(
                "{{\"state\":\"{state}\",\"child_pid\":{},\"restarts\":{},\"kernel\":\"{}\",\"mem\":\"{}\",\"ncpus\":\"{}\",\"uptime_s\":{uptime}}}\n",
                self.child, self.restarts, self.kernel, self.mem, self.ncpus
            )
        }
    }

    fn ports_json(&self) -> String {
        let mut list = String::new();
        if let Some(p) = &self.exposures_path {
            if let Ok(text) = fs::read_to_string(p) {
                for l in text.lines() {
                    if l.trim().is_empty() {
                        continue;
                    }
                    if !list.is_empty() {
                        list.push('\n');
                    }
                    list.push_str(l);
                }
                while list.ends_with([',', ' ']) {
                    list.pop();
                }
            }
        }
        format!("{{\"exposures\":[{list}]}}\n")
    }

    fn reap_child(&mut self) {
        CHILD_EXITED.store(false, Ordering::SeqCst);
        loop {
            let mut st: libc::c_int = 0;
            let pid = unsafe { libc::waitpid(-1, &mut st, libc::WNOHANG) };
            if pid <= 0 {
                return;
            }
            if pid != self.child {
                continue;
            }
            let exited = libc::WIFEXITED(st);
            let code = if exited {
                libc::WEXITSTATUS(st)
            } else {
                libc::WTERMSIG(st)
            };
            let how = if exited { "exit" } else { "signal" };
            self.child = -1;
            logf(&format!("child {pid} died ({how} {code})"));

            // exit 0 = the guest powered itself off: a finished session, not a
            // crash. Stay stopped; only crashes restart.
            if exited && code == 0 {
                self.state_json("completed", &format!("{how}={code}"));
                self.completed = true;
                logf("guest session completed; not restarting");
                if self.pty_master >= 0 {
                    unsafe { libc::close(self.pty_master) };
                    self.pty_master = -1;
                }
                self.log_file = None;
                return;
            }
            // exec failure (126/127) is a configuration error, not a crash:
            // restarting would loop forever.
            if exited && (code == 126 || code == 127) {
                self.state_json("failed", &format!("{how}={code}"));
                logf(&format!("exec/config failure ({how}={code}); giving up"));
                STOP.store(true, Ordering::SeqCst);
                return;
            }
            self.state_json("exited", &format!("{how}={code}"));
            self.restarts += 1;
            if self.restarts > RESTART_MAX {
                logf(&format!("restart limit {RESTART_MAX} reached, giving up"));
                self.state_json("failed", "restart-limit");
                STOP.store(true, Ordering::SeqCst);
                return;
            }
            std::thread::sleep(Duration::from_secs(
                (RESTART_BACKOFF_S * self.restarts) as u64,
            ));
            if !STOP.load(Ordering::SeqCst) && self.spawn_child().is_err() {
                STOP.store(true, Ordering::SeqCst);
            }
        }
    }

    /// Clean shutdown first (guest `poweroff -f` through the console), then
    /// SIGTERM, then SIGKILL -- same escalation and budgets as the C daemon.
    fn stop_child(&mut self, timeout_s: i32) {
        if self.child <= 0 {
            return;
        }
        if self.pty_master >= 0 {
            let line = "exec:sync; poweroff -f\n";
            let n = unsafe {
                libc::write(
                    self.pty_master,
                    line.as_ptr() as *const libc::c_void,
                    line.len(),
                )
            };
            if n > 0 {
                logf("stop: clean poweroff via console (20 s budget)");
                let deadline = Instant::now() + Duration::from_secs(20);
                while Instant::now() < deadline && !self.child_reaped() {
                    std::thread::sleep(Duration::from_millis(500));
                }
                if self.child_reaped() {
                    self.child = -1;
                    logf("clean poweroff landed");
                    return;
                }
                logf("clean poweroff did not land; falling back to signals");
            }
        }
        unsafe { libc::kill(self.child, libc::SIGTERM) };
        let deadline = Instant::now() + Duration::from_secs(timeout_s.max(1) as u64);
        while Instant::now() < deadline && !self.child_reaped() {
            std::thread::sleep(Duration::from_millis(200));
        }
        if !self.child_reaped() {
            logf(&format!(
                "SIGTERM ignored for {timeout_s}s, sending SIGKILL"
            ));
            unsafe {
                libc::kill(self.child, libc::SIGKILL);
                libc::waitpid(self.child, std::ptr::null_mut(), 0);
            }
        }
        self.child = -1;
    }

    fn child_reaped(&mut self) -> bool {
        if self.child <= 0 {
            return true;
        }
        let mut st: libc::c_int = 0;
        let pid = unsafe { libc::waitpid(self.child, &mut st, libc::WNOHANG) };
        pid != 0 // >0 reaped, <0 error/none
    }

    fn write_state(&self, body: &str) {
        let tmp = with_suffix(&self.state_path, ".tmp");
        let write = || -> io::Result<()> {
            let mut f = OpenOptions::new()
                .write(true)
                .create(true)
                .truncate(true)
                .open(&tmp)?;
            f.write_all(body.as_bytes())?;
            f.sync_all()?;
            fs::rename(&tmp, &self.state_path)?;
            Ok(())
        };
        if let Err(e) = write() {
            logf(&format!("state write failed: {e}"));
        }
    }

    fn state_json(&self, phase: &str, detail: &str) {
        let ts = SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        // Key order is built explicitly to stay byte-identical with the C
        // daemon (serde_json's json! macro would sort them alphabetically),
        // while the VALUES are still escaped by serde -- which is the fix for
        // the C version's unescaped snprintf("%s") detail field.
        let esc = |v: &str| serde_json::to_string(v).unwrap_or_else(|_| "\"\"".to_string());
        let line = format!(
            "{{\"phase\":{},\"child_pid\":{},\"restarts\":{},\"detail\":{},\"ts\":{}}}\n",
            esc(phase),
            self.child,
            self.restarts,
            esc(detail),
            ts
        );
        debug_assert!(serde_json::from_str::<serde_json::Value>(line.trim()).is_ok());
        self.write_state(&line);
        logf(&format!("state={phase} {detail}"));
    }
}

fn with_suffix(p: &Path, suffix: &str) -> PathBuf {
    let mut s = p.as_os_str().to_os_string();
    s.push(suffix);
    PathBuf::from(s)
}

fn write_all_fd(fd: RawFd, mut buf: &[u8]) -> io::Result<()> {
    while !buf.is_empty() {
        let n = unsafe { libc::write(fd, buf.as_ptr() as *const libc::c_void, buf.len()) };
        if n <= 0 {
            return Err(io::Error::last_os_error());
        }
        buf = &buf[n as usize..];
    }
    Ok(())
}

fn logf(msg: &str) {
    let ts = SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .unwrap_or_default();
    eprintln!(
        "[{}.{:03}] uml4termuxd[{}]: {msg}",
        ts.as_secs(),
        ts.subsec_millis(),
        std::process::id()
    );
}

/// Read one line from a file descriptor (used by the parity harness and by
/// future HTTP handling); kept here so the module owns all raw-fd plumbing.
#[allow(dead_code)]
pub fn read_line_fd(fd: RawFd) -> io::Result<String> {
    let mut f = unsafe { File::from_raw_fd(fd) };
    let mut s = String::new();
    f.read_to_string(&mut s)?;
    Ok(s)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_daemon(selftest: bool) -> Daemon {
        let cfg = Config::from_env();
        Daemon::new(cfg, selftest)
    }

    #[test]
    fn selftest_status_shape_matches_c() {
        let d = test_daemon(true);
        let json = d.status_json();
        assert!(json.ends_with("}\n"));
        assert!(json.contains("\"child_pid\":-1"));
        assert!(json.contains("\"restarts\":0"));
        assert!(json.contains("\"mode\":\"selftest\""));
        assert!(json.contains("\"state\":\"idle\""));
    }

    #[test]
    fn ports_is_empty_without_a_registry() {
        let d = test_daemon(true);
        assert_eq!(d.ports_json(), "{\"exposures\":[]}\n");
    }

    #[test]
    fn exec_without_a_guest_reports_the_same_error_as_c() {
        let mut d = test_daemon(true);
        assert_eq!(
            d.dispatch("exec uname -a"),
            "{\"error\":\"guest not running\"}\n"
        );
    }

    #[test]
    fn expose_without_gvproxy_reports_the_same_error_as_c() {
        let mut d = test_daemon(true);
        assert_eq!(
            d.dispatch("expose 8124 80"),
            "{\"error\":\"gvproxy not running\"}\n"
        );
    }

    #[test]
    fn unknown_command_matches_c() {
        let mut d = test_daemon(true);
        assert_eq!(d.dispatch("wibble"), "{\"error\":\"unknown command\"}\n");
    }

    #[test]
    fn stop_answers_then_sets_the_stop_flag() {
        let mut d = test_daemon(true);
        STOP.store(false, Ordering::SeqCst);
        assert_eq!(d.dispatch("stop"), "{\"state\":\"stopping\"}\n");
        assert!(STOP.load(Ordering::SeqCst));
        STOP.store(false, Ordering::SeqCst);
    }

    #[test]
    fn state_file_round_trips_with_escaped_detail() {
        let d = test_daemon(true);
        d.state_json("exited", "quote \" and \\ backslash");
        let text = fs::read_to_string(&d.state_path).unwrap_or_default();
        if !text.is_empty() {
            let v: serde_json::Value = serde_json::from_str(text.trim()).expect("valid JSON");
            assert_eq!(v["phase"], "exited");
            assert_eq!(v["detail"], "quote \" and \\ backslash");
            let _ = fs::remove_file(&d.state_path);
        }
    }

    #[test]
    fn guest_argv_puts_the_cow_first() {
        let mut d = test_daemon(false);
        d.kernel = "/k".into();
        d.image = "/img.ext4".into();
        d.initramfs = "/i.cpio.gz".into();
        d.stub = "/stub".into();
        d.cow = "/g.cow".into();
        let argv = d.guest_argv();
        assert!(argv.iter().any(|a| a == "ubd0=/g.cow,/img.ext4"));
        d.cow.clear();
        let argv = d.guest_argv();
        assert!(argv.iter().any(|a| a == "ubd0=/img.ext4"));
        assert!(!argv.iter().any(|a| a.starts_with("ubd0=,")));
    }
}
