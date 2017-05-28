DC = dmd
DFLAGS = -ofonedrive -L-lcurl -L-lsqlite3 -L-ldl
DESTDIR = /usr/local/bin

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

onedrive: $(SOURCES)
	$(DC) -O -release -inline -boundscheck=off $(DFLAGS) $(SOURCES)

debug: $(SOURCES)
	$(DC) -debug -g -gs $(DFLAGS) $(SOURCES)

unittest: $(SOURCES)
	$(DC) -unittest -debug -g -gs $(DFLAGS) $(SOURCES)

clean:
	rm -f onedrive.o onedrive

install: onedrive onedrive.service
	install onedrive $(DESTDIR)/onedrive
	install -m 644 onedrive.service /usr/lib/systemd/user

uninstall:
	rm -f $(DESTDIR)/onedrive
	rm -f /usr/lib/systemd/user/onedrive.service
