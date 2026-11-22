/* Linux side of the backend, shared by mclp and mclpd: calibration file and the UIO register access */
#ifndef BACKEND_H
#define BACKEND_H

#include "mclp_ops.h"

extern const char *cal_path;                  /* /etc/mclp/mclp.cal */
int file_store(const void *p, unsigned n);
int file_fetch(void *p, unsigned n);
int file_read(const char *path, char *buf, unsigned max);

extern backend_t sim_backend;                 /* co-simulation server; getc is left to the program */
int  sim_open(const char *hostport);          /* 0, or -1 with a message on stderr */
void sim_close(void);

#ifdef __linux__
extern backend_t uio_backend;                 /* getc is left to the program */
int  uio_open(void);                          /* 0, or -1 with a message on stderr */
void uio_lock(void);                          /* /run/mclp.lock, plus a mutex for threads */
void uio_unlock(void);
#endif

#endif
