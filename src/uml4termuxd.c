/*
 * uml4termuxd — the UML runtime as a binary daemon (0.4.0, roadmap A1).
 *
 * One binary, two roles:
 *   uml4termuxd daemon [--selftest]   foreground supervisor (runit `run` execs this)
 *   uml4termuxd status|stop           client over the control socket
 *
 * Supervision contract (v1):
 *   - spawn the configured child (in --selftest: /bin/sleep 30) with
 *     fork/exec, reap with waitpid, record exits, restart with backoff
 *   - control socket $UML4TERMUX_RUNTIME/daemon.sock, newline-delimited
 *     JSON requests, newline-delimited JSON responses
 *   - state file daemon.state.json next to the socket (atomic tmp+rename)
 *
 * SPDX-License-Identifier: GPL-2.0-only
 */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/un.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <sys/wait.h>
#include <libgen.h>
#include <pty.h>
#include <time.h>
#include <unistd.h>

#define SOCK_PATH_DEFAULT "/data/data/com.termux/files/home/.uml4termux/daemon.sock"
#define SELFTEST_CHILD_DEFAULT "/data/data/com.termux/files/usr/bin/sleep"
#define RESTART_BACKOFF_S 2
#define RESTART_MAX 5

static volatile sig_atomic_t g_stop = 0;
static volatile sig_atomic_t g_child_exited = 0;
static pid_t g_child = -1;
static int g_restarts = 0;
static char g_sockpath[512];
static char g_statepath[512];
static char g_child_argv0[512];
static char g_consolelog[512];

/* Real-mode guest config (A2): everything comes from the environment so the
   daemon stays free of device-specific paths. */
static char g_kernel[512], g_stub[512], g_image[512], g_initrd[512];
static char g_mem[32], g_ncpus[8];
static char g_gvproxy[512], g_bess[512];
static char g_cow[512];        /* B2: UML native copy-on-write (ephemeral) */
static time_t g_started_at;
static int g_completed; /* last guest session ended cleanly (exit 0) */

/* A2b/A3 runtime state */
static int g_ptym = -1;        /* PTY master: guest console lives here */
static int g_logfd = -1;       /* console log file fd */
static pid_t g_gvproxy_pid = -1;
static int g_exec_seq;
static char g_exposures[512];  /* A3b: registry file (JSONL) */
static char g_gvapi[512];      /* gvproxy unix API socket path */

/* fixed gvproxy DHCP topology (verified across all runs) */
#define GUEST_IP "192.168.127.2"

static const char *env_or(const char *name, const char *def)
{
	const char *v = getenv(name);
	return (v && *v) ? v : def;
}

static int load_guest_config(char *err, size_t errn)
{
	struct stat st;
	const char *parts[] = { g_kernel, g_stub, g_image, g_initrd };
	const char *names[] = { "kernel", "stub", "image", "initramfs" };
	int i;

	snprintf(g_kernel, sizeof(g_kernel), "%s", env_or("UML4TERMUXD_KERNEL", ""));
	snprintf(g_stub, sizeof(g_stub), "%s", env_or("UML4TERMUXD_STUB", ""));
	snprintf(g_image, sizeof(g_image), "%s", env_or("UML4TERMUXD_IMAGE", ""));
	snprintf(g_initrd, sizeof(g_initrd), "%s", env_or("UML4TERMUXD_INITRAMFS", ""));
	snprintf(g_mem, sizeof(g_mem), "%s", env_or("UML4TERMUXD_MEM", "1024M"));
	snprintf(g_ncpus, sizeof(g_ncpus), "%s", env_or("UML4TERMUXD_NCPUS", "4"));
	snprintf(g_gvproxy, sizeof(g_gvproxy), "%s", env_or("UML4TERMUXD_GVPROXY", ""));
	snprintf(g_bess, sizeof(g_bess), "%s", env_or("UML4TERMUXD_BESS", ""));
	/* B2 ephemeral mode: UML's native ubd copy-on-write.  Writes land in the
	   COW file, the backing image stays pristine; the COW is reset per boot. */
	snprintf(g_cow, sizeof(g_cow), "%s", env_or("UML4TERMUXD_COW", ""));

	for (i = 0; i < 4; i++) {
		if (!parts[i][0]) {
			snprintf(err, errn, "UML4TERMUXD_%s is not set",
				 names[i] == g_kernel ? (char *)"KERNEL" :
				 names[i] == g_stub ? (char *)"STUB" :
				 names[i] == g_image ? (char *)"IMAGE" : (char *)"INITRAMFS");
			return -1;
		}
		if (stat(parts[i], &st) != 0) {
			snprintf(err, errn, "%s not found: %s", names[i], parts[i]);
			return -1;
		}
	}
	return 0;
}

static void logf_(const char *fmt, ...)
{
	va_list ap;
	struct timespec ts;
	char stamp[32];

	clock_gettime(CLOCK_REALTIME, &ts);
	snprintf(stamp, sizeof(stamp), "%ld.%03ld", (long)ts.tv_sec, ts.tv_nsec / 1000000);
	flockfile(stderr);
	fprintf(stderr, "[%s] uml4termuxd[%d]: ", stamp, (int)getpid());
	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
	fputc('\n', stderr);
	funlockfile(stderr);
}

static void on_sigint(int s) { (void)s; g_stop = 1; }
static void on_sigterm(int s) { (void)s; g_stop = 1; }
static void on_sigchld(int s) { (void)s; g_child_exited = 1; }

