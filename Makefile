DC = dmd
DFLAGS = -g -ofonedrive -O -L-lcurl -L-lsqlite3 -L-ldl -J.
PREFIX = /usr/local

SOURCES = \
	src/config.d \
	src/itemdb.d \
	src/log.d \
	src/main.d \
	src/monitor.d \
	src/onedrive.d \
	src/qxor.d \
	src/selective.d \
	src/sqlite.d \
	src/sync.d \
	src/upload.d \
	src/util.d

all: onedrive onedrive.service

clean:
	rm -f onedrive onedrive.o onedrive.service

onedrive: version $(SOURCES)
	$(DC) $(DFLAGS) $(SOURCES)

install.noservice: onedrive
	install -D onedrive $(DESTDIR)$(PREFIX)/bin/onedrive

install: all install.noservice
	install -D -m 644 onedrive.service $(DESTDIR)/usr/lib/systemd/user/onedrive.service

onedrive.service:
	sed "s|@PREFIX@|$(PREFIX)|g" onedrive.service.in > onedrive.service

uninstall:
	rm -f $(DESTDIR)$(PREFIX)/bin/onedrive
	rm -f $(DESTDIR)/usr/lib/systemd/user/onedrive.service

version: .git/HEAD .git/index
	echo $(shell git describe --tags) >version
