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
	rm -f onedrive onedrive.o onedrive.service onedrive@.service

install: all
	mkdir -p $(DESTDIR)/var/log/onedrive
	chown root.users $(DESTDIR)/var/log/onedrive
	chmod 0775 $(DESTDIR)/var/log/onedrive
	install -D onedrive $(DESTDIR)$(PREFIX)/bin/onedrive
	install -D -m 644 logrotate/onedrive.logrotate $(DESTDIR)/etc/logrotate.d/onedrive
	mkdir -p $(DESTDIR)/usr/lib/systemd/user/
	chown root.root $(DESTDIR)/usr/lib/systemd/user/
	chmod 0755 $(DESTDIR)/usr/lib/systemd/user/
	cp -raf *.service $(DESTDIR)/usr/lib/systemd/user/
	chmod 0644 $(DESTDIR)/usr/lib/systemd/user/onedrive*.service
	
onedrive: version $(SOURCES)
	$(DC) $(DFLAGS) $(SOURCES)

onedrive.service:
	sed "s|@PREFIX@|$(PREFIX)|g" systemd.units/onedrive.service.in > onedrive.service
	sed "s|@PREFIX@|$(PREFIX)|g" systemd.units/onedrive@.service.in > onedrive@.service

uninstall:
	rm -f $(DESTDIR)$(PREFIX)/bin/onedrive
	rm -f $(DESTDIR)/usr/lib/systemd/user/onedrive.service
	rm -f $(DESTDIR)/usr/lib/systemd/user/onedrive@.service
	rm -f $(DESTDIR)/etc/logrotate.d/onedrive

version: .git/HEAD .git/index
	echo $(shell git describe --tags) >version
