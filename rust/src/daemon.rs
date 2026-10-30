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
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const SELFTEST_CHILD_DEFAULT: &str = "/data/data/com.termux/files/usr/bin/sleep";
const SELFTEST_SECONDS_DEFAULT: &str = "30";
const RESTART_BACKOFF_S: u32 = 2;
const RESTART_MAX: u32 = 5;

// Written from signal handlers: only atomics, no allocation, no locks.
/// Runtime contract v1 (docs/RUNTIME-CONTRACT.md). Bumped only when the
/// documented protocol/paths change in a way old clients cannot handle.
const PROTOCOL: u8 = 1;
const RUNTIME_CONTRACT: u8 = 1;
const COMMANDS: &str = "\"status\",\"stop\",\"ports\",\"expose\",\"exec\",\"protocol\"";

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
    /// E3: audit writer (opened lazily next to the socket) and the exec rate
    /// limit state. Mirrors the C daemon so the two implementations cannot
    /// drift apart on hardening either.
    audit_file: Option<File>,
    last_exec: Option<Instant>,
    exec_min_ms: Option<u64>,

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
    gvproxy_path: String,
    bess: String,
    /// gvproxy's HTTP-over-unix API socket (`<bess>.gv.sock`).
    gvapi: String,
    http_fd: RawFd,
    /// Console tail used to notice that the guest never attached its disk.
    console_tail: Vec<u8>,
    ubd_failed: bool,
    ubd_aborted: bool,
    /// UML4TERMUXD_STRICT_UBD=1: treat a failed ubd attach as fatal instead of
    /// letting the guest silently continue without a disk (its init runs from
    /// the initramfs and every write is then lost -- a docker run would appear
    /// to work while nothing persists).
    strict_ubd: bool,
    /// How long the selftest child lives (UML4TERMUXD_SELFTEST_SECONDS).
    /// A child that exits 0 means "session completed" and the daemon exits, so
    /// anything testing the daemon for longer than this must raise it.
    selftest_seconds: String,
    /// gvproxy's SSH port forwarder binds a FIXED host port (default 2222),
    /// so a second gvproxy on the same device dies with "address already in
    /// use". Override it per instance with UML4TERMUXD_GVPROXY_SSH_PORT.
    gvproxy_ssh_port: u16,
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
            audit_file: None,
            last_exec: None,
            exec_min_ms: None,
            kernel: env_or("UML4TERMUXD_KERNEL", ""),
            stub: env_or("UML4TERMUXD_STUB", ""),
            image: env_or("UML4TERMUXD_IMAGE", ""),
            initramfs: env_or("UML4TERMUXD_INITRAMFS", ""),
            mem: env_or("UML4TERMUXD_MEM", "1024M"),
            ncpus: env_or("UML4TERMUXD_NCPUS", "4"),
            cow: env_or("UML4TERMUXD_COW", ""),
            child_argv0,
            gvproxy_pid: -1,
            gvproxy_path: env_or("UML4TERMUXD_GVPROXY", ""),
            bess: env_or("UML4TERMUXD_BESS", ""),
            gvapi: String::new(),
            http_fd: -1,
            console_tail: Vec::new(),
            ubd_failed: false,
            ubd_aborted: false,
            selftest_seconds: env_or("UML4TERMUXD_SELFTEST_SECONDS", SELFTEST_SECONDS_DEFAULT),
            gvproxy_ssh_port: match std::env::var("UML4TERMUXD_GVPROXY_SSH_PORT") {
                Ok(v) => v.trim().parse::<u16>().unwrap_or(2222),
                Err(_) => 2222,
            },
            strict_ubd: std::env::var("UML4TERMUXD_STRICT_UBD")
                .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
                .unwrap_or(false),
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
            if self.spawn_gvproxy() != 0 {
                eprintln!("uml4termux-rs: gvproxy failed to start (see log)");
                return Ok(2);
            }
            self.reapply_exposures();
        }

        // Owner-only files (socket, state, console log), like the C daemon.
        unsafe { libc::umask(0o077) };

        let lfd = self.bind_socket()?;
        logf(&format!("control socket: {}", self.sock_path.display()));
        self.open_http_listener();
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
        // B2: this port's ubd driver needs a FORMATTED COW file -- it stats and
        // reads the header but never creates one. Reset it per boot by writing a
        // fresh v3 header (guests only; the selftest child has no disk).
        if !self.selftest && !self.cow.is_empty() {
            if let Err(e) =
                crate::cow::ensure_cow_header(Path::new(&self.cow), Path::new(&self.image))
            {
                logf(&format!(
                    "cow header write failed: {e}; booting without COW"
                ));
            }
        }
        // The guest branch MUST build the UML command line: an earlier refactor
        // returned an empty argv here, so the child exec'd nothing and died with
        // SIGSEGV in ~0.1s -- while every unit test still passed, because the
        // selftest path was the only one covered.
        let (argv, use_pty) = if self.selftest {
            self.selftest_argv()
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
        if self.gvproxy_pid > 0 && !self.bess.is_empty() {
            argv.push(format!(
                "vec0:transport=bess,dst={},depth=128,gro=1,mac=5a:94:ef:e4:0c:ee",
                self.bess
            ));
        }
        argv
    }

    // -----------------------------------------------------------------------
    // gvproxy lifecycle (A3) -- started only when UML4TERMUXD_GVPROXY is set
    // -----------------------------------------------------------------------
    fn spawn_gvproxy(&mut self) -> i32 {
        if self.gvproxy_path.is_empty() {
            return 0; // not configured: the guest runs without networking
        }
        if self.bess.is_empty() {
            logf("UML4TERMUXD_GVPROXY set but no UML4TERMUXD_BESS");
            return -1;
        }
        // Termux has no /etc; gvproxy wants /etc/resolv.conf, so proot binds
        // the Termux etc over it (skipped on hosts that have one).
        let need_proot =
            !Path::new("/etc/resolv.conf").exists() && Path::new("/data/data/com.termux").exists();
        let prefix = std::env::var("PREFIX")
            .ok()
            .filter(|v| !v.is_empty())
            .unwrap_or_else(|| "/data/data/com.termux/files/usr".to_string());

        let argv = gvproxy_argv(
            &self.gvproxy_path,
            &self.bess,
            self.gvproxy_ssh_port,
            need_proot,
            &prefix,
        );

        let cstrings: Vec<CString> = argv
            .iter()
            .map(|a| CString::new(a.as_str()).unwrap_or_default())
            .collect();
        let mut ptrs: Vec<*const libc::c_char> = cstrings.iter().map(|c| c.as_ptr()).collect();
        ptrs.push(std::ptr::null());

        let pid = unsafe { libc::fork() };
        if pid < 0 {
            return -1;
        }
        if pid == 0 {
            unsafe {
                // setsid: a bare kill of the proot pid would orphan its
                // tracee, so the daemon signals the whole process group.
                libc::setsid();
                libc::execvp(ptrs[0], ptrs.as_ptr());
                logf(&format!(
                    "exec gvproxy failed: {}",
                    io::Error::last_os_error()
                ));
                libc::_exit(127);
            }
        }
        self.gvproxy_pid = pid;

        // Up to 5 s for the bess socket to appear.
        for _ in 0..50 {
            if let Ok(meta) = fs::metadata(&self.bess) {
                use std::os::unix::fs::FileTypeExt;
                if meta.file_type().is_socket() {
                    logf(&format!("gvproxy up pid={pid} bess={}", self.bess));
                    self.gvapi = format!("{}.gv.sock", self.bess);
                    return 0;
                }
            }
            std::thread::sleep(Duration::from_millis(100));
        }
        logf(&format!("gvproxy did not create {}", self.bess));
        self.gvproxy_pid = -1;
        -1
    }

    /// Signal the whole process GROUP, then escalate -- a proot tracee would
    /// survive a bare kill of the proot pid.
    fn stop_gvproxy(&mut self) {
        if self.gvproxy_pid <= 0 {
            return;
        }
        unsafe { libc::kill(-self.gvproxy_pid, libc::SIGTERM) };
        for _ in 0..10 {
            if unsafe { libc::waitpid(self.gvproxy_pid, std::ptr::null_mut(), libc::WNOHANG) } != 0
            {
                logf("gvproxy stopped");
                self.gvproxy_pid = -1;
                return;
            }
            std::thread::sleep(Duration::from_millis(200));
        }
        logf("gvproxy group ignored SIGTERM, SIGKILL");
        unsafe {
            libc::kill(-self.gvproxy_pid, libc::SIGKILL);
            libc::waitpid(self.gvproxy_pid, std::ptr::null_mut(), 0);
        }
        logf("gvproxy stopped");
        self.gvproxy_pid = -1;
    }

    // -----------------------------------------------------------------------
    // Exposure registry (JSONL) + gvproxy HTTP-over-unix client (A3b)
    // -----------------------------------------------------------------------

    /// One HTTP request over a unix socket; returns the raw response text.
    fn unix_http(sockpath: &str, req: &str) -> io::Result<String> {
        use std::os::unix::net::UnixStream;
        let mut stream = UnixStream::connect(sockpath)?;
        stream.set_read_timeout(Some(Duration::from_secs(4)))?;
        stream.write_all(req.as_bytes())?;
        stream.flush()?;
        let mut out = String::new();
        stream.take(4096).read_to_string(&mut out)?;
        Ok(out)
    }

    fn do_expose(&self, hport: &str, gport: &str) -> Result<(), String> {
        let local = format!("127.0.0.1:{hport}");
        let remote = format!("{}:{gport}", self.cfg.guest_ip);
        // serde, not string concatenation: a stray quote in a port value
        // cannot break the payload the way "{\"local\":\"%s\"}" can.
        let json = serde_json::json!({ "local": local, "remote": remote }).to_string();
        let req = format!(
            "POST /services/forwarder/expose HTTP/1.1\r\nHost: unix\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
            json.len(),
            json
        );
        match Self::unix_http(&self.gvapi, &req) {
            Ok(resp) => {
                if resp.contains("200") {
                    logf(&format!("exposed {local} -> {remote}"));
                    Ok(())
                } else {
                    Err(format!(
                        "gvproxy rejected: {}",
                        resp.chars().take(80).collect::<String>()
                    ))
                }
            }
            Err(_) => Err("gvproxy API unreachable".to_string()),
        }
    }

    /// Append an exposure, dropping any earlier entry for the same host port.
    fn save_exposure(&self, hport: &str, gport: &str) -> io::Result<()> {
        let path = match &self.exposures_path {
            Some(p) => p,
            None => return Ok(()),
        };
        let needle = format!("\"local\":\"127.0.0.1:{hport}\"");
        let existing = fs::read_to_string(path).unwrap_or_default();
        let mut out = String::new();
        for line in existing.lines() {
            if !line.contains(&needle) {
                out.push_str(line);
                out.push('\n');
            }
        }
        out.push_str(&format!(
            "{{\"local\":\"127.0.0.1:{hport}\",\"remote\":\"{}:{gport}\"}}\n",
            self.cfg.guest_ip
        ));
        let tmp = with_suffix(path, ".tmp");
        fs::write(&tmp, out)?;
        fs::rename(&tmp, path)?;
        Ok(())
    }

    /// Re-apply every recorded exposure after a restart.
    fn reapply_exposures(&self) {
        let path = match &self.exposures_path {
            Some(p) => p,
            None => return,
        };
        let text = match fs::read_to_string(path) {
            Ok(t) => t,
            Err(_) => return,
        };
        let mut n = 0;
        for line in text.lines() {
            if let (Some(hport), Some(gport)) =
                (json_field(line, "local"), json_field(line, "remote"))
            {
                match self.do_expose(&hport, &gport) {
                    Ok(()) => n += 1,
                    Err(e) => logf(&format!("re-expose {hport}->{gport} failed: {e}")),
                }
            }
        }
        if n > 0 {
            logf(&format!("re-applied {n} exposure(s) from the registry"));
        }
    }

    fn exposure_count(&self) -> usize {
        match &self.exposures_path {
            Some(p) => fs::read_to_string(p)
                .map(|t| t.lines().filter(|l| !l.trim().is_empty()).count())
                .unwrap_or(0),
            None => 0,
        }
    }

    // -----------------------------------------------------------------------
    // Optional loopback HTTP health endpoint (D2, UML4TERMUXD_HTTP=ip:port)
    // -----------------------------------------------------------------------
    fn open_http_listener(&mut self) {
        let spec = match std::env::var("UML4TERMUXD_HTTP") {
            Ok(v) if !v.is_empty() => v,
            _ => return,
        };
        let (host, port_str) = match spec.rsplit_once(':') {
            Some((h, p)) => (h.to_string(), p.to_string()),
            None => ("127.0.0.1".to_string(), spec.clone()),
        };
        let port: i32 = port_str.trim().parse().unwrap_or(0);
        if port <= 0 || port > 65535 {
            logf("http: invalid port in UML4TERMUXD_HTTP, endpoint disabled");
            return;
        }
        let fd = unsafe { libc::socket(libc::AF_INET, libc::SOCK_STREAM, 0) };
        if fd < 0 {
            return;
        }
        let yes: libc::c_int = 1;
        unsafe {
            libc::setsockopt(
                fd,
                libc::SOL_SOCKET,
                libc::SO_REUSEADDR,
                &yes as *const libc::c_int as *const libc::c_void,
                std::mem::size_of::<libc::c_int>() as libc::socklen_t,
            )
        };
        let mut addr: libc::sockaddr_in = unsafe { std::mem::zeroed() };
        addr.sin_family = libc::AF_INET as libc::sa_family_t;
        addr.sin_port = (port as u16).to_be();
        // The libc crate does not expose inet_pton; parse the dotted quad
        // directly. s_addr is a native-order u32 whose MEMORY bytes are the
        // network-order octets, so from_ne_bytes is the correct conversion --
        // from_be_bytes gives 01 00 00 7F for 127.0.0.1 and bind() then fails
        // with EADDRNOTAVAIL (os error 99).
        match host.parse::<std::net::Ipv4Addr>() {
            Ok(ip) => addr.sin_addr.s_addr = u32::from_ne_bytes(ip.octets()),
            Err(_) => {
                logf(&format!("http: bad host '{host}', endpoint disabled"));
                unsafe { libc::close(fd) };
                return;
            }
        }
        let ok = unsafe {
            libc::bind(
                fd,
                &addr as *const libc::sockaddr_in as *const libc::sockaddr,
                std::mem::size_of::<libc::sockaddr_in>() as libc::socklen_t,
            ) == 0
                && libc::listen(fd, 4) == 0
        };
        if !ok {
            logf(&format!(
                "http: bind/listen {host}:{port} failed: {}",
                io::Error::last_os_error()
            ));
            unsafe { libc::close(fd) };
            return;
        }
        self.http_fd = fd;
        logf(&format!(
            "http health endpoint on {host}:{port} (GET /status)"
        ));
    }

    /// Response body is byte-identical to the C daemon's http_serve().
    fn http_response(&self) -> String {
        let mode = if self.cow.is_empty() {
            "persistent"
        } else {
            "ephemeral-cow"
        };
        let payload = if self.child > 0 {
            format!(
                "{{\"ok\":true,\"state\":\"running\",\"child_pid\":{},\"exposures\":{},\"mode\":\"{mode}\"}}\r\n",
                self.child,
                self.exposure_count()
            )
        } else {
            format!(
                "{{\"ok\":true,\"state\":\"idle\",\"child_pid\":-1,\"exposures\":{},\"mode\":\"{mode}\"}}\r\n",
                self.exposure_count()
            )
        };
        format!("HTTP/1.0 200 OK\r\nContent-Type: application/json\r\n\r\n{payload}")
    }

    fn http_serve(&self, cfd: RawFd) {
        let mut req = [0u8; 512];
        let _ = unsafe { libc::read(cfd, req.as_mut_ptr() as *mut libc::c_void, req.len() - 1) };
        let body = self.http_response();
        let _ = write_all_fd(cfd, body.as_bytes());
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

            let mut http_idx: Option<usize> = None;
            if self.http_fd >= 0 {
                http_idx = Some(pfds.len());
                pfds.push(libc::pollfd {
                    fd: self.http_fd,
                    events: libc::POLLIN,
                    revents: 0,
                });
            }

            if self.strict_ubd && self.ubd_failed && !self.ubd_aborted {
                self.ubd_aborted = true;
                logf("guest could not attach its disk (ubd); aborting because UML4TERMUXD_STRICT_UBD is set");
                self.state_json("failed", "ubd-attach");
                if self.child > 0 {
                    self.stop_child(5);
                }
                STOP.store(true, Ordering::SeqCst);
                break;
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
                        if peer_is_owner(cfd) {
                            self.handle_client(cfd);
                        } else {
                            self.audit("denied", "control socket connection from another uid");
                            logf("control socket: refused a connection from a different uid");
                            let _ = write_all_fd(cfd, b"{\"error\":\"not the owner\"}\n");
                        }
                        unsafe { libc::close(cfd) };
                    }
                }
                if let Some(i) = http_idx {
                    if pfds[i].revents & libc::POLLIN != 0 {
                        let cfd = unsafe {
                            libc::accept(self.http_fd, std::ptr::null_mut(), std::ptr::null_mut())
                        };
                        if cfd >= 0 {
                            self.http_serve(cfd);
                            unsafe { libc::close(cfd) };
                        }
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
        if self.http_fd >= 0 {
            unsafe { libc::close(self.http_fd) };
            self.http_fd = -1;
        }
        self.log_file = None;
        self.stop_gvproxy();
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
            if scan_ubd_failure(&mut self.console_tail, &buf[..n as usize]) {
                self.ubd_failed = true;
            }
        }
    }

    /// E3: one line per event, same shape as the C daemon:
    ///   <utc> <verb> uid=<uid> <detail>
    /// Control characters in the detail become '_' so a crafted command cannot
    /// forge a second entry.
    fn audit(&mut self, verb: &str, detail: &str) {
        if self.audit_file.is_none() {
            let path = self.sock_path.with_file_name("audit.log");
            match OpenOptions::new().create(true).append(true).open(&path) {
                Ok(f) => self.audit_file = Some(f),
                Err(e) => {
                    logf(&format!("audit: cannot open {}: {e}", path.display()));
                    return;
                }
            }
        }
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs();
        let stamp = format_utc(now);
        let safe: String = detail
            .chars()
            .take(240)
            .map(|c| {
                if (c as u32) < 0x20 || (c as u32) == 0x7f {
                    '_'
                } else {
                    c
                }
            })
            .collect();
        let uid = unsafe { libc::geteuid() };
        if let Some(f) = self.audit_file.as_mut() {
            let _ = f.write_all(format!("{stamp} {verb} uid={uid} {safe}\n").as_bytes());
        }
    }

    /// E3: a client can send `exec` as fast as it can write, and each one drives
    /// a shell inside the guest. UML4TERMUXD_EXEC_MIN_INTERVAL_MS=0 turns it off.
    fn exec_min_interval_ms(&mut self) -> u64 {
        if let Some(v) = self.exec_min_ms {
            return v;
        }
        let v = std::env::var("UML4TERMUXD_EXEC_MIN_INTERVAL_MS")
            .ok()
            .and_then(|v| v.parse::<u64>().ok())
            .unwrap_or(100);
        self.exec_min_ms = Some(v);
        v
    }

    fn exec_rate_limited(&mut self) -> bool {
        let min_ms = self.exec_min_interval_ms();
        if min_ms == 0 {
            return false;
        }
        let now = Instant::now();
        let limited = self
            .last_exec
            .map(|last| now.duration_since(last).as_millis() < min_ms as u128)
            .unwrap_or(false);
        if !limited {
            self.last_exec = Some(now);
        }
        limited
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

    /// The child command line for the current mode. Pure so the selftest
    /// lifetime (which decides how long a `--selftest` daemon stays up) is
    /// asserted in a test rather than discovered by a flaky suite.
    fn selftest_argv(&self) -> (Vec<String>, bool) {
        (
            vec![self.child_argv0.clone(), self.selftest_seconds.clone()],
            false,
        )
    }

    /// Pure command dispatch: separated from the socket so it is unit-testable
    /// without a client, a PTY or a child process.
    pub fn dispatch(&mut self, line: &str) -> String {
        // Runtime contract v1 (docs/RUNTIME-CONTRACT.md). Must stay byte-identical
        // to the C daemon's reply -- ci/verify-daemon-parity.sh compares them.
        if line.starts_with("protocol") {
            return format!(
                "{{\"protocol\":{},\"runtime_contract\":{},\"commands\":[{}]}}\n",
                PROTOCOL, RUNTIME_CONTRACT, COMMANDS
            );
        }
        if line.starts_with("status") {
            return self.status_json();
        }
        if line.starts_with("stop") {
            self.audit("stop", "requested");
            if self.child > 0 {
                logf(&format!("stop requested: SIGTERM -> {}", self.child));
            }
            STOP.store(true, Ordering::SeqCst);
            return "{\"state\":\"stopping\"}\n".to_string();
        }
        if let Some(rest) = line.strip_prefix("exec ") {
            self.audit("exec", rest);
            if self.exec_rate_limited() {
                let min_ms = self.exec_min_interval_ms();
                self.audit("exec-denied", "rate-limited");
                return format!("{{\"error\":\"rate-limited\",\"min_interval_ms\":{min_ms}}}\n");
            }
            if self.pty_master < 0 || self.child <= 0 {
                self.audit("exec-denied", "guest not running");
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
            self.audit("expose", rest);
            let parts: Vec<&str> = rest.split_whitespace().collect();
            if self.gvproxy_pid <= 0 {
                return "{\"error\":\"gvproxy not running\"}\n".to_string();
            }
            if parts.len() != 2 {
                return "{\"error\":\"usage: expose <host-port> <guest-port>\"}\n".to_string();
            }
            let (hport, gport) = (parts[0], parts[1]);
            return match self.do_expose(hport, gport) {
                Ok(()) => {
                    let _ = self.save_exposure(hport, gport);
                    format!(
                        "{{\"exposed\":\"127.0.0.1:{hport} -> {}:{gport}\"}}\n",
                        self.cfg.guest_ip
                    )
                }
                Err(e) => format!("{{\"error\":{}}}\n", serde_json::to_string(&e).unwrap()),
            };
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

/// gvproxy's command line. Kept pure (and tested) so the port/lock
/// behaviour cannot drift silently: `-ssh-port` must be settable per instance
/// because gvproxy hard-binds that host port.
fn gvproxy_argv(
    binary: &str,
    bess: &str,
    ssh_port: u16,
    need_proot: bool,
    prefix: &str,
) -> Vec<String> {
    let mut argv = Vec::new();
    if need_proot {
        argv.push("proot".to_string());
        argv.push("-b".to_string());
        argv.push(format!("{prefix}/etc:/etc"));
    }
    argv.push(binary.to_string());
    argv.push("-debug".to_string());
    argv.push(format!("-listen=unix://{bess}.gv.sock"));
    argv.push(format!("-listen-bess=unixpacket://{bess}"));
    argv.push(format!("-log-file={bess}.gv.log"));
    argv.push("-ssh-port".to_string());
    argv.push(ssh_port.to_string());
    argv
}

/// True when `chunk` (appended to `tail`, capped) contains UML's ubd failure
/// banner. The kernel prints it in several pieces, so a rolling tail of the
/// last few KB is kept and both known lines are searched.
fn scan_ubd_failure(tail: &mut Vec<u8>, chunk: &[u8]) -> bool {
    const TAIL_MAX: usize = 8192;
    const NEEDLES: [&[u8]; 2] = [b"Failed to initialize ubd device", b"Failed to lock"];
    tail.extend_from_slice(chunk);
    if tail.len() > TAIL_MAX {
        let cut = tail.len() - TAIL_MAX;
        tail.drain(..cut);
    }
    NEEDLES
        .iter()
        .any(|n| tail.windows(n.len()).any(|w| w == *n))
}

/// Extract a `"field":"<prefix><value>"` value from a registry line, e.g.
/// json_field(line, "local") on {"local":"127.0.0.1:8124"} gives "8124".
fn json_field(line: &str, field: &str) -> Option<String> {
    let v: serde_json::Value = serde_json::from_str(line).ok()?;
    let s = v.get(field)?.as_str()?;
    Some(s.rsplit(':').next().unwrap_or(s).to_string())
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

/// UTC timestamp in the same shape the C daemon writes.
fn format_utc(secs: u64) -> String {
    let t = secs as libc::time_t;
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    if unsafe { libc::gmtime_r(&t, &mut tm) }.is_null() {
        return format!("{secs}");
    }
    format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z",
        tm.tm_year + 1900,
        tm.tm_mon + 1,
        tm.tm_mday,
        tm.tm_hour,
        tm.tm_min,
        tm.tm_sec
    )
}

/// SO_PEERCRED: the kernel's answer about who connected, never the client's claim.
/// Mirrors peer_is_owner() in src/uml4termuxd.c, including the fail-open path when
/// the kernel will not tell us.
fn peer_is_owner(fd: RawFd) -> bool {
    let mut cr: libc::ucred = unsafe { std::mem::zeroed() };
    let mut len = std::mem::size_of::<libc::ucred>() as libc::socklen_t;
    let rc = unsafe {
        libc::getsockopt(
            fd,
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            &mut cr as *mut _ as *mut libc::c_void,
            &mut len,
        )
    };
    if rc != 0 {
        logf("peer check: SO_PEERCRED unavailable; accepting this connection");
        return true;
    }
    cr.uid == unsafe { libc::geteuid() }
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
    fn selftest_child_argv_carries_its_lifetime() {
        let mut d = test_daemon(true);
        d.selftest_seconds = "4242".to_string();
        let (argv, use_pty) = d.selftest_argv();
        assert_eq!(argv.len(), 2);
        assert_eq!(argv[1], "4242");
        assert!(!use_pty, "the selftest child is not run on a PTY");
        // default must match the C daemon
        assert_eq!(SELFTEST_SECONDS_DEFAULT, "30");
    }

    #[test]
    fn protocol_reply_is_the_v1_contract() {
        let mut d = test_daemon(true);
        assert_eq!(
            d.dispatch("protocol"),
            "{\"protocol\":1,\"runtime_contract\":1,\"commands\":[\"status\",\"stop\",\"ports\",\"expose\",\"exec\",\"protocol\"]}\n"
        );
    }

    #[test]
    fn gvproxy_argv_pins_the_ssh_port_and_supports_a_proot_wrapper() {
        let argv = gvproxy_argv("/bin/gvproxy", "/tmp/bess.sock", 2222, false, "/usr");
        assert_eq!(argv[0], "/bin/gvproxy");
        assert!(argv.contains(&"-listen=unix:///tmp/bess.sock.gv.sock".to_string()));
        assert!(argv.contains(&"-listen-bess=unixpacket:///tmp/bess.sock".to_string()));
        let i = argv
            .iter()
            .position(|a| a == "-ssh-port")
            .expect("-ssh-port must be set");
        assert_eq!(argv[i + 1], "2222");

        // a second instance must be able to pick another port
        let other = gvproxy_argv("/bin/gvproxy", "/tmp/b2.sock", 12224, false, "/usr");
        let j = other.iter().position(|a| a == "-ssh-port").unwrap();
        assert_eq!(other[j + 1], "12224");

        // Termux: wrap in proot so gvproxy can read /etc/resolv.conf
        let wrapped = gvproxy_argv(
            "/bin/gvproxy",
            "/tmp/b.sock",
            2222,
            true,
            "/data/data/com.termux/files/usr",
        );
        assert_eq!(wrapped[0], "proot");
        assert_eq!(wrapped[1], "-b");
        assert_eq!(wrapped[2], "/data/data/com.termux/files/usr/etc:/etc");
        assert_eq!(wrapped[3], "/bin/gvproxy");
    }

    #[test]
    fn ubd_failure_is_detected_across_split_writes() {
        let mut tail = Vec::new();
        assert!(!scan_ubd_failure(&mut tail, b"normal boot chatter\n"));
        assert!(!scan_ubd_failure(&mut tail, b"Failed to initial"));
        // the needle is split across two reads: only now is it complete
        assert!(scan_ubd_failure(&mut tail, b"ize ubd device 0 :(null)\n"));
    }

    #[test]
    fn lock_failure_is_detected_and_tail_stays_bounded() {
        let mut tail = Vec::new();
        assert!(scan_ubd_failure(
            &mut tail,
            b"Failed to lock '/img', err = 11\n"
        ));
        let mut tail = Vec::new();
        for _ in 0..2000 {
            assert!(!scan_ubd_failure(&mut tail, &[b'x'; 64]));
        }
        assert!(
            tail.len() <= 8192,
            "tail must stay bounded, got {}",
            tail.len()
        );
    }

    #[test]
    fn strict_ubd_is_opt_in() {
        // default construction (no env var) must not abort on a diskless boot
        let d = test_daemon(false);
        assert!(
            !d.strict_ubd,
            "strict mode must be opt-in via UML4TERMUXD_STRICT_UBD"
        );
    }

    #[test]
    fn json_field_reads_the_port_out_of_a_registry_line() {
        let line = "{\"local\":\"127.0.0.1:8124\",\"remote\":\"192.168.127.2:80\"}";
        assert_eq!(json_field(line, "local").as_deref(), Some("8124"));
        assert_eq!(json_field(line, "remote").as_deref(), Some("80"));
        assert_eq!(json_field("not json", "local"), None);
    }

    #[test]
    fn save_exposure_dedups_the_same_host_port() {
        let d = test_daemon(true);
        let dir = std::env::temp_dir().join(format!(
            "u4t-exp-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .subsec_nanos()
        ));
        fs::create_dir_all(&dir).unwrap();
        let d = Daemon {
            exposures_path: Some(dir.join("exposures.jsonl")),
            ..d
        };
        d.save_exposure("8124", "80").unwrap();
        d.save_exposure("8125", "81").unwrap();
        d.save_exposure("8124", "8080").unwrap(); // same host port: replace
        let text = fs::read_to_string(d.exposures_path.clone().unwrap()).unwrap();
        assert_eq!(text.lines().count(), 2, "expected 2 entries, got: {text}");
        assert!(text.contains("8124\",\"remote\":\"192.168.127.2:8080"));
        assert!(!text.contains(":80\""));
        assert_eq!(d.exposure_count(), 2);
        let ports = d.ports_json();
        assert!(ports.starts_with("{\"exposures\":["));
        assert!(ports.contains("8125"));
        fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn do_expose_accepts_200_and_rejects_errors_from_gvproxy() {
        use std::os::unix::net::UnixListener;
        let d = test_daemon(true);
        let sock = std::env::temp_dir().join(format!(
            "u4t-gvapi-{}-{}.sock",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .subsec_nanos()
        ));
        let _ = fs::remove_file(&sock);

        // A fake gvproxy that answers the expose POST with 200.
        let listener = UnixListener::bind(&sock).unwrap();
        let handle = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut buf = [0u8; 1024];
            let n = stream.read(&mut buf).unwrap();
            let req = String::from_utf8_lossy(&buf[..n]).to_string();
            assert!(req.starts_with("POST /services/forwarder/expose"));
            assert!(req.contains("\"local\":\"127.0.0.1:8124\""));
            assert!(req.contains("\"remote\":\"192.168.127.2:80\""));
            stream.write_all(b"HTTP/1.1 200 OK\r\n\r\n").unwrap();
        });
        let d = Daemon {
            gvapi: sock.to_string_lossy().to_string(),
            ..d
        };
        assert_eq!(d.do_expose("8124", "80"), Ok(()));
        handle.join().unwrap();
        fs::remove_file(&sock).ok();

        // An unreachable API is reported, not panicked on.
        let d = Daemon {
            gvapi: "/nonexistent/gv.sock".to_string(),
            ..d
        };
        assert_eq!(
            d.do_expose("1", "1"),
            Err("gvproxy API unreachable".to_string())
        );
    }

    #[test]
    fn http_response_matches_the_c_daemon_bytes() {
        let d = test_daemon(true);
        let idle = d.http_response();
        assert!(idle.starts_with("HTTP/1.0 200 OK\r\nContent-Type: application/json\r\n\r\n"));
        assert!(idle.contains("{\"ok\":true,\"state\":\"idle\",\"child_pid\":-1,"));
        assert!(idle.contains("\"mode\":\"persistent\""));
        assert!(idle.ends_with("}\r\n"));

        let mut d = test_daemon(true);
        d.child = 4242;
        d.cow = "/tmp/x.cow".into();
        let running = d.http_response();
        assert!(running.contains("\"state\":\"running\",\"child_pid\":4242,"));
        assert!(running.contains("\"mode\":\"ephemeral-cow\""));
    }

    #[test]
    fn expose_reply_matches_the_c_daemon_shape() {
        let mut d = test_daemon(true);
        // gvproxy absent -> the same error the C daemon prints
        assert_eq!(
            d.dispatch("expose 8124 80"),
            "{\"error\":\"gvproxy not running\"}\n"
        );
        // one argument -> usage error, as in C
        d.gvproxy_pid = 1234;
        assert_eq!(
            d.dispatch("expose 8124"),
            "{\"error\":\"usage: expose <host-port> <guest-port>\"}\n"
        );
    }

    /// Regression: a refactor once routed the NON-selftest branch through the
    /// selftest helper, which returned an empty argv -- the child then exec'd
    /// nothing and died with SIGSEGV in ~0.1s while every unit test passed.
    /// The two modes must stay separate: the guest mode always builds a real
    /// UML command line and uses a PTY console.
    #[test]
    fn guest_mode_never_yields_an_empty_argv() {
        let d = test_daemon(false);
        let (argv, use_pty) = if d.selftest {
            d.selftest_argv()
        } else {
            (d.guest_argv(), true)
        };
        assert!(!argv.is_empty(), "guest argv must never be empty");
        assert!(use_pty, "the guest console is driven through a PTY");
        assert!(
            argv.iter().any(|a| a.starts_with("ubd0=")),
            "the guest needs its disk option: {argv:?}"
        );
        assert!(
            argv.iter().any(|a| a.starts_with("initrd=")),
            "the guest needs its initramfs: {argv:?}"
        );
        assert_eq!(argv[0], d.kernel, "argv[0] is the kernel path");
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