static void write_state(const char *state)
{
	char tmp[600];
	int fd;
	size_t len = strlen(state);

	snprintf(tmp, sizeof(tmp), "%s.tmp", g_statepath);
	fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0644);
	if (fd < 0) {
		logf_("state write open failed: %s", strerror(errno));
		return;
	}
	if (write(fd, state, len) != (ssize_t)len)
		logf_("state write short: %s", strerror(errno));
	close(fd);
	if (rename(tmp, g_statepath) != 0)
		logf_("state rename failed: %s", strerror(errno));
}

static void state_json(const char *phase, const char *detail)
{
	char buf[1024];
	struct timespec ts;

	clock_gettime(CLOCK_REALTIME, &ts);
	snprintf(buf, sizeof(buf),
		 "{\"phase\":\"%s\",\"child_pid\":%d,\"restarts\":%d,\"detail\":\"%s\",\"ts\":%ld}\n",
		 phase, (int)g_child, g_restarts, detail ? detail : "", (long)ts.tv_sec);
	write_state(buf);
}

static void stop_gvproxy(void)
{
	int i;

	if (g_gvproxy_pid <= 0)
		return;
	/* The child called setsid() before exec'ing (possibly via proot, whose
	   tracee would survive a bare kill of the proot pid): signal the whole
	   process GROUP, then escalate to SIGKILL for the group too. */
	kill(-g_gvproxy_pid, SIGTERM);
	for (i = 0; i < 10; i++) {
		if (waitpid(g_gvproxy_pid, NULL, WNOHANG) != 0)
			break;
		usleep(200000);
	}
	if (waitpid(g_gvproxy_pid, NULL, WNOHANG) == 0) {
		logf_("gvproxy group ignored SIGTERM, SIGKILL");
		kill(-g_gvproxy_pid, SIGKILL);
		waitpid(g_gvproxy_pid, NULL, 0);
	}
	logf_("gvproxy stopped");
	g_gvproxy_pid = -1;
}

/* ---- A3b: port exposure registry (JSONL) + gvproxy unix-HTTP client ---- */

static int unix_http(const char *sockpath, const char *req,
		     char *resp, size_t rlen)
{
	struct sockaddr_un addr;
	int fd, rc;
	ssize_t n;
	size_t got = 0;
	struct pollfd pfd;

	fd = socket(AF_UNIX, SOCK_STREAM, 0);
	if (fd < 0)
		return -1;
	memset(&addr, 0, sizeof(addr));
	addr.sun_family = AF_UNIX;
	strncpy(addr.sun_path, sockpath, sizeof(addr.sun_path) - 1);
	if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
		close(fd);
		return -1;
	}
	if (write(fd, req, strlen(req)) < 0) {
		close(fd);
		return -1;
	}
	pfd.fd = fd;
	pfd.events = POLLIN;
	for (;;) {
		rc = poll(&pfd, 1, 4000);
		if (rc <= 0)
			break;
		n = read(fd, resp + got, rlen - 1 - got);
		if (n <= 0)
			break;
		got += (size_t)n;
		if (got >= rlen - 1)
			break;
	}
	close(fd);
	resp[got] = '\0';
	return got > 0 ? 0 : -1;
}

static int do_expose(const char *hport, const char *gport, char *err, size_t errn)
{
	char local[64], remote[64], json[256], req[512], resp[1024];

	snprintf(local, sizeof(local), "127.0.0.1:%s", hport);
	snprintf(remote, sizeof(remote), "%s:%s", GUEST_IP, gport);
	snprintf(json, sizeof(json),
		 "{\"local\":\"%s\",\"remote\":\"%s\"}", local, remote);
	snprintf(req, sizeof(req),
		 "POST /services/forwarder/expose HTTP/1.1\r\n"
		 "Host: unix\r\nContent-Type: application/json\r\n"
		 "Content-Length: %zu\r\nConnection: close\r\n\r\n%s",
		 strlen(json), json);
	if (unix_http(g_gvapi, req, resp, sizeof(resp)) != 0) {
		snprintf(err, errn, "gvproxy API unreachable");
		return -1;
	}
	if (!strstr(resp, "200")) {
		snprintf(err, errn, "gvproxy rejected: %.80s", resp);
		return -1;
	}
	logf_("exposed %s -> %s", local, remote);
	return 0;
}

static void save_exposure(const char *hport, const char *gport)
{
	char line[192], tmp[600];
	FILE *f;

	/* de-dup: drop an existing entry for the same host port */
	snprintf(line, sizeof(line), "\"local\":\"127.0.0.1:%s\"", hport);
	snprintf(tmp, sizeof(tmp), "%s.tmp", g_exposures);
	{
		FILE *in = fopen(g_exposures, "r");
		FILE *out = fopen(tmp, "w");
		char buf[256];

		if (out) {
			if (in) {
				while (fgets(buf, sizeof(buf), in))
					if (!strstr(buf, line))
						fputs(buf, out);
				fclose(in);
			}
			fprintf(out, "{\"local\":\"127.0.0.1:%s\",\"remote\":\"%s:%s\"}\n",
				hport, GUEST_IP, gport);
			fclose(out);
			rename(tmp, g_exposures);
		}
	}
	f = fopen(g_exposures, "a");
	(void)f; /* entry appended via the tmp+rename above */
}

