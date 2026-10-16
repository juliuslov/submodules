CC ?= cc
CFLAGS ?= -O2
CPPFLAGS += -Iservices/archive/include -Ivendor/miniz -Ibuild -D_POSIX_C_SOURCE=200809L
WARN = -Wall -Wextra -Wpedantic
NATIVE = services/archive/src/main.c services/archive/src/inspect.c services/archive/src/path.c services/archive/src/json.c
MINIZ = vendor/miniz/miniz.c vendor/miniz/miniz_zip.c vendor/miniz/miniz_tinfl.c vendor/miniz/miniz_tdef.c
CARGO ?= cargo
.PHONY: all native test-native clean
all: native ascii mobi
native: build/wiz-archive
build/miniz_export.h:
	mkdir -p build
	printf '#ifndef MINIZ_EXPORT\n#define MINIZ_EXPORT\n#endif\n' > $@
build/wiz-archive: $(NATIVE) $(MINIZ) services/archive/include/archive_service.h build/miniz_export.h
	$(CC) -std=c99 $(CPPFLAGS) $(CFLAGS) $(WARN) $(NATIVE) $(MINIZ) -o $@
test-native: native
	python3 -m unittest discover -s tests -p 'test_archive.py' -v

# Image-to-ASCII is a napi-rs addon (services/ascii/native), and the build is
# OPTIONAL: without a Rust toolchain, scripts/build-ascii.mjs reports how to get
# the addon and the built-in TypeScript renderer in services/ascii/render/ keeps
# the feature working. A toolchain that is present and fails still fails.
.PHONY: ascii test-ascii
ascii:
	node scripts/build-ascii.mjs
test-ascii:
	@if command -v $(CARGO) >/dev/null 2>&1; then $(CARGO) test --manifest-path services/ascii/native/Cargo.toml; \
	else printf '%s\n' 'hikari: cargo not installed; Rust renderer tests skipped (the TypeScript fallback is covered by node --test tests/ascii.*.test.cjs).'; fi

clean:
	rm -rf build dist services/ascii/native/target

# Replaceable LGPL library with internal XML/OPF writer. DRM stays disabled.
LIBMOBI_SRC = $(addprefix vendor/libmobi/src/,buffer.c compression.c debug.c index.c memory.c meta.c parse_rawml.c read.c structure.c util.c write.c opf.c xmlwriter.c)
UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
MOBI_LIB = build/libmobi.dylib
MOBI_SHARED = -dynamiclib -Wl,-install_name,@rpath/libmobi.dylib
MOBI_RPATH = -Wl,-rpath,@loader_path
else
MOBI_LIB = build/libmobi.so
MOBI_SHARED = -shared
MOBI_RPATH = -Wl,-rpath,'$$ORIGIN'
endif
.PHONY: mobi
mobi: build/wiz-mobi libmobi-tools
build/libmobi-miniz.o: vendor/libmobi/src/miniz.c
	mkdir -p build
	$(CC) -std=c99 -O2 -fPIC -DMINIZ_NO_STDIO -DMINIZ_NO_ZLIB_COMPATIBLE_NAMES -DMINIZ_NO_TIME -DMINIZ_NO_ARCHIVE_APIS -DMINIZ_NO_ARCHIVE_WRITING_APIS -c $< -o $@
$(MOBI_LIB): $(LIBMOBI_SRC) $(wildcard vendor/libmobi/src/*.h) build/libmobi-miniz.o
	mkdir -p build
	$(CC) -std=c99 -D_POSIX_C_SOURCE=200809L -DUSE_MINIZ -DUSE_XMLWRITER -DPACKAGE_VERSION='"git-9062742"' -fPIC $(CFLAGS) $(MOBI_SHARED) -Ivendor/libmobi/src $(LIBMOBI_SRC) build/libmobi-miniz.o -o $@
MOBI_ADAPTER = $(wildcard services/mobi/native/*.c)
build/wiz-mobi: $(MOBI_ADAPTER) services/mobi/native/service.h services/archive/src/json.c services/archive/include/archive_service.h $(MOBI_LIB)
	$(CC) -std=c99 -D_POSIX_C_SOURCE=200809L $(CFLAGS) $(WARN) -Ivendor/libmobi/src -Iservices/archive/include $(MOBI_ADAPTER) services/archive/src/json.c -Lbuild $(MOBI_RPATH) -lmobi -o $@
.PHONY: test-mobi
test-mobi: mobi
	python3 -m unittest discover -s tests -p 'test_mobi.py' -v

# Upstream DRM-free CLI features, including EPUB source/ZIP generation and metadata editing.
.PHONY: libmobi-tools
libmobi-tools: build/mobitool build/mobimeta
build/libmobi-tool-miniz.o: vendor/libmobi/src/miniz.c
	mkdir -p build
	$(CC) -std=c99 -D_POSIX_C_SOURCE=200809L -O2 -DMINIZ_NO_ZLIB_COMPATIBLE_NAMES -c $< -o $@
build/mobitool: vendor/libmobi/tools/mobitool.c vendor/libmobi/tools/common.c $(MOBI_LIB) build/libmobi-tool-miniz.o
	$(CC) -std=c99 -D_POSIX_C_SOURCE=200809L -DHAVE_GETOPT -DUSE_XMLWRITER -Ivendor/libmobi/src $(CFLAGS) vendor/libmobi/tools/mobitool.c vendor/libmobi/tools/common.c build/libmobi-tool-miniz.o -Lbuild $(MOBI_RPATH) -lmobi -o $@
build/mobimeta: vendor/libmobi/tools/mobimeta.c vendor/libmobi/tools/common.c $(MOBI_LIB)
	$(CC) -std=c99 -D_POSIX_C_SOURCE=200809L -DHAVE_GETOPT -Ivendor/libmobi/src $(CFLAGS) vendor/libmobi/tools/mobimeta.c vendor/libmobi/tools/common.c -Lbuild $(MOBI_RPATH) -lmobi -o $@
