// SPDX-License-Identifier: GPL-2.0
/*
 * Host side controller for the RISC-V KVM stale VS-stage TLB reproducer.
 *
 * Runs on the machine-under-test (the KVM host). It starts QEMU with KVM,
 * pins both vCPU threads to one host CPU, then after the guest populated a
 * VS-stage TLB entry it moves vCPU0 to a second host CPU. vCPU1 stays where
 * it is, so the guest task later re-reads the same page on a host CPU that
 * never saw the guest-local sfence.vma.
 *
 * Exit codes:
 *   0 = stale value read  -> BUG REPRODUCED
 *   1 = new value read    -> not reproduced
 *   2 = harness error
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <sched.h>
#include <signal.h>
#include <dirent.h>
#include <stdarg.h>
#include <sys/wait.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>

#ifndef CPU_SETSIZE
#define CPU_SETSIZE 1024
#endif

static pid_t qemu_pid = -1;
static int qemu_in = -1;	/* write to guest console */
static FILE *qemu_out;		/* read guest console */
static const char *qmp_path = "/tmp/vstlb-qmp.sock";

static void die(const char *fmt, ...)
{
	va_list ap;

	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
	fputc('\n', stderr);
	if (qemu_pid > 0) {
		kill(qemu_pid, SIGKILL);
		waitpid(qemu_pid, NULL, 0);
	}
	exit(2);
}

static int set_affinity(int tid, int cpu)
{
	cpu_set_t set;

	CPU_ZERO(&set);
	CPU_SET(cpu, &set);
	if (sched_setaffinity(tid, sizeof(set), &set)) {
		printf("[host] sched_setaffinity(%d,%d): %s\n", tid, cpu,
		       strerror(errno));
		return -1;
	}
	return 0;
}

static int get_affinity(int tid)
{
	cpu_set_t set;
	int i;

	CPU_ZERO(&set);
	if (sched_getaffinity(tid, sizeof(set), &set)) {
		printf("[host] sched_getaffinity(%d): %s\n", tid,
		       strerror(errno));
		return -1;
	}
	for (i = 0; i < CPU_SETSIZE; i++)
		if (CPU_ISSET(i, &set))
			return i;
	return -1;
}

/* find "CPU <n>/KVM" threads under /proc/<pid>/task */
static int find_vcpu_tid(pid_t pid, int idx)
{
	char want[32];
	int tries;

	snprintf(want, sizeof(want), "CPU %d/KVM", idx);
	for (tries = 0; tries < 200; tries++) {
		DIR *d;
		struct dirent *de;
		char path[256], comm[64];
		FILE *f;
		pid_t tid;

		snprintf(path, sizeof(path), "/proc/%d/task", (int)pid);
		d = opendir(path);
		if (d) {
			while ((de = readdir(d))) {
				if (de->d_name[0] == '.')
					continue;
				tid = atoi(de->d_name);
				if (tid <= 0)
					continue;
				snprintf(path, sizeof(path),
					 "/proc/%d/task/%d/comm", (int)pid, (int)tid);
				f = fopen(path, "r");
				if (!f)
					continue;
				memset(comm, 0, sizeof(comm));
				if (fgets(comm, sizeof(comm), f)) {
					comm[strcspn(comm, "\n")] = '\0';
					if (!strcmp(comm, want)) {
						fclose(f);
						closedir(d);
						return tid;
					}
				}
				fclose(f);
			}
			closedir(d);
		}
		usleep(50000);
	}
	return -1;
}

/* ---------------- QMP: authoritative vCPU -> host TID mapping ---------------- */

static int qmp_fd = -1;
static int qmp_read(char *buf, size_t len, int timeout_ms);

static int qmp_connect(void)
{
	struct sockaddr_un sa;
	int fd, i;

	for (i = 0; i < 200; i++) {
		fd = socket(AF_UNIX, SOCK_STREAM, 0);
		if (fd < 0)
			return -1;
		memset(&sa, 0, sizeof(sa));
		sa.sun_family = AF_UNIX;
		snprintf(sa.sun_path, sizeof(sa.sun_path), "%s", qmp_path);
		if (!connect(fd, (struct sockaddr *)&sa, sizeof(sa))) {
			char greet[1024];

			qmp_fd = fd;
			/* consume the QMP greeting line */
			if (qmp_read(greet, sizeof(greet), 3000) != 1) {
				close(fd);
				qmp_fd = -1;
				return -1;
			}
			return fd;
		}
		close(fd);
		usleep(50000);
	}
	return -1;
}

static int qmp_send(const char *json)
{
	char buf[512];
	int len;

	snprintf(buf, sizeof(buf), "%s\n", json);
	len = (int)strlen(buf);
	return write(qmp_fd, buf, len) == len ? 0 : -1;
}