static void reapply_exposures(void)
{
	FILE *f;
	char buf[256];
	int n = 0;

	f = fopen(g_exposures, "r");
	if (!f)
		return;
	while (fgets(buf, sizeof(buf), f)) {
		char *lp = strstr(buf, "\"local\":\"127.0.0.1:");
		char *rp = strstr(buf, "\"remote\":\"" GUEST_IP ":");
		char hport[32] = "", gport[32] = "";
		char err[128];

		if (!lp || !rp)
			continue;
		sscanf(lp + strlen("\"local\":\"127.0.0.1:"), "%31[^\":]", hport);
		sscanf(rp + strlen("\"remote\":\"" GUEST_IP ":"), "%31[^\":]", gport);
		if (do_expose(hport, gport, err, sizeof(err)) == 0)
			n++;
		else
			logf_("re-expose %s->%s failed: %s", hport, gport, err);
	}
	fclose(f);
	if (n)
		logf_("re-applied %d exposure(s) from the registry", n);
}
/* ---- end A3b ---- */

/* spawn gvproxy (A3) when configured; wait for the bess socket. */
static int spawn_gvproxy(void)
{
	pid_t pid;
	int i;

	if (!g_gvproxy[0])
		return 0; /* not configured: guest runs without networking */
	if (!g_bess[0]) {
		logf_("UML4TERMUXD_GVPROXY set but no UML4TERMUXD_BESS");
		return -1;
	}
	pid = fork();
	if (pid < 0)
		return -1;
	if (pid == 0) {
		char largs[600], bargs[600], fargs[600];
		char *argv[12];
		int i = 0;
		int need_proot;

		snprintf(largs, sizeof(largs), "-listen=unix://%s.gv.sock", g_bess);
		snprintf(bargs, sizeof(bargs), "-listen-bess=unixpacket://%s", g_bess);
		snprintf(fargs, sizeof(fargs), "-log-file=%s.gv.log", g_bess);
		/* Termux has no /etc; gvproxy wants /etc/resolv.conf -> bind the
		   Termux etc over it with proot (skipped elsewhere). */
		need_proot = access("/etc/resolv.conf", R_OK) != 0 &&
			     access("/data/data/com.termux", F_OK) == 0;
		if (need_proot) {
			static char pb[600];

			snprintf(pb, sizeof(pb), "%s/etc:/etc",
				 env_or("PREFIX", "/data/data/com.termux/files/usr"));
			argv[i++] = "proot";
			argv[i++] = "-b";
			argv[i++] = pb;
		}
		argv[i++] = (char *)g_gvproxy;
		argv[i++] = "-debug";
		argv[i++] = largs;
		argv[i++] = bargs;
		argv[i++] = fargs;
		argv[i] = NULL;
		setsid();
		execvp(argv[0], argv);
		logf_("exec gvproxy failed: %s", strerror(errno));
		_exit(127);
	}
	g_gvproxy_pid = pid;
	for (i = 0; i < 50; i++) { /* up to 5 s for the bess socket */
		struct stat st;

		if (stat(g_bess, &st) == 0 && S_ISSOCK(st.st_mode)) {
			logf_("gvproxy up pid=%d bess=%s", (int)pid, g_bess);
			snprintf(g_gvapi, sizeof(g_gvapi), "%s.gv.sock", g_bess);
			return 0;
		}
		usleep(100000);
	}
	logf_("gvproxy did not create %s", g_bess);
	g_gvproxy_pid = -1;
	return -1;
}

/* ---- B2: UML COW v3 header writer (format from arch/um/drivers/cow_user.c:
   magic MOOO be32, version 3 be32, mtime be32, size be64, sectorsize be32,
   alignment be32, cow_format(=COW_BITMAP 0) be32, backing[4096] packed) ---- */
