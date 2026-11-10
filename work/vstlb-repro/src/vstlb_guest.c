// SPDX-License-Identifier: GPL-2.0
/*
 * Guest side of the RISC-V KVM stale VS-stage TLB reproducer.
 *
 * Reproduces:
 *   vcpu0 runs on host CPU1 and caches a VS-stage translation for the page.
 *   vcpu0 migrates to host CPU0; the task then does a COW on that page,
 *   which only issues a guest-local sfence.vma.
 *   The task is then scheduled on vcpu1, which still runs on host CPU1 and
 *   therefore still holds the stale VS-stage entry -> reads the old value.
 *
 * Sync protocol (line based, over the guest console):
 *   host -> guest : GO_PHASE1 / MIGRATED0 / MIGRATED1
 *   guest -> host : GUEST_READY / PHASE1_DONE / PHASE2_DONE / RESULT:0x...
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sched.h>
#include <errno.h>
#include <stdint.h>
#include <sys/mman.h>

#define PAGE_SZ		4096UL
#define INITIAL_VAL	0x0UL
#define WRITE_VAL	0xCAFEBABEUL

static volatile unsigned long *shared_page;

static int read_line(char *buf, size_t buflen)
{
	size_t n = 0;

	while (n + 1 < buflen) {
		char c;
		if (read(0, &c, 1) != 1)
			return -1;
		if (c == '\n')
			break;
		buf[n++] = c;
	}
	buf[n] = '\0';
	return (int)n;
}

static int pin_guest_cpu(int cpu)
{
	cpu_set_t set;

	CPU_ZERO(&set);
	CPU_SET(cpu, &set);
	if (sched_setaffinity(0, sizeof(set), &set)) {
		perror("sched_setaffinity");
		return -1;
	}
	/* give the scheduler time to actually place us on the target vCPU */
	usleep(300000);
	printf("GUEST_ON_CPU %d\n", sched_getcpu());
	return 0;
}

static int wait_for(const char *what, const char *expect)
{
	char buf[128];

	printf("GUEST_WAIT_FOR %s\n", expect);
	for (;;) {
		memset(buf, 0, sizeof(buf));
		if (read_line(buf, sizeof(buf)) < 0) {
			printf("GUEST_EOF while waiting for %s\n", expect);
			return -1;
		}
		if (!strcmp(buf, expect))
			return 0;
		printf("GUEST_IGNORED_INPUT '%s' (waiting %s)\n", buf, expect);
	}
}

int main(void)
{
	unsigned long val;
	long ncpus;
	char *argv[3];

	setvbuf(stdout, NULL, _IOLBF, 0);

	/*
	 * Pin to vCPU0 before touching anything, then re-exec once.  exec()
	 * gives us a brand new mm, so mm_cpumask() starts empty and only ever
	 * contains vCPU0 from here on.  Without this the task can be scheduled
	 * on vCPU1 during startup, which puts vCPU1 into mm_cpumask() and makes
	 * the guest kernel send it a remote sfence.vma -- that hides the bug.
	 */
	if (pin_guest_cpu(0))
		return 1;
	if (!getenv("VSTLB_REEXEC")) {
		setenv("VSTLB_REEXEC", "1", 1);
		argv[0] = "/vstlb_guest";
		argv[1] = NULL;
		execv(argv[0], argv);
		perror("execv");
	}

	ncpus = sysconf(_SC_NPROCESSORS_ONLN);
	printf("GUEST_PROG_START ncpu=%ld\n", ncpus);
	if (ncpus < 2) {
		printf("GUEST_FAIL need 2 guest CPUs\n");
		return 1;
	}

	shared_page = mmap(NULL, PAGE_SZ, PROT_READ | PROT_WRITE,
			   MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (shared_page == MAP_FAILED) {
		perror("mmap");
		return 1;
	}
	printf("GUEST_PAGE %p\n", (void *)shared_page);
	printf("GUEST_READY\n");

	if (wait_for("phase1", "GO_PHASE1"))
		return 1;

	/* Phase 1: read the page on vCPU0 (host CPU1) -> VS-stage TLB entry */
	printf("PHASE1_BEGIN\n");
	if (pin_guest_cpu(0))
		return 1;
	val = shared_page[0];
	printf("PHASE1_READ 0x%lx\n", val);
	printf("PHASE1_DONE\n");

	if (wait_for("migrated0", "MIGRATED0"))
		return 1;

	/* Phase 2: write on vCPU0 (now host CPU0) -> COW + local sfence.vma */
	printf("PHASE2_BEGIN\n");
	shared_page[0] = WRITE_VAL;
	val = shared_page[0];
	printf("PHASE2_READBACK 0x%lx\n", val);
	printf("PHASE2_DONE\n");

	if (wait_for("migrated1", "MIGRATED1"))
		return 1;

	/* Phase 3: migrate the task to vCPU1 (still host CPU1) and re-read */
	printf("PHASE3_BEGIN\n");
	if (pin_guest_cpu(1))
		return 1;
	val = shared_page[0];
	printf("PHASE3_READ 0x%lx\n", val);

	printf("RESULT:0x%lx\n", val);
	if (val == WRITE_VAL)
		printf("GUEST_VERDICT OK\n");
	else if (val == INITIAL_VAL)
		printf("GUEST_VERDICT STALE\n");
	else
		printf("GUEST_VERDICT UNEXPECTED\n");
	/* never exit: PID 1 exiting panics the guest and eats the last line */
	for (;;)
		pause();
}