static int qmp_read(char *buf, size_t len, int timeout_ms)
{
	size_t n = 0;
	struct pollfd pfd = { .fd = qmp_fd, .events = POLLIN };

	while (n + 1 < len) {
		char c;
		int r = poll(&pfd, 1, timeout_ms);

		if (r == 0)
			return 0;
		if (r < 0) {
			if (errno == EINTR)
				continue;
			return -1;
		}
		if (read(qmp_fd, &c, 1) != 1)
			return -1;
		if (c == '\n')
			break;
		buf[n++] = c;
	}
	buf[n] = '\0';
	return 1;
}

/*
 * query-cpus-fast -> {"return":[{"cpu-index":0,...,"thread-id":123},...]}
 * crude scan: for each "cpu-index" take the first "thread-id" that follows.
 */
static int qmp_vcpu_tids(int *tids, int max)
{
	char buf[16384];
	const char *p;
	int n = 0;

	if (qmp_send("{\"execute\":\"qmp_capabilities\"}"))
		return -1;
	if (qmp_read(buf, sizeof(buf), 5000) != 1)
		return -1;
	if (qmp_send("{\"execute\":\"query-cpus-fast\"}"))
		return -1;
	if (qmp_read(buf, sizeof(buf), 5000) != 1)
		return -1;
	printf("[host] QMP: %.400s\n", buf);

	p = buf;
	while ((p = strstr(p, "{\"thread-id\"")) != NULL && n < max) {
		const char *c, *ci;
		int idx, tid;

		c = strchr(p, ':');
		if (!c)
			break;
		tid = atoi(c + 1);
		ci = strstr(p, "\"cpu-index\"");
		if (!ci)
			break;
		c = strchr(ci, ':');
		if (!c)
			break;
		idx = atoi(c + 1);
		if (idx >= 0 && idx < max) {
			tids[idx] = tid;
			if (idx + 1 > n)
				n = idx + 1;
		}
		p = ci + 1;
	}
	return n;
}

/* read one line with a timeout; returns 1 on line, 0 on timeout, -1 on EOF */
static int read_line(char *buf, size_t len, int timeout_ms)
{
	size_t n = 0;
	struct pollfd pfd = { .fd = fileno(qemu_out), .events = POLLIN };

	while (n + 1 < len) {
		char c;
		int r = poll(&pfd, 1, timeout_ms);

		if (r == 0)
			return 0;
		if (r < 0) {
			if (errno == EINTR)
				continue;
			return -1;
		}
		if (read(fileno(qemu_out), &c, 1) != 1)
			return -1;
		if (c == '\r')
			continue;
		if (c == '\n')
			break;
		buf[n++] = c;
	}
	buf[n] = '\0';
	return 1;
}

/* wait for a line matching exactly; echoes every line read */
static int wait_for(const char *expect, int timeout_ms)
{
	char line[512];
	int waited = 0;

	while (waited < timeout_ms) {
		int r = read_line(line, sizeof(line), 1000);

		if (r < 0) {
			printf("[host] qemu console closed while waiting %s\n", expect);
			return -1;
		}
		if (r == 0) {
			waited += 1000;
			continue;
		}
		printf("[qemu] %s\n", line);
		if (!strcmp(line, expect))
			return 0;
	}
	printf("[host] TIMEOUT waiting for %s\n", expect);
	return -1;
}

static void send_cmd(const char *cmd)
{
	char buf[64];
	int len;

	snprintf(buf, sizeof(buf), "%s\n", cmd);
	len = (int)strlen(buf);
	printf("[host] -> %s", buf);
	if (write(qemu_in, buf, len) != len)
		printf("[host] WARN short write\n");
}

