DC = dmd
DFLAGS = -unittest -debug -g -gs -od./bin -of./bin/$@ -L-lcurl -L-lsqlite3 -L-ldl

SOURCES = \
	/usr/include/dlang/dmd/etc/c/curl.d \
	/usr/include/dlang/dmd/std/net/curl.d \
	src/config.d \
	src/itemdb.d \
	src/main.d \
	src/monitor.d \
	src/onedrive.d \
	src/sqlite.d \
	src/sync.d \
	src/util.d

onedrive: $(SOURCES)
	$(DC) $(DFLAGS) $(SOURCES)
