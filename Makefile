DC = dmd
DFLAGS = -debug -g -gs -od./bin -of./bin/$@ -L-lcurl -L-lsqlite3 -L-ldl

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
	$(DC) $(DFLAGS) $(SOURCES)