int main(int argc, char **argv)
{
	const char *qemu = "/usr/bin/qemu-system-riscv64";
	const char *kernel = "/opt/vstlb/Image";
	const char *initrd = "/opt/vstlb/guest.cpio.gz";
	const char *accel = "kvm";
	int cpu0 = 0, cpu1 = 1, settle_ms = 500;
	int in_pipe[2], out_pipe[2];
	int tid0, tid1, i, a0, a1;
	char line[512];
	int got = 0;

	for (i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--qemu") && i + 1 < argc)
			qemu = argv[++i];
		else if (!strcmp(argv[i], "--kernel") && i + 1 < argc)
			kernel = argv[++i];
		else if (!strcmp(argv[i], "--initrd") && i + 1 < argc)
			initrd = argv[++i];
		else if (!strcmp(argv[i], "--cpu0") && i + 1 < argc)
			cpu0 = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--cpu1") && i + 1 < argc)
			cpu1 = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--settle-ms") && i + 1 < argc)
			settle_ms = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--accel") && i + 1 < argc)
			accel = argv[++i];
		else if (!strcmp(argv[i], "--help")) {
			printf("usage: %s [--qemu PATH] [--kernel IMG] "
			       "[--initrd CPIO] [--cpu0 N] [--cpu1 N]\n", argv[0]);
			return 2;
		} else
			die("unknown argument: %s", argv[i]);
	}
	if (cpu0 == cpu1)
		die("--cpu0 and --cpu1 must differ");
	if (strcmp(accel, "kvm"))
		printf("[host] WARNING: accel=%s (this run does not exercise host KVM)\n",
		       accel);

	if (pipe(in_pipe) || pipe(out_pipe))
		die("pipe: %s", strerror(errno));

	qemu_pid = fork();
	if (qemu_pid < 0)
		die("fork: %s", strerror(errno));
	if (qemu_pid == 0) {
		dup2(in_pipe[0], 0);
		dup2(out_pipe[1], 1);
		dup2(out_pipe[1], 2);
		close(in_pipe[0]); close(in_pipe[1]);
		close(out_pipe[0]); close(out_pipe[1]);
		execl(qemu, qemu,
		      "-machine", "virt,aia=none",
		      "-accel", accel,
		      "-cpu", strcmp(accel, "kvm") ? "rv64" : "host",
		      "-smp", "2",
		      "-m", "512",
		      "-nodefaults",
		      "-display", "none",
		      "-serial", "stdio",
		      "-monitor", "none",
		      "-qmp", "unix:/tmp/vstlb-qmp.sock,server=on,wait=off",
		      "-no-reboot",
		      "-kernel", kernel,
		      "-initrd", initrd,
		      "-append", "console=ttyS0,115200 loglevel=5",
		      (char *)NULL);
		_exit(127);
	}
	close(in_pipe[0]);
	close(out_pipe[1]);
	qemu_in = in_pipe[1];
	qemu_out = fdopen(out_pipe[0], "r");
	if (!qemu_out)
		die("fdopen: %s", strerror(errno));

	printf("[host] qemu pid %d, host CPUs: vCPU0 -> %d, vCPU1 stays on %d\n",
	       (int)qemu_pid, cpu0, cpu1);

	if (wait_for("GUEST_READY", 90000))
		die("guest never became ready");

	tid0 = tid1 = -1;
	qmp_fd = qmp_connect();
	if (qmp_fd >= 0) {
		int tids[8] = { -1, -1, -1, -1, -1, -1, -1, -1 };

		if (qmp_vcpu_tids(tids, 8) >= 2) {
			tid0 = tids[0];
			tid1 = tids[1];
		}
	}
	if (tid0 < 0 || tid1 < 0) {
		/* fallback: QEMU may not set thread names in this build */
		tid0 = find_vcpu_tid(qemu_pid, 0);
		tid1 = find_vcpu_tid(qemu_pid, 1);
	}
	if (tid0 < 0 || tid1 < 0)
		die("vCPU threads not found (tid0=%d tid1=%d)", tid0, tid1);
	printf("[host] vCPU tids: 0=%d 1=%d\n", tid0, tid1);

	if (set_affinity(tid0, cpu1) || set_affinity(tid1, cpu1))
		die("set_affinity both->%d: %s", cpu1, strerror(errno));
	usleep(200000);
	a0 = get_affinity(tid0);
	a1 = get_affinity(tid1);
	printf("[host] initial pinning: vCPU0=%d vCPU1=%d (want both %d)\n",
	       a0, a1, cpu1);
	if (a0 != cpu1 || a1 != cpu1)
		die("pinning failed");

	send_cmd("GO_PHASE1");
	if (wait_for("PHASE1_DONE", 30000))
		die("phase1 timeout");

	printf("[host] migrating vCPU0: cpu%d -> cpu%d\n", cpu1, cpu0);
	if (set_affinity(tid0, cpu0))
		die("migrate vCPU0: %s", strerror(errno));
	usleep(settle_ms * 1000);
	a0 = get_affinity(tid0);
	printf("[host] vCPU0 now on cpu%d\n", a0);
	if (a0 != cpu0)
		die("vCPU0 migration failed");

	send_cmd("MIGRATED0");
	if (wait_for("PHASE2_DONE", 30000))
		die("phase2 timeout");

	a1 = get_affinity(tid1);
	printf("[host] vCPU1 still on cpu%d (must equal %d)\n", a1, cpu1);
	if (a1 != cpu1)
		die("vCPU1 moved, test invalid");

	send_cmd("MIGRATED1");

	while (read_line(line, sizeof(line), 30000) == 1) {
		printf("[qemu] %s\n", line);
		if (!strncmp(line, "RESULT:", 7)) {
			got = 1;
			break;
		}
	}
	if (!got)
		die("no RESULT line from guest");

	kill(qemu_pid, SIGKILL);
	waitpid(qemu_pid, NULL, 0);

	if (!strcmp(line, "RESULT:0xcafebabe")) {
		printf("[host] VERDICT: OK (guest read the new value)\n");
		return 1;
	}
	if (!strcmp(line, "RESULT:0x0")) {
		printf("[host] VERDICT: BUG_REPRODUCED (guest read the stale value)\n");
		return 0;
	}
	printf("[host] VERDICT: UNEXPECTED (%s)\n", line);
	return 2;
}