#define COW_PATH_V3 4096
static int write_cow_header_file(const char *cowpath, const char *image)
{
	unsigned char hdr[12 + 8 + 12 + COW_PATH_V3]; /* packed v3 = 4128 */
	unsigned long long size, bitmap_len, data_offset;
	struct stat st;
	char absimage[1024];
	unsigned int mtime;
	int fd, i;

	if (!realpath(image, absimage)) {
		logf_("cow: cannot resolve image %s: %s", image, strerror(errno));
		return -1;
	}
	if (stat(absimage, &st) != 0) {
		logf_("cow: image stat failed: %s", strerror(errno));
		return -1;
	}
	size = (unsigned long long)st.st_size;
	mtime = (unsigned int)st.st_mtime;

	memset(hdr, 0, sizeof(hdr));
#define be32(v) (unsigned char)((v) >> 24), (unsigned char)((v) >> 16), \
                (unsigned char)((v) >> 8), (unsigned char)(v)
#define be64(v) be32((unsigned int)((v) >> 32)), be32((unsigned int)(v))
	i = 0;
	{
		static const unsigned char magic_be[4] = {0x4f, 0x4f, 0x4f, 0x4d}; /* MOOO */
		memcpy(hdr + i, magic_be, 4); i += 4;                       /* magic */
		hdr[i++] = 0; hdr[i++] = 0; hdr[i++] = 0; hdr[i++] = 3;     /* version 3 */
		hdr[i++] = (unsigned char)(mtime >> 24); hdr[i++] = (unsigned char)(mtime >> 16);
		hdr[i++] = (unsigned char)(mtime >> 8);  hdr[i++] = (unsigned char)mtime;
		hdr[i++] = (unsigned char)(size >> 56); hdr[i++] = (unsigned char)(size >> 48);
		hdr[i++] = (unsigned char)(size >> 40); hdr[i++] = (unsigned char)(size >> 32);
		hdr[i++] = (unsigned char)(size >> 24); hdr[i++] = (unsigned char)(size >> 16);
		hdr[i++] = (unsigned char)(size >> 8);  hdr[i++] = (unsigned char)size;
		hdr[i++] = 0; hdr[i++] = 0; hdr[i++] = 2; hdr[i++] = 0;     /* sectorsize 512 */
		hdr[i++] = 0; hdr[i++] = 0; hdr[i++] = 2; hdr[i++] = 0;     /* alignment 512 */
		hdr[i++] = 0; hdr[i++] = 0; hdr[i++] = 0; hdr[i++] = 0;     /* cow_format = bitmap */
		strncpy((char *)hdr + i, absimage, sizeof(hdr) - i - 1);
	}
#undef be32
#undef be64

	fd = open(cowpath, O_WRONLY | O_CREAT | O_TRUNC, 0644);
	if (fd < 0) {
		logf_("cow: open %s failed: %s", cowpath, strerror(errno));
		return -1;
	}
	if (write(fd, hdr, sizeof(hdr)) != (ssize_t)sizeof(hdr)) {
		logf_("cow: header write failed: %s", strerror(errno));
		close(fd);
		return -1;
	}
	/* bitmap covers size/512 sectors; data starts at round_up(4128,512) +
	   bitmap_len.  Seek to the last data byte and write one zero to set
	   EOF -- this leaves the whole bitmap zeroed (sparse). */
	bitmap_len = size / 4096;                       /* (size/512)/8 */
	data_offset = 4608 + bitmap_len;                /* round_up(4128,512)=4608 */
	if (lseek(fd, (off_t)(data_offset + size - 1), SEEK_SET) == (off_t)-1 ||
	    write(fd, "\0", 1) != 1) {
		logf_("cow: EOF poke failed: %s", strerror(errno));
		close(fd);
		return -1;
	}
	close(fd);
	logf_("cow header written: %s (backing %s, %llu bytes)", cowpath, absimage, size);
	return 0;
}

static int spawn_child(void)
{
	pid_t pid;

	if (g_kernel[0]) {
		/* real guest (A2/A2b): console on a PTY, output -> console log */
		char memopt[64], cpusopt[32], ubdopt[600], rdopt[600], stubopt[600];
		char vecopt[600];
		char *argv[16];
		int m = -1, i = 0;

		snprintf(memopt, sizeof(memopt), "mem=%s", g_mem);
		snprintf(cpusopt, sizeof(cpusopt), "ncpus=%s", g_ncpus);
		snprintf(ubdopt, sizeof(ubdopt), "ubd0=%s", g_image);
		snprintf(rdopt, sizeof(rdopt), "initrd=%s", g_initrd);
		snprintf(stubopt, sizeof(stubopt), "stub_exe=%s", g_stub);
		argv[i++] = g_kernel;
		argv[i++] = memopt;
		argv[i++] = cpusopt;
		argv[i++] = "seccomp=on";
		if (g_cow[0]) {
			/* B2 ephemeral: UML's syntax is ubd0=<cow>,<backing> --
			   the COW file comes FIRST, the backing image second. */
			snprintf(ubdopt, sizeof(ubdopt), "ubd0=%s,%s", g_cow, g_image);
		}
		argv[i++] = ubdopt;
		argv[i++] = "root=/dev/ubda";
		argv[i++] = "rw";
		argv[i++] = rdopt;
		argv[i++] = stubopt;
		argv[i++] = "panic=-1";
		argv[i++] = "con=null";
		argv[i++] = "con0=fd:0,fd:1";
		if (g_gvproxy_pid > 0) {
			snprintf(vecopt, sizeof(vecopt),
				 "vec0:transport=bess,dst=%s,depth=128,gro=1,mac=5a:94:ef:e4:0c:ee",
				 g_bess);
			argv[i++] = vecopt;
		}
		argv[i] = NULL;

		/* B2: this port's ubd driver requires a FORMATTED COW file -- it
		   stats and reads the header but never creates one.  Reset the
		   COW per boot (fresh state) by writing a v3 header. */
		if (g_cow[0] && write_cow_header_file(g_cow, g_image) != 0) {
			logf_("cow header write failed; booting without COW");
		}

		/* A2b: the console is a PTY slave -- the daemon writes to the
		   master (exec channel) and drains the master into the log. */
		pid = forkpty(&m, NULL, NULL, NULL);
		if (pid < 0) {
			logf_("forkpty failed: %s", strerror(errno));
			return -1;
		}
		if (pid == 0) {
			execv(g_kernel, argv);
			_exit(127);
		}
		g_ptym = m;
		fcntl(g_ptym, F_SETFL, fcntl(g_ptym, F_GETFL) | O_NONBLOCK);
		g_logfd = open(g_consolelog, O_WRONLY | O_CREAT | O_TRUNC, 0644);
	} else {
		pid = fork();
		if (pid < 0) {
			logf_("fork failed: %s", strerror(errno));
			return -1;
		}
		if (pid == 0) {
			char *argv[] = { g_child_argv0, "30", NULL };

			execv(argv[0], argv);
			_exit(127);
		}
	}
	g_child = pid;
	g_completed = 0;
	g_started_at = time(NULL);
	logf_("child spawned pid=%d argv0=%s", (int)pid,
	      g_kernel[0] ? g_kernel : g_child_argv0);
	state_json("running", "spawned");
	return 0;
}

