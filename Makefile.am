
bin_PROGRAMS = onedrive
onedrive_SOURCES =   src/config.d \
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

DCFLAGS += -J.
if NOTIFICATIONS
onedrive_SOURCES += src/notifications/notify.d src/notifications/dnotify.d
DCFLAGS += -version=NoPragma -version=NoGdk -version=Notifications
endif


onedrive.o: $(onedrive_SOURCES) version
	$(DC) $(DCFLAGS) -c $(onedrive_SOURCES) -of$@

onedrive$(EXEEXT): onedrive.o
	$(DC) $(DCFLAGS) $(addprefix -L,$(CURL_LIBS)) $(addprefix -L,$(SQLITE_LIBS)) $(addprefix -L,$(NOTIFY_LIBS)) -L-ldl $^ -of$@


docdir = $(datadir)/doc/@PACKAGE@
doc_DATA = README.md README.Office365.md config LICENSE CHANGELOG.md
man_MANS = onedrive.1

onedrive.1: onedrive.1.in
	$(SED) -e 's,[@]FinalDocDir[@],$(docdir),g' < $< > $@


#
# Service files for systemd
#
system_unit_files = systemd.units/onedrive@.service
user_unit_files = systemd.units/onedrive.service
DISTCHECK_CONFIGURE_FLAGS = \
	--with-systemdsystemunitdir=$$dc_install_base/$(systemdsystemunitdir) \
	--with-systemduserunitdir=$$dc_install_base/$(systemduserunitdir)
if HAVE_SYSTEMD
systemdsystemunit_DATA = systemd.units/onedrive@.service
systemduserunit_DATA = systemd.units/onedrive.service
endif

SUFFIXES = .service.in .service
.service.in.service:
	$(SED) -e 's,[@]bindir[@],$(bindir),g' < $< > $@



CLEANFILES = onedrive onedrive.o \
	     systemd.units/onedrive.service systemd.units/onedrive@.service \
	     onedrive.1 version


version:
	if [ -d .git/ ] ; then \
		echo $(shell git describe --tags) >version ; \
	else \
		echo @VERSION@ > version ; \
	fi

