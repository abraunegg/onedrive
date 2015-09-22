DC = dmd
DFLAGS = -ofonedrive -L-lcurl -L-lsqlite3 -L-ldl
DESTDIR = /usr/local/bin
CONFDIR = /usr/local/etc

SOURCES = \
	patch/etc_c_curl.d \
	patch/std_net_curl.d \
	src/config.d \
	src/itemdb.d \
	src/main.d \
	src/monitor.d \
	src/onedrive.d \
	src/sqlite.d \
	src/sync.d \
	src/util.d

onedrive: $(SOURCES)
	$(DC) -O -release -inline -boundscheck=off $(DFLAGS) $(SOURCES)

debug: $(SOURCES)
	$(DC) -unittest -debug -g -gs $(DFLAGS) $(SOURCES)

clean:
	rm -f onedrive.o onedrive

install: onedrive onedrive.conf
	install onedrive $(DESTDIR)
	install onedrive.conf $(CONFDIR)

uninstall:
	rm -f $(DESTDIR)/onedrive
	rm -f $(CONFDIR)/onedrive.conf
