DC = dmd
DFLAGS = -unittest -debug -g -od./bin -of./bin/$@ -L-lcurl -L-lsqlite3

SOURCES = \
	src/cache.d \
	src/config.d \
	src/main.d \
	src/onedrive.d \
	src/sqlite.d \
	src/sync.d \
	src/util.d

onedrive: $(SOURCES)
	$(DC) $(DFLAGS) $(SOURCES)