/* stop_child: B2 clean shutdown first -- a guest `poweroff -f` through the
   console exec channel keeps the image consistent; escalate to signals when
   the console channel cannot deliver (no agent yet) or the guest hangs. */
static void stop_child(int timeout_s)
{
	int waited = 0;

	if (g_child <= 0)
		return;
	if (g_ptym >= 0) {
		char line[96];
		int clean = 0;

		snprintf(line, sizeof(line), "exec:sync; poweroff -f\n");
		if (write(g_ptym, line, strlen(line)) > 0) {
			logf_("stop: clean poweroff via console (20 s budget)");
			while (waitpid(g_child, NULL, WNOHANG) == 0 && clean < 40) {
				usleep(500000);
				clean++;
			}
			if (waitpid(g_child, NULL, WNOHANG) != 0) {
				g_child = -1;
				logf_("clean poweroff landed after %d.%ds", clean / 2, (clean % 2) * 5);
				return;
			}
			logf_("clean poweroff did not land; falling back to signals");
		}
	}
	kill(g_child, SIGTERM);
	waited = 0;
	while (waitpid(g_child, NULL, WNOHANG) == 0 && waited < timeout_s * 5) {
		usleep(200000);
		waited++;
	}
	if (waitpid(g_child, NULL, WNOHANG) == 0) {
		logf_("SIGTERM ignored for %ds, sending SIGKILL", timeout_s);
		kill(g_child, SIGKILL);
		waitpid(g_child, NULL, 0);
	}
	g_child = -1;
}

static void reap_child(void)
{
	int st;
	pid_t pid;

	g_child_exited = 0;
	while ((pid = waitpid(-1, &st, WNOHANG)) > 0) {
		if (pid == g_child) {
			char detail[128];
			const char *how = WIFEXITED(st) ? "exit" : "signal";
			int code = WIFEXITED(st) ? WEXITSTATUS(st) : WTERMSIG(st);

			g_child = -1;
			snprintf(detail, sizeof(detail), "%s=%d", how, code);
			logf_("child %d died (%s %d)", (int)pid, how, code);
			/* exit 0 = the guest powered itself off after completing
			   its session (poweroff -f). That is a finished session,
			   not a crash: stay stopped. Only crashes restart. */
			if (WIFEXITED(st) && WEXITSTATUS(st) == 0) {
				state_json("completed", detail);
				g_completed = 1;
				logf_("guest session completed; not restarting");
				if (g_ptym >= 0) {
					close(g_ptym);
					g_ptym = -1;
				}
				if (g_logfd >= 0) {
					close(g_logfd);
					g_logfd = -1;
				}
				stop_gvproxy();
				return;
			}
			/* exec failure (126/127) is a configuration error, not a
			   guest crash: restarting would loop forever. Give up. */
			if (WIFEXITED(st) && (WEXITSTATUS(st) == 126 || WEXITSTATUS(st) == 127)) {
				state_json("failed", detail);
				logf_("exec/config failure (%s); giving up", detail);
				g_stop = 1;
				return;
			}
			state_json("exited", detail);
			g_restarts++;
			if (g_restarts > RESTART_MAX) {
				logf_("restart limit %d reached, giving up", RESTART_MAX);
				state_json("failed", "restart-limit");
				g_stop = 1;
				return;
			}
			sleep(RESTART_BACKOFF_S * g_restarts);
			if (!g_stop && spawn_child() != 0)
				g_stop = 1;
		}
	}
}

static int respond(int fd, const char *json)
{
	return (int)write(fd, json, strlen(json));
}

