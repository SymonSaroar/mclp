/*
 * Linux side of the backend, shared by mclp and mclpd.
 *
 * Calibration file: /etc/mclp/mclp.cal, the cal_t record as written by the console.
 * UIO: the register block and the AXI DMA are generic-uio devices, found by their bus address under
 * /sys/class/uio; the DMA device's second map is the reserved capture-ring memory.
 * Co-simulation (--sim HOST:PORT): register traffic goes over TCP to the co-simulation server, which runs
 * mclp_core in Icarus. Time is simulation time. The AXI DMA is modelled here: raw beats from the RTL fill
 * the capture ring through the same descriptor code as on the board. Builds on Linux and Windows.
 * Lock: mclp and mclpd both drive the PL. Each command runs under an exclusive flock on /run/mclp.lock;
 * the mutex orders mclpd's threads, which share one lock file.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
typedef SOCKET sock_t;
#else
#include <netdb.h>
#include <sys/socket.h>
#include <sys/stat.h>
typedef int sock_t;
#endif

#include "backend.h"

#define RING_BYTES 0x100000u
#define SIM_RING_PHYS 0x3FC00000u                 /* same as the reserved region on the board */

/* ------------------------------------------------------------------ calibration file */

const char *cal_path = "/etc/mclp/mclp.cal";

