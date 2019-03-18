DC ?= dmd
RELEASEVER = v2.2.6
pkgconfig := $(shell if [ $(PKGCONFIG) ] && [ "$(PKGCONFIG)" != 0 ] ; then echo 1 ; else echo "" ; fi)
notifications := $(shell if [ $(NOTIFICATIONS) ] && [ "$(NOTIFICATIONS)" != 0 ] ; then echo 1 ; else echo "" ; fi)
gitversion := $(shell if [ -f .git/HEAD ] ; then echo 1 ; else echo "" ; fi)

ifeq ($(pkgconfig),1)
LIBS = $(shell pkg-config --libs sqlite3 libcurl)
else
LIBS = -lcurl -lsqlite3
endif
ifeq ($(notifications),1)
NOTIF_VERSIONS = -version=NoPragma -version=NoGdk -version=Notifications
ifeq ($(pkgconfig),1)
LIBS += $(shell pkg-config --libs libnotify)
else
LIBS += -lgmodule-2.0 -lglib-2.0 -lnotify
endif
endif
LIBS += -ldl

# add the necessary prefix for the D compiler
LIBS := $(addprefix -L,$(LIBS))

# support ldc2 which needs -d prefix for version specification
ifeq ($(notdir $(DC)),ldc2)
	NOTIF_VERSIONS := $(addprefix -d,$(NOTIF_VERSIONS))
endif

DFLAGS += -w -g -ofonedrive -O $(NOTIF_VERSIONS) $(LIBS) -J.

PREFIX ?= /usr/local
DOCDIR ?= $(PREFIX)/share/doc/onedrive
MANDIR ?= $(PREFIX)/share/man/man1
DOCFILES = README.md README.Office365.md config LICENSE CHANGELOG.md

ifneq ("$(wildcard /etc/redhat-release)","")
RHEL = $(shell cat /etc/redhat-release | grep -E "(Red Hat Enterprise Linux Server|CentOS)" | wc -l)
RHEL_VERSION = $(shell rpm --eval "%{centos_ver}")
else
RHEL = 0
RHEL_VERSION = 0
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

ifeq ($(notifications),1)
SOURCES += src/notifications/notify.d src/notifications/dnotify.d
endif

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
ifeq ($(RHEL_VERSION),6)
	mkdir -p $(DESTDIR)/etc/init.d/
	chown root.root $(DESTDIR)/etc/init.d/
	install -D init.d/onedrive.init $(DESTDIR)/etc/init.d/onedrive
	install -D init.d/onedrive_service.sh $(DESTDIR)$(PREFIX)/bin/onedrive_service.sh
else
	mkdir -p $(DESTDIR)/usr/lib/systemd/system/
	chown root.root $(DESTDIR)/usr/lib/systemd/system/
	chmod 0755 $(DESTDIR)/usr/lib/systemd/system/
	install -D -m 644 *.service $(DESTDIR)/usr/lib/systemd/system/
endif
else
	mkdir -p $(DESTDIR)/usr/lib/systemd/user/
	chown root.root $(DESTDIR)/usr/lib/systemd/user/
	chmod 0755 $(DESTDIR)/usr/lib/systemd/user/
	install -D -m 644 onedrive.service $(DESTDIR)/usr/lib/systemd/user/
	mkdir -p $(DESTDIR)/usr/lib/systemd/system/
	chown root.root $(DESTDIR)/usr/lib/systemd/system/
	chmod 0755 $(DESTDIR)/usr/lib/systemd/system/
	install -D -m 644 onedrive@.service $(DESTDIR)/usr/lib/systemd/system/
	install -D -m 644 onedrive.service $(DESTDIR)/usr/lib/systemd/user/onedrive.service
endif

onedrive.service:
	sed "s|@PREFIX@|$(PREFIX)|g" systemd.units/onedrive.service.in > onedrive.service
	sed "s|@PREFIX@|$(PREFIX)|g" systemd.units/onedrive@.service.in > onedrive@.service

onedrive.1: onedrive.1.in
	sed "s|@DOCDIR@|$(DOCDIR)|g" onedrive.1.in > onedrive.1

uninstall:
	rm -f $(DESTDIR)$(PREFIX)/bin/onedrive
	rm -f $(DESTDIR)/etc/logrotate.d/onedrive
ifeq ($(RHEL),1)
ifeq ($(RHEL_VERSION),6)
	rm -f $(DESTDIR)/etc/init.d/onedrive
	rm -f $(DESTDIR)$(PREFIX)/bin/onedrive_service.sh
else
	rm -f $(DESTDIR)/usr/lib/systemd/system/onedrive*.service
endif
else
	rm -f $(DESTDIR)/usr/lib/systemd/user/onedrive.service
	rm -f $(DESTDIR)/usr/lib/systemd/system/onedrive@.service
endif
	for i in $(DOCFILES) ; do rm -f $(DESTDIR)$(DOCDIR)/$$i ; done
	rm -f $(DESTDIR)$(MANDIR)/onedrive.1

version:
ifeq ($(gitversion),1)
	echo $(shell git describe --tags) > version
else
	echo $(RELEASEVER) > version
endif