# mclp for Linux (the PetaLinux recipe runs this with the cross compiler in CC/CFLAGS/LDFLAGS)
COMMON ?= ../../common
CFLAGS ?= -O2
CFLAGS += -std=gnu11 -Wall -Wextra -I$(COMMON)
SRC = main.c $(COMMON)/console.c $(COMMON)/mclp_ops.c $(COMMON)/calib.c

mclp: $(SRC) $(wildcard $(COMMON)/*.h)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $(SRC) -lm

install: mclp
	install -d $(DESTDIR)/usr/bin
	install -m 0755 mclp $(DESTDIR)/usr/bin/mclp

clean:
	rm -f mclp

.PHONY: install clean
