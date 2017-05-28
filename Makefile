DFLAGS = -ofonedrive -L-lcurl -L-lsqlite3 -L-ldl
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

onedrive: $(SOURCES)
	dmd -g -inline -O -release $(DFLAGS) $(SOURCES)

onedrive.service:
	sed "s|@PREFIX@|$(PREFIX)|g" onedrive.service.in > onedrive.service

debug: $(SOURCES)
	dmd -debug -g -gs $(DFLAGS) $(SOURCES)

unittest: $(SOURCES)
	dmd -debug -g -gs -unittest $(DFLAGS) $(SOURCES)

clean:
	rm -f onedrive onedrive.o onedrive.service

install: all
	install -D onedrive $(DESTDIR)$(PREFIX)/bin/onedrive
	install -D -m 644 onedrive.service $(DESTDIR)/usr/lib/systemd/user

uninstall:
	rm -f $(DESTDIR)$(PREFIX)/bin/onedrive
	rm -f $(DESTDIR)/usr/lib/systemd/user/onedrive.service
