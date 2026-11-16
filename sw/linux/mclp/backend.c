/*
 * Linux side of the backend, shared by mclp and mclpd.
 *
 * Calibration file: /etc/mclp/mclp.cal, the cal_t record as written by the console.
 * UIO: the register block and the AXI DMA are generic-uio devices, found by their bus address under
 * /sys/class/uio; the DMA device's second map is the reserved capture-ring memory.
 * Lock: mclp and mclpd both drive the PL. Each command runs under an exclusive flock on /run/mclp.lock;
 * the mutex orders mclpd's threads, which share one lock file.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <fcntl.h>
#include <pthread.h>
#include <sys/file.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include "backend.h"

#define RING_BYTES 0x100000u

/* ------------------------------------------------------------------ calibration file */

const char *cal_path = "/etc/mclp/mclp.cal";

int file_store(const void *p, unsigned n)
{
	static const char dir[] = "/etc/mclp/";
	if (!strncmp(cal_path, dir, sizeof dir - 1))
		mkdir("/etc/mclp", 0755);
	FILE *f = fopen(cal_path, "wb");
	if (!f)
		return -1;
	size_t w = fwrite(p, 1, n, f);
	return fclose(f) == 0 && w == n ? 0 : -2;
}

int file_fetch(void *p, unsigned n)
{
	FILE *f = fopen(cal_path, "rb");
	if (!f)
		return -1;
	size_t r = fread(p, 1, n, f);
	fclose(f);
	return r == n ? 0 : -2;
}

/* ------------------------------------------------------------------ UIO */

static volatile uint32_t *uio_regs, *uio_dma;

static uint32_t sysfs_hex(const char *path)
{
	char buf[32] = {0};
	FILE *f = fopen(path, "r");
	if (!f)
		return 0;
	if (!fgets(buf, sizeof buf, f))
		buf[0] = 0;
	fclose(f);
	return (uint32_t)strtoul(buf, NULL, 0);
}

/* /dev/uioN whose first map starts at `addr`; maps map `map` of it */
static volatile uint32_t *uio_map(uint32_t addr, int map, uint32_t *phys, uint32_t *size)
{
	char path[96];
	for (int n = 0; n < 16; n++) {
		snprintf(path, sizeof path, "/sys/class/uio/uio%d/maps/map0/addr", n);
		if (sysfs_hex(path) != addr)
			continue;
		snprintf(path, sizeof path, "/sys/class/uio/uio%d/maps/map%d/addr", n, map);
		*phys = sysfs_hex(path);
		snprintf(path, sizeof path, "/sys/class/uio/uio%d/maps/map%d/size", n, map);
		*size = sysfs_hex(path);
		snprintf(path, sizeof path, "/dev/uio%d", n);
		int fd = open(path, O_RDWR | O_SYNC | O_CLOEXEC);
		if (fd < 0) {
			perror(path);                     /* EACCES: /dev/uio* belongs to root, run with sudo */
			return NULL;
		}
		if (!*size)
			return NULL;
		void *p = mmap(NULL, *size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, (off_t)map * getpagesize());
		return p == MAP_FAILED ? NULL : (volatile uint32_t *)p;
	}
	return NULL;
}

static uint32_t uio_rd(uint32_t a)
{
	if (a - MCLP_BASE < 0x10000u) return uio_regs[(a - MCLP_BASE) / 4u];
	if (a - DMA_BASE < 0x10000u)   return uio_dma[(a - DMA_BASE) / 4u];
	fprintf(stderr, "mclp: %08X is outside the mapped register windows\n", (unsigned)a);
	return 0xFFFFFFFFu;
}

static void uio_wr(uint32_t a, uint32_t v)
{
	if (a - MCLP_BASE < 0x10000u)    uio_regs[(a - MCLP_BASE) / 4u] = v;
	else if (a - DMA_BASE < 0x10000u) uio_dma[(a - DMA_BASE) / 4u] = v;
	else fprintf(stderr, "mclp: %08X is outside the mapped register windows\n", (unsigned)a);
}

static uint64_t uio_now_us(void)
{
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return (uint64_t)t.tv_sec * 1000000u + (uint64_t)t.tv_nsec / 1000u;
}

static void uio_delay_us(uint32_t us) { usleep(us); }
static void uio_barrier(void)         { __sync_synchronize(); }

static pthread_mutex_t lock_mx = PTHREAD_MUTEX_INITIALIZER;
static int lock_fd = -1;

void uio_lock(void)
{
	pthread_mutex_lock(&lock_mx);
	if (lock_fd < 0)
		lock_fd = open("/run/mclp.lock", O_RDWR | O_CREAT | O_CLOEXEC, 0600);
	if (lock_fd >= 0)
		flock(lock_fd, LOCK_EX);
}

void uio_unlock(void)
{
	if (lock_fd >= 0)
		flock(lock_fd, LOCK_UN);
	pthread_mutex_unlock(&lock_mx);
}

backend_t uio_backend = {
	.name = "Linux UIO", .rd = uio_rd, .wr = uio_wr, .now_us = uio_now_us, .delay_us = uio_delay_us,
	.store = file_store, .fetch = file_fetch, .store_name = "/etc/mclp/mclp.cal", .barrier = uio_barrier,
	.lock = uio_lock, .unlock = uio_unlock,
};

int uio_open(void)
{
	uint32_t phys, size, rphys, rsize;
	uio_regs = uio_map(MCLP_BASE, 0, &phys, &size);
	uio_dma  = uio_map(DMA_BASE, 0, &phys, &size);
	uio_backend.ring = uio_map(DMA_BASE, 1, &rphys, &rsize);
	if (!uio_regs || !uio_dma || !uio_backend.ring) {
		fprintf(stderr, "mclp: UIO devices for 0x%08X and 0x%08X (with the ring as map 1) not found.\n"
		        "Load the driver: modprobe uio_pdrv_genirq of_id=generic-uio\n", MCLP_BASE, DMA_BASE);
		return -1;
	}
	uio_backend.ring_phys  = rphys;
	uio_backend.ring_bytes = rsize < RING_BYTES ? rsize : RING_BYTES;
	return 0;
}
