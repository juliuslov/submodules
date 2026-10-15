CC ?= cc
CFLAGS ?= -O2
CPPFLAGS += -Iservices/archive/include -Ivendor/miniz -Ibuild -D_POSIX_C_SOURCE=200809L
WARN = -Wall -Wextra -Wpedantic
NATIVE = services/archive/src/main.c services/archive/src/inspect.c services/archive/src/path.c services/archive/src/json.c
MINIZ = vendor/miniz/miniz.c vendor/miniz/miniz_zip.c vendor/miniz/miniz_tinfl.c vendor/miniz/miniz_tdef.c
.PHONY: all native test-native clean
all: native
native: build/wiz-archive
build/miniz_export.h:
	mkdir -p build
	printf '#ifndef MINIZ_EXPORT\n#define MINIZ_EXPORT\n#endif\n' > $@
build/wiz-archive: $(NATIVE) $(MINIZ) services/archive/include/archive_service.h build/miniz_export.h
	$(CC) -std=c99 $(CPPFLAGS) $(CFLAGS) $(WARN) $(NATIVE) $(MINIZ) -o $@
test-native: native
	python3 -m unittest discover -s tests -p 'test_archive.py' -v
clean:
	rm -rf build dist
