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
#include <sys/wait.h>
#include <libgen.h>
#include <time.h>
#include <unistd.h>

#define SOCK_PATH_DEFAULT "/data/data/com.termux/files/home/.uml4termux/daemon.sock"
#define SELFTEST_CHILD "/data/data/com.termux/files/usr/bin/sleep"
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
static time_t g_started_at;
static int g_completed; /* last guest session ended cleanly (exit 0) */

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

static int spawn_child(void)
{
	pid_t pid = fork();

	if (pid < 0) {
		logf_("fork failed: %s", strerror(errno));
		return -1;
	}
	if (pid == 0) {
		if (g_kernel[0]) {
			/* real guest (A2): console -> log file, no controlling tty */
			char memopt[64], cpusopt[32], ubdopt[600], rdopt[600], stubopt[600];
			char *argv[16];
			int logfd = open(g_consolelog, O_WRONLY | O_CREAT | O_TRUNC, 0644);
			int i = 0;

			if (logfd < 0)
				_exit(126);
			snprintf(memopt, sizeof(memopt), "mem=%s", g_mem);
			snprintf(cpusopt, sizeof(cpusopt), "ncpus=%s", g_ncpus);
			snprintf(ubdopt, sizeof(ubdopt), "ubd0=%s", g_image);
			snprintf(rdopt, sizeof(rdopt), "initrd=%s", g_initrd);
			snprintf(stubopt, sizeof(stubopt), "stub_exe=%s", g_stub);
			setsid();
			dup2(logfd, 1);
			dup2(logfd, 2);
			close(logfd);
			argv[i++] = g_kernel;
			argv[i++] = memopt;
			argv[i++] = cpusopt;
			argv[i++] = "seccomp=on";
			argv[i++] = ubdopt;
			argv[i++] = "root=/dev/ubda";
			argv[i++] = "rw";
			argv[i++] = rdopt;
			argv[i++] = stubopt;
			argv[i++] = "panic=-1";
			argv[i++] = "con=null";
			argv[i++] = "con0=null,fd:1";
			argv[i] = NULL;
			execv(g_kernel, argv);
			logf_("exec %s failed: %s", g_kernel, strerror(errno));
			_exit(127);
		}
		{
			char *argv[] = { g_child_argv0, "30", NULL };
			execv(argv[0], argv);
			logf_("exec %s failed: %s", g_child_argv0, strerror(errno));
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

/* stop_child: SIGTERM, escalate to SIGKILL after timeout seconds. */
static void stop_child(int timeout_s)
{
	int waited = 0;

	if (g_child <= 0)
		return;
	kill(g_child, SIGTERM);
	while (waitpid(g_child, NULL, WNOHANG) == 0 && waited < timeout_s) {
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
	} else {
		respond(fd, "{\"error\":\"unknown command\"}\n");
	}
}

static int serve_loop(int lfd)
{
	struct pollfd pfd = { .fd = lfd, .events = POLLIN };

	while (!g_stop) {
		int rc = poll(&pfd, 1, 500);
		if (g_child_exited)
			reap_child();
		if (rc > 0 && (pfd.revents & POLLIN)) {
			int cfd = accept(lfd, NULL, NULL);
			if (cfd >= 0) {
				handle_client(cfd);
				close(cfd);
			}
		}
	}
	if (g_child > 0) {
		stop_child(5);
	}
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
		snprintf(g_child_argv0, sizeof(g_child_argv0), "%s", SELFTEST_CHILD);
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

	if (spawn_child() != 0) {
		close(lfd);
		return 1;
	}
	return serve_loop(lfd);
}

static int client_main(const char *cmd)
{
	struct sockaddr_un addr;
	int fd, rc;
	char buf[512];
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
	rc = snprintf(buf, sizeof(buf), "%s\n", cmd);
	if (write(fd, buf, (size_t)rc) < 0) {
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

int main(int argc, char **argv)
{
	if (argc >= 2 && strcmp(argv[1], "daemon") == 0)
		return daemon_main(argc >= 3 && strcmp(argv[2], "--selftest") == 0);
	if (argc >= 2 && (strcmp(argv[1], "status") == 0 || strcmp(argv[1], "stop") == 0))
		return client_main(argv[1]);
	fprintf(stderr,
		"usage: uml4termuxd daemon [--selftest]\n"
		"       uml4termuxd status|stop\n");
	return 64;
}
