DC ?= dmd
DFLAGS += -w -g -ofonedrive -O -L-lcurl -L-lsqlite3 -L-ldl -J.
PREFIX ?= /usr/local
DOCDIR ?= $(PREFIX)/share/doc/onedrive
MANDIR ?= $(PREFIX)/share/man/man1
DOCFILES = README.md README.Office365.md config LICENSE CHANGELOG.md

ifneq ("$(wildcard /etc/redhat-release)","")
RHEL = $(shell cat /etc/redhat-release | grep -E "(Red Hat Enterprise Linux Server|CentOS Linux)" | wc -l)
else
RHEL = 0
endif

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
	src/util.d \
	src/progress.d

all: onedrive onedrive.service onedrive.1

clean:
	rm -f onedrive onedrive.o onedrive.service onedrive@.service onedrive.1

onedrive: version $(SOURCES)
	$(DC) $(DFLAGS) $(SOURCES)

install.noservice: onedrive onedrive.1
	mkdir -p $(DESTDIR)/var/log/onedrive
	chown root.users $(DESTDIR)/var/log/onedrive
	chmod 0775 $(DESTDIR)/var/log/onedrive
	install -D onedrive $(DESTDIR)$(PREFIX)/bin/onedrive
	install -D onedrive.1 $(DESTDIR)$(MANDIR)/onedrive.1
	install -D -m 644 logrotate/onedrive.logrotate $(DESTDIR)/etc/logrotate.d/onedrive

install: all install.noservice
	for i in $(DOCFILES) ; do install -D -m 644 $$i $(DESTDIR)$(DOCDIR)/$$i ; done
ifeq ($(RHEL),1)
	mkdir -p $(DESTDIR)/usr/lib/systemd/system/
	chown root.root $(DESTDIR)/usr/lib/systemd/system/
	chmod 0755 $(DESTDIR)/usr/lib/systemd/system/
	install -D -m 644 *.service $(DESTDIR)/usr/lib/systemd/system/
else
	mkdir -p $(DESTDIR)/usr/lib/systemd/user/
	chown root.root $(DESTDIR)/usr/lib/systemd/user/
	chmod 0755 $(DESTDIR)/usr/lib/systemd/user/
	install -D -m 644 onedrive.service $(DESTDIR)/usr/lib/systemd/user/
	mkdir -p $(DESTDIR)/usr/lib/systemd/system/
	chown root.root $(DESTDIR)/usr/lib/systemd/system/
	chmod 0755 $(DESTDIR)/usr/lib/systemd/system/
	install -D -m 644 onedrive@.service $(DESTDIR)/usr/lib/systemd/system/
endif
	install -D -m 644 onedrive.service $(DESTDIR)/usr/lib/systemd/user/onedrive.service

onedrive.service:
	sed "s|@PREFIX@|$(PREFIX)|g" systemd.units/onedrive.service.in > onedrive.service
	sed "s|@PREFIX@|$(PREFIX)|g" systemd.units/onedrive@.service.in > onedrive@.service

onedrive.1: onedrive.1.in
	sed "s|@DOCDIR@|$(DOCDIR)|g" onedrive.1.in > onedrive.1

uninstall:
	rm -f $(DESTDIR)$(PREFIX)/bin/onedrive
	rm -f $(DESTDIR)/etc/logrotate.d/onedrive
ifeq ($(RHEL),1)
	rm -f $(DESTDIR)/usr/lib/systemd/system/onedrive*.service
else
	rm -f $(DESTDIR)/usr/lib/systemd/user/onedrive.service
	rm -f $(DESTDIR)/usr/lib/systemd/system/onedrive@.service
endif
	for i in $(DOCFILES) ; do rm -f $(DESTDIR)$(DOCDIR)/$$i ; done
	rm -f $(DESTDIR)$(MANDIR)/onedrive.1

version: .git/HEAD .git/index
	echo $(shell git describe --tags) >version
