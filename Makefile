CC ?= cc
CFLAGS ?= -O2
CPPFLAGS += -Iservices/archive/include -Ivendor/miniz -Ibuild -D_POSIX_C_SOURCE=200809L
WARN = -Wall -Wextra -Wpedantic
NATIVE = services/archive/src/main.c services/archive/src/inspect.c services/archive/src/path.c services/archive/src/json.c
MINIZ = vendor/miniz/miniz.c vendor/miniz/miniz_zip.c vendor/miniz/miniz_tinfl.c vendor/miniz/miniz_tdef.c
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
clean:
	rm -rf build dist

# No crates.io dependencies: Rust std + a small shim around pinned stb_image.
RUSTC ?= rustc
AR ?= ar
ASCII_RS = services/ascii/src/main.rs services/ascii/src/image.rs services/ascii/src/render.rs
.PHONY: ascii test-ascii
ascii: build/wiz-ascii
build/image_decode.o: services/ascii/native/decode.c vendor/stb/stb_image.h
	mkdir -p build
	$(CC) -std=c99 -O2 -Ivendor/stb -c $< -o $@
build/libwiz_image.a: build/image_decode.o
	$(AR) rcs $@ $<
build/wiz-ascii: $(ASCII_RS) build/libwiz_image.a
	$(RUSTC) --edition=2021 -D warnings -O services/ascii/src/main.rs -L native=build -l static=wiz_image -l m -o $@
build/wiz-ascii-tests: $(ASCII_RS) build/libwiz_image.a
	$(RUSTC) --edition=2021 -D warnings --test services/ascii/src/main.rs -L native=build -l static=wiz_image -l m -o $@
test-ascii: ascii build/wiz-ascii-tests
	build/wiz-ascii-tests

# Replaceable LGPL library; DRM and XML/resource reconstruction features disabled.
LIBMOBI_SRC = $(addprefix vendor/libmobi/src/,buffer.c compression.c debug.c index.c memory.c meta.c parse_rawml.c read.c structure.c util.c write.c)
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
mobi: build/wiz-mobi
build/libmobi-miniz.o: vendor/libmobi/src/miniz.c
	mkdir -p build
	$(CC) -std=c99 -O2 -fPIC -DMINIZ_NO_STDIO -DMINIZ_NO_ZLIB_COMPATIBLE_NAMES -DMINIZ_NO_TIME -DMINIZ_NO_ARCHIVE_APIS -DMINIZ_NO_ARCHIVE_WRITING_APIS -c $< -o $@
$(MOBI_LIB): $(LIBMOBI_SRC) $(wildcard vendor/libmobi/src/*.h) build/libmobi-miniz.o
	mkdir -p build
	$(CC) -std=c99 -D_POSIX_C_SOURCE=200809L -DUSE_MINIZ -DPACKAGE_VERSION='"git-9062742"' -fPIC $(CFLAGS) $(MOBI_SHARED) -Ivendor/libmobi/src $(LIBMOBI_SRC) build/libmobi-miniz.o -o $@
build/wiz-mobi: services/mobi/native/main.c services/archive/src/json.c $(MOBI_LIB)
	$(CC) -std=c99 -D_POSIX_C_SOURCE=200809L $(CFLAGS) $(WARN) -Ivendor/libmobi/src -Iservices/archive/include services/mobi/native/main.c services/archive/src/json.c -Lbuild $(MOBI_RPATH) -lmobi -o $@
.PHONY: test-mobi
test-mobi: mobi
	python3 -m unittest discover -s tests -p 'test_mobi.py' -v