static void handle_client(int fd)
{
	char req[512];
	char resp[512];
	ssize_t n;

	n = read(fd, req, sizeof(req) - 1);
	if (n <= 0)
		return;
	req[n] = '\0';
	for (ssize_t i = 0; i < n; i++)
		if (req[i] == '\n' || req[i] == '\r')
			req[i] = '\0';

	if (strncmp(req, "status", 6) == 0) {
		char info[192];

		if (g_kernel[0]) {
			snprintf(info, sizeof(info),
				 ",\"kernel\":\"%s\",\"mem\":\"%s\",\"ncpus\":\"%s\",\"uptime_s\":%ld",
				 g_kernel, g_mem, g_ncpus,
				 g_child > 0 ? (long)(time(NULL) - g_started_at) : 0L);
		} else {
			snprintf(info, sizeof(info), ",\"mode\":\"selftest\"");
		}
		snprintf(resp, sizeof(resp),
			 "{\"state\":\"%s\",\"child_pid\":%d,\"restarts\":%d%s}\n",
			 g_child > 0 ? "running" : (g_completed ? "completed" : "idle"),
			 (int)g_child, g_restarts, info);
		respond(fd, resp);
	} else if (strncmp(req, "stop", 4) == 0) {
		if (g_child > 0)
			logf_("stop requested: SIGTERM -> %d", (int)g_child);
		respond(fd, "{\"state\":\"stopping\"}\n");
		g_stop = 1;
	} else if (strncmp(req, "exec ", 5) == 0) {
		char line[1024];
		int seq;

		if (g_ptym < 0 || g_child <= 0) {
			respond(fd, "{\"error\":\"guest not running\"}\n");
		} else {
			seq = ++g_exec_seq;
			snprintf(line, sizeof(line),
				 "exec:echo __EXEC_%d_BEGIN__; %s; echo __EXEC_%d_DONE_$?\n",
				 seq, req + 5, seq);
			if (write(g_ptym, line, strlen(line)) < 0) {
				snprintf(resp, sizeof(resp),
					 "{\"error\":\"pty write failed: %s\"}\n",
					 strerror(errno));
				respond(fd, resp);
			} else {
				snprintf(resp, sizeof(resp),
					 "{\"started\":true,\"seq\":%d,\"console\":\"%s\"}\n",
					 seq, g_consolelog);
				respond(fd, resp);
			}
		}
	} else if (strncmp(req, "expose ", 7) == 0) {
		char hport[32] = "", gport[32] = "";
		char err[128];

		if (g_gvproxy_pid <= 0) {
			respond(fd, "{\"error\":\"gvproxy not running\"}\n");
		} else if (sscanf(req + 7, "%31s %31s", hport, gport) != 2) {
			respond(fd, "{\"error\":\"usage: expose <host-port> <guest-port>\"}\n");
		} else if (do_expose(hport, gport, err, sizeof(err)) != 0) {
			snprintf(resp, sizeof(resp), "{\"error\":\"%s\"}\n", err);
			respond(fd, resp);
		} else {
			save_exposure(hport, gport);
			snprintf(resp, sizeof(resp),
				 "{\"exposed\":\"127.0.0.1:%s -> %s:%s\"}\n",
				 hport, GUEST_IP, gport);
			respond(fd, resp);
		}
	} else if (strncmp(req, "ports", 5) == 0) {
		char list[2048] = "";
		FILE *in = fopen(g_exposures, "r");
		char buf[256];

		if (in) {
			while (fgets(buf, sizeof(buf), in)) {
				if (strlen(list) + strlen(buf) >= sizeof(list) - 1)
					break;
				strncat(list, buf, strlen(buf));
			}
			fclose(in);
		}
		{
			size_t l = strlen(list);

			while (l > 0 && (list[l - 1] == '\n' || list[l - 1] == '\r' ||
					 list[l - 1] == ' ' || list[l - 1] == ',')) {
				list[--l] = '\0';
			}
		}
		snprintf(resp, sizeof(resp), "{\"exposures\":[%s]}\n",
			 strlen(list) ? list : "");
		respond(fd, resp);
	} else {
		respond(fd, "{\"error\":\"unknown command\"}\n");
	}
}

/* ---- D2: optional loopback HTTP health endpoint (UML4TERMUXD_HTTP) ---- */
static int g_httpfd = -1;

static int exposure_count(void)
{
	FILE *f;
	char buf[256];
	int n = 0;

	f = fopen(g_exposures, "r");
	if (!f)
		return 0;
	while (fgets(buf, sizeof(buf), f))
		n++;
	fclose(f);
	return n;
}

static void http_serve(int cfd)
{
	char req[512] = {0};
	char body[4096];
	int n;

	(void)!read(cfd, req, sizeof(req) - 1);
	if (g_child > 0) {
		/* mirror the unix-socket status payload (plus exposure count) */
		n = snprintf(body, sizeof(body),
			"HTTP/1.0 200 OK\r\nContent-Type: application/json\r\n\r\n"
			"{\"ok\":true,\"state\":\"running\",\"child_pid\":%d,"
			"\"exposures\":%d,\"mode\":\"%s\"}\r\n",
			g_child, exposure_count(), g_cow[0] ? "ephemeral-cow" : "persistent");
	} else {
		n = snprintf(body, sizeof(body),
			"HTTP/1.0 200 OK\r\nContent-Type: application/json\r\n\r\n"
			"{\"ok\":true,\"state\":\"idle\",\"child_pid\":-1,"
			"\"exposures\":%d,\"mode\":\"%s\"}\r\n",
			exposure_count(), g_cow[0] ? "ephemeral-cow" : "persistent");
	}
	(void)!write(cfd, body, (size_t)n);
}

static int open_http_listener(void)
{
	const char *spec = getenv("UML4TERMUXD_HTTP");
	struct sockaddr_in a;
	int fd, yes = 1;
	char host[128] = "127.0.0.1";
	int port = 9110;

	if (!spec || !*spec)
		return 0;
	{
		char *c = strchr(spec, ':');

		if (c) {
			size_t hl = (size_t)(c - spec);

			if (hl < sizeof(host)) {
				memcpy(host, spec, hl);
				host[hl] = 0;
			}
			port = atoi(c + 1);
		} else {
			port = atoi(spec);
		}
	}
	if (port <= 0 || port > 65535) {
		logf_("http: invalid port in UML4TERMUXD_HTTP, endpoint disabled");
		return 0;
	}
	fd = socket(AF_INET, SOCK_STREAM, 0);
	if (fd < 0)
		return -1;
	setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
	memset(&a, 0, sizeof(a));
	a.sin_family = AF_INET;
	a.sin_port = htons((unsigned short)port);
	if (inet_pton(AF_INET, host, &a.sin_addr) != 1) {
		logf_("http: bad host '%s', endpoint disabled", host);
		close(fd);
		return 0;
	}
	if (bind(fd, (struct sockaddr *)&a, sizeof(a)) < 0 || listen(fd, 4) < 0) {
		logf_("http: bind/listen %s:%d failed: %s", host, port, strerror(errno));
		close(fd);
		return 0;
	}
	g_httpfd = fd;
	logf_("http health endpoint on %s:%d (GET /status)", host, port);
	return 0;
}

