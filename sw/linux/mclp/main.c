/*
 * mclp: the MCLP console on Linux.
 *
 *   mclp [-t] [command ...]
 *
 * Without a command it runs the interactive console; with one it runs that command and exits (exit status
 * 1 when the command reports a failure). -t prints every register access (decoded, with its devmem form).
 *
 * Register access through UIO (backend.c, shared with mclpd).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <termios.h>
#include <unistd.h>

#include "backend.h"

/* ------------------------------------------------------------------ stdin */

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

/* ------------------------------------------------------------------ main */

int main(int argc, char **argv)
{
	int i = 1;

	setvbuf(stdout, NULL, _IONBF, 0);
	for (; i < argc && argv[i][0] == '-'; i++) {
		if (!strcmp(argv[i], "-t"))
			trace = 1;
		else {
			fprintf(stderr, "usage: mclp [-t] [command ...]\n");
			return 2;
		}
	}
	if (uio_open())
		return 3;
	uio_backend.getc = con_getc;
	hw = &uio_backend;
	if (i >= argc)
		con_raw();
	/* console_run sees argv[0] and the command words */
	argv[i - 1] = argv[0];
	return console_run(argc - i + 1, argv + i - 1);
}
