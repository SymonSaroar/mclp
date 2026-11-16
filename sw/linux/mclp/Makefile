# mclp (console) and mclpd (REST/MQTT service) for Linux. The PetaLinux recipe runs this with the cross
# compiler in CC/CFLAGS/LDFLAGS; mclpd needs libmicrohttpd, libmosquitto, cJSON and libcrypt.
COMMON ?= ../../common
CFLAGS ?= -O2
CFLAGS += -std=gnu11 -Wall -Wextra -I$(COMMON)
SHARED = backend.c $(COMMON)/console.c $(COMMON)/mclp_ops.c $(COMMON)/calib.c
DEPS = $(SHARED) backend.h $(wildcard $(COMMON)/*.h)

all: mclp mclpd

mclp: main.c $(DEPS)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ main.c $(SHARED) -lm -pthread

mclpd: mclpd.c $(DEPS)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ mclpd.c $(SHARED) -lmicrohttpd -lmosquitto -lcjson -lcrypt -lm -pthread

install: all
	install -d $(DESTDIR)/usr/bin
	install -m 0755 mclp mclpd $(DESTDIR)/usr/bin/

clean:
	rm -f mclp mclpd

.PHONY: all install clean