static int serve_loop(int lfd)
{
	struct pollfd pfds[3];

	(void)open_http_listener();

	while (!g_stop) {
		int npfd = 1;
		int rc;
		int pty_idx = -1, http_idx = -1;

		pfds[0].fd = lfd;
		pfds[0].events = POLLIN;
		if (g_ptym >= 0) {
			pty_idx = npfd;
			pfds[npfd].fd = g_ptym;
			pfds[npfd].events = POLLIN;
			npfd++;
		}
		if (g_httpfd >= 0) {
			http_idx = npfd;
			pfds[npfd].fd = g_httpfd;
			pfds[npfd].events = POLLIN;
			npfd++;
		}
		rc = poll(pfds, npfd, 500);
		if (g_child_exited)
			reap_child();
		if (rc > 0) {
			/* A2b: drain the guest console into the log */
			if (pty_idx >= 0 && (pfds[pty_idx].revents & (POLLIN | POLLHUP))) {
				char buf[4096];
				ssize_t n;

				while ((n = read(g_ptym, buf, sizeof(buf))) > 0) {
					if (g_logfd >= 0)
						write(g_logfd, buf, (size_t)n);
				}
			}
			if (pfds[0].revents & POLLIN) {
				int cfd = accept(lfd, NULL, NULL);

				if (cfd >= 0) {
					handle_client(cfd);
					close(cfd);
				}
			}
			if (http_idx >= 0 && (pfds[http_idx].revents & POLLIN)) {
				int cfd = accept(g_httpfd, NULL, NULL);

				if (cfd >= 0) {
					http_serve(cfd);
					close(cfd);
				}
			}
		}
	}
	if (g_child > 0) {
		stop_child(5);
	}
	if (g_ptym >= 0) {
		close(g_ptym);
		g_ptym = -1;
	}
	if (g_httpfd >= 0) {
		close(g_httpfd);
		g_httpfd = -1;
	}
	if (g_logfd >= 0) {
		close(g_logfd);
		g_logfd = -1;
	}
	stop_gvproxy();
	logf_("daemon exit");
	state_json("stopped", "daemon-exit");
	return 0;
}

static const char *sock_path(char *buf, size_t n)
{
	const char *rt = getenv("UML4TERMUX_RUNTIME");

	if (rt && *rt)
		snprintf(buf, n, "%s/daemon.sock", rt);
	else
		snprintf(buf, n, "%s", SOCK_PATH_DEFAULT);
	return buf;
}

static int daemon_main(int selftest)
{
	struct sockaddr_un addr;
	int lfd;

	sock_path(g_sockpath, sizeof(g_sockpath));
	snprintf(g_statepath, sizeof(g_statepath), "%s.state", g_sockpath);
	{
		char dirbuf[512];
		snprintf(dirbuf, sizeof(dirbuf), "%s", g_sockpath);
		mkdir(dirname(dirbuf), 0755);
		snprintf(g_consolelog, sizeof(g_consolelog), "%s/uml-console.log",
			 dirname(dirbuf));
		snprintf(dirbuf, sizeof(dirbuf), "%s", g_sockpath);
		dirname(dirbuf);
	}

	if (selftest) {
		snprintf(g_child_argv0, sizeof(g_child_argv0), "%s",
			 env_or("UML4TERMUXD_SELFTEST_CHILD", SELFTEST_CHILD_DEFAULT));
		logf_("selftest: supervising %s", g_child_argv0);
	} else {
		char err[256];

		if (load_guest_config(err, sizeof(err)) != 0) {
			logf_("guest config error: %s", err);
			fprintf(stderr, "uml4termuxd: %s\n", err);
			return 2;
		}
		snprintf(g_child_argv0, sizeof(g_child_argv0), "%s", g_kernel);
		logf_("guest: kernel=%s mem=%s ncpus=%s console=%s",
		      g_kernel, g_mem, g_ncpus, g_consolelog);
		if (spawn_gvproxy() != 0) {
			fprintf(stderr,
				"uml4termuxd: gvproxy failed to start (see log)\n");
			return 2;
		}
		snprintf(g_exposures, sizeof(g_exposures), "%s/exposures.jsonl",
			 dirname(g_statepath));
		reapply_exposures();
	}

	sock_path(g_sockpath, sizeof(g_sockpath));
	snprintf(g_statepath, sizeof(g_statepath), "%s.state", g_sockpath);
	{
		char dirbuf[512];
		snprintf(dirbuf, sizeof(dirbuf), "%s", g_sockpath);
		mkdir(dirname(dirbuf), 0755);
	}

	unlink(g_sockpath);
	lfd = socket(AF_UNIX, SOCK_STREAM, 0);
	if (lfd < 0) {
		logf_("socket: %s", strerror(errno));
		return 1;
	}
	memset(&addr, 0, sizeof(addr));
	addr.sun_family = AF_UNIX;
	strncpy(addr.sun_path, g_sockpath, sizeof(addr.sun_path) - 1);
	if (bind(lfd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
		logf_("bind %s: %s", g_sockpath, strerror(errno));
		close(lfd);
		return 1;
	}
	if (listen(lfd, 4) != 0) {
		logf_("listen: %s", strerror(errno));
		close(lfd);
		return 1;
	}
	chmod(g_sockpath, 0600);
	logf_("control socket: %s", g_sockpath);

	signal(SIGINT, on_sigint);
	signal(SIGTERM, on_sigterm);
	signal(SIGCHLD, on_sigchld);
	/* SIGCHLD handler uses a flag + 500 ms poll timeout (no lost wakeup);
	   SA_NOCLDSTOP keeps stop notifications from setting the flag. */
	{
		struct sigaction sa;

		memset(&sa, 0, sizeof(sa));
		sa.sa_handler = on_sigchld;
		sa.sa_flags = SA_NOCLDSTOP | SA_RESTART;
		sigaction(SIGCHLD, &sa, NULL);
	}
	umask(0077); /* socket + state files: owner-only, before bind() */

	if (spawn_child() != 0) {
		close(lfd);
		return 1;
	}
	return serve_loop(lfd);
}

static int client_line(const char *what, const char *prefix)
{
	struct sockaddr_un addr;
	int fd;
	char buf[1024];
	ssize_t n;

	sock_path(g_sockpath, sizeof(g_sockpath));
	fd = socket(AF_UNIX, SOCK_STREAM, 0);
	if (fd < 0) {
		fprintf(stderr, "socket: %s\n", strerror(errno));
		return 1;
	}
	memset(&addr, 0, sizeof(addr));
	addr.sun_family = AF_UNIX;
	strncpy(addr.sun_path, g_sockpath, sizeof(addr.sun_path) - 1);
	if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
		fprintf(stderr, "daemon not reachable at %s: %s\n", g_sockpath, strerror(errno));
		close(fd);
		return 3;
	}
	snprintf(buf, sizeof(buf), "%s%s\n", prefix, what);
	if (write(fd, buf, strlen(buf)) < 0) {
		fprintf(stderr, "write: %s\n", strerror(errno));
		close(fd);
		return 1;
	}
	n = read(fd, buf, sizeof(buf) - 1);
	if (n > 0) {
		buf[n] = '\0';
		fputs(buf, stdout);
	}
	close(fd);
	return 0;
}