int file_store(const void *p, unsigned n)
{
#ifndef _WIN32
	static const char dir[] = "/etc/mclp/";
	if (!strncmp(cal_path, dir, sizeof dir - 1))
		mkdir("/etc/mclp", 0755);
#endif
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

/* ------------------------------------------------------------------ co-simulation */

static void no_barrier(void) {}

/* ------------------------------------------------------------------ co-simulation backend */

static sock_t sk;
static char rx[65536];
static size_t rx_len;

/* AXI DMA S2MM model: the subset mclp_ops.c uses (reset, run, cyclic descriptors) */
#define REC_MAX_WORDS (2 * (2 + MAX_CH / 2))      /* 32-bit words of the longest raw record */
static struct { uint32_t cr, cur; int running; uint32_t rec[REC_MAX_WORDS]; int words; } dma;
static uint32_t *sim_ring;

static volatile uint32_t *sim_ptr(uint32_t phys)
{
	uint32_t off = phys - SIM_RING_PHYS;
	return off < RING_BYTES ? (volatile uint32_t *)sim_ring + off / 4u : NULL;
}

static void dma_beat(uint32_t lo, uint32_t hi, int last)
{
	if (dma.words < REC_MAX_WORDS) {
		dma.rec[dma.words++] = lo;
		dma.rec[dma.words++] = hi;
	}
	if (!last)
		return;
	volatile uint32_t *d = sim_ptr(dma.cur);
	if (dma.running && d) {
		volatile uint32_t *b = sim_ptr(d[2]);
		for (int i = 0; b && i < dma.words; i++)
			b[i] = dma.rec[i];
		d[7] = BD_CMPLT | (1u << 27) | (1u << 26) | (uint32_t)(4 * dma.words);
		dma.cur = d[0];
	}
	dma.words = 0;
}

static void sim_send(const char *s)
{
	send(sk, s, (int)strlen(s), 0);
}

/* reads lines until "OK ..." and returns its value; "B lo hi last" lines feed the DMA model */
static uint64_t sim_reply(void)
{
	for (;;) {
		char *nl = memchr(rx, '\n', rx_len);
		if (nl) {
			*nl = 0;
			uint64_t v = 0;
			if (rx[0] == 'B') {
				unsigned lo, hi, last;
				if (sscanf(rx + 2, "%x %x %u", &hi, &lo, &last) == 3)
					dma_beat(lo, hi, (int)last);
			} else if (!strncmp(rx, "OK", 2)) {
				v = strtoull(rx + 2, NULL, 16);
			} else {
				fprintf(stderr, "mclp: co-simulation server: %s\n", rx);
			}
			int ok = !strncmp(rx, "OK", 2) || rx[0] == 'E';
			size_t used = (size_t)(nl - rx) + 1;
			memmove(rx, nl + 1, rx_len - used);
			rx_len -= used;
			if (ok)
				return v;
			continue;
		}
		int n = recv(sk, rx + rx_len, (int)(sizeof rx - rx_len - 1), 0);
		if (n <= 0) {
			fprintf(stderr, "mclp: co-simulation server closed the connection\n");
			exit(3);
		}
		rx_len += (size_t)n;
	}
}

static uint32_t sim_rd(uint32_t a)
{
	char q[32];
	if (a - DMA_BASE < 0x10000u) {
		uint32_t off = a - DMA_BASE;
		if (off == S2MM_DMACR)   return dma.cr;
		if (off == S2MM_DMASR)   return dma.running ? (1u << 3) : DMASR_HALTED;
		if (off == S2MM_CURDESC) return dma.cur;
		return 0;
	}
	snprintf(q, sizeof q, "R %08X\n", (unsigned)a);
	sim_send(q);
	return (uint32_t)sim_reply();
}

static void sim_wr(uint32_t a, uint32_t v)
{
	char q[40];
	if (a - DMA_BASE < 0x10000u) {
		uint32_t off = a - DMA_BASE;
		if (off == S2MM_DMACR) {
			if (v & DMACR_RESET)
				memset(&dma, 0, sizeof dma);
			else
				dma.cr = v;
			if (!(v & DMACR_RS))
				dma.running = 0;
		} else if (off == S2MM_CURDESC) {
			dma.cur = v;
		} else if (off == S2MM_TAILDESC && (dma.cr & DMACR_RS)) {
			dma.running = 1;
		}
		return;
	}
	snprintf(q, sizeof q, "W %08X %08X\n", (unsigned)a, (unsigned)v);
	sim_send(q);
	sim_reply();
}

static uint64_t sim_now_us(void)
{
	sim_send("T\n");
	return sim_reply();
}

static void sim_delay_us(uint32_t us)
{
	char q[24];
	snprintf(q, sizeof q, "D %u\n", (unsigned)us);
	sim_send(q);
	sim_reply();
}

backend_t sim_backend = {
	.name = "co-simulation", .rd = sim_rd, .wr = sim_wr, .now_us = sim_now_us, .delay_us = sim_delay_us,
	.store = file_store, .fetch = file_fetch, .store_name = "mclp-sim.cal",
	.ring_phys = SIM_RING_PHYS, .ring_bytes = RING_BYTES, .barrier = no_barrier,
};

int sim_open(const char *hostport)
{
	char host[128];
	const char *colon = strrchr(hostport, ':');
	struct addrinfo hints = {0}, *res;
#ifdef _WIN32
	WSADATA w;
	WSAStartup(MAKEWORD(2, 2), &w);
#endif
	if (!colon || (size_t)(colon - hostport) >= sizeof host) {
		fprintf(stderr, "mclp: --sim needs HOST:PORT\n");
		return -1;
	}
	memcpy(host, hostport, (size_t)(colon - hostport));
	host[colon - hostport] = 0;
	hints.ai_family = AF_INET;
	hints.ai_socktype = SOCK_STREAM;
	if (getaddrinfo(host, colon + 1, &hints, &res) != 0) {
		fprintf(stderr, "mclp: cannot resolve %s\n", host);
		return -1;
	}
	sk = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
	if (connect(sk, res->ai_addr, (int)res->ai_addrlen) != 0) {
		fprintf(stderr, "mclp: cannot connect to the co-simulation server at %s\n", hostport);
		return -1;
	}
	freeaddrinfo(res);
	sim_ring = calloc(1, RING_BYTES + 64);
	sim_backend.ring = (volatile uint32_t *)(((uintptr_t)sim_ring + 63u) & ~(uintptr_t)63u);
	sim_ring = (uint32_t *)sim_backend.ring;
	cal_path = "mclp-sim.cal";
	return 0;
}

void sim_close(void)
{
	sim_send("Q\n");
}

/* ------------------------------------------------------------------ UIO */

#ifdef __linux__
#include <fcntl.h>
#include <pthread.h>
#include <sys/file.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

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
#endif
