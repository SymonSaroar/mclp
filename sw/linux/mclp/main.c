/*
 * mclp: the MCLP console on Linux.
 *
 *   mclp [-t] [--sim HOST:PORT] [command ...]
 *
 * Without a command it runs the interactive console; with one it runs that command and exits (exit status
 * 1 when the command reports a failure). -t prints every register access (decoded, with its devmem form).
 *
 * Backends:
 *   UIO (default, the board): backend.c, shared with mclpd.
 *   --sim HOST:PORT: the co-simulation server (backend.c). Builds on Linux and Windows.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <conio.h>
#include <windows.h>
#else
#include <termios.h>
#include <unistd.h>
#endif

#include "backend.h"

/* ------------------------------------------------------------------ stdin */

#ifdef _WIN32
static int con_getc(void)
{
	if (!_kbhit()) {
		Sleep(10);
		return -1;
	}
	int c = _getch();
	return c == '\r' ? '\n' : c;
}
#else
static struct termios saved;
static int raw_on;

static void con_restore(void)
{
	if (raw_on)
		tcsetattr(0, TCSANOW, &saved);
}

static void con_raw(void)
{
	struct termios t;
	if (!isatty(0) || tcgetattr(0, &saved))
		return;
	t = saved;
	t.c_lflag &= ~(ICANON | ECHO);
	t.c_cc[VMIN] = 0;
	t.c_cc[VTIME] = 0;
	tcsetattr(0, TCSANOW, &t);
	raw_on = 1;
	atexit(con_restore);
}

static int con_getc(void)
{
	unsigned char c;
	if (read(0, &c, 1) == 1)
		return c;
	usleep(10000);
	return -1;
}
#endif

/* ------------------------------------------------------------------ main */

int main(int argc, char **argv)
{
	const char *sim = NULL;
	int i = 1;

	setvbuf(stdout, NULL, _IONBF, 0);
	for (; i < argc && argv[i][0] == '-'; i++) {
		if (!strcmp(argv[i], "-t"))
			trace = 1;
		else if (!strcmp(argv[i], "--sim") && i + 1 < argc)
			sim = argv[++i];
		else {
			fprintf(stderr, "usage: mclp [-t] [--sim HOST:PORT] [command ...]\n");
			return 2;
		}
	}
	if (sim) {
		if (sim_open(sim))
			return 3;
		sim_backend.getc = con_getc;
		hw = &sim_backend;
	} else {
#ifdef __linux__
		if (uio_open())
			return 3;
		uio_backend.getc = con_getc;
		hw = &uio_backend;
#else
		fprintf(stderr, "mclp: this build has only the co-simulation backend (--sim HOST:PORT)\n");
		return 2;
#endif
	}
#ifndef _WIN32
	if (i >= argc)
		con_raw();
#endif
	/* console_run sees argv[0] and the command words */
	argv[i - 1] = argv[0];
	int rc = console_run(argc - i + 1, argv + i - 1);
	if (sim)
		sim_close();
	return rc;
}