static int client_main(const char *cmd)
{
	return client_line(cmd, "");
}

int main(int argc, char **argv)
{
	if (argc >= 2 && strcmp(argv[1], "daemon") == 0)
		return daemon_main(argc >= 3 && strcmp(argv[2], "--selftest") == 0);
	if (argc >= 2 && (strcmp(argv[1], "status") == 0 || strcmp(argv[1], "stop") == 0))
		return client_main(argv[1]);
	if (argc >= 2 && strcmp(argv[1], "ports") == 0)
		return client_main("ports");
	if (argc >= 4 && strcmp(argv[1], "expose") == 0) {
		char pair[128];

		snprintf(pair, sizeof(pair), "%s %s", argv[2], argv[3]);
		return client_line(pair, "expose ");
	}
	if (argc >= 3 && strcmp(argv[1], "exec") == 0) {
		/* join argv[2..] into one command line for the console agent */
		char joined[900];
		size_t used = 0;
		int i;

		joined[0] = '\0';
		for (i = 2; i < argc && used < sizeof(joined) - 2; i++) {
			size_t len = strlen(argv[i]);

			if (used)
				joined[used++] = ' ';
			memcpy(joined + used, argv[i], len);
			used += len;
			joined[used] = '\0';
		}
		return client_line(joined, "exec ");
	}
	if (argc >= 2 && strcmp(argv[1], "console") == 0) {
		char sockbuf[512];
		char logbuf[520];
		char line[1024];
		int want = argc >= 3 ? atoi(argv[2]) : 40;
		int shown = 0;
		off_t *offs = NULL, off_n = 0, off_cap = 0;
		FILE *f;

		if (want <= 0)
			want = 40;
		sock_path(sockbuf, sizeof(sockbuf));
		snprintf(logbuf, sizeof(logbuf), "%s/uml-console.log",
			 dirname(sockbuf));
		f = fopen(logbuf, "r");
		if (!f) {
			fprintf(stderr, "no console log yet: %s\n", logbuf);
			return 3;
		}
		/* index line offsets, keep the last `want` */
		{
			char offbuf[600];

			snprintf(offbuf, sizeof(offbuf), "%s", logbuf);
			(void)offbuf;
		}
		while (fgets(line, sizeof(line), f)) {
			if (off_n == off_cap) {
				off_cap = off_cap ? off_cap * 2 : 256;
				offs = realloc(offs, off_cap * sizeof(*offs));
			}
			offs[off_n++] = ftello(f);
		}
		{
			size_t start = off_n > (off_t)want ? (size_t)(off_n - (off_t)want) : 0;

			fseeko(f, offs ? offs[start] : 0, SEEK_SET);
			while (fgets(line, sizeof(line), f)) {
				fputs(line, stdout);
				shown++;
			}
		}
		free(offs);
		fclose(f);
		if (!shown)
			printf("(console log empty)\n");
		return 0;
	}
	fprintf(stderr,
		"usage: uml4termuxd daemon [--selftest]\n"
		"       uml4termuxd status|stop\n"
		"       uml4termuxd exec <command...>   run inside the guest console\n"
		"       uml4termuxd console [lines]     tail the guest console log\n"
		"       uml4termuxd expose <hport> <gport>  publish a guest port on the phone loopback\n"
		"       uml4termuxd ports               list persistent port exposures\n"
		"env:   UML4TERMUXD_COW=<path>  ephemeral boot: writes go to a UML copy-on-write\n"
		"       file (reset per boot); the backing image stays pristine\n"
		"       UML4TERMUXD_HTTP=<ip:port>  optional loopback HTTP health endpoint\n"
		"       (GET /status -> JSON: state, child_pid, exposures, mode)\n");
	return 64;
}
