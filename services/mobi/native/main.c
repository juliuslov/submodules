/* Original bounded process adapter; upstream library remains replaceable. */
#include "service.h"
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
int main(int argc, char **argv) {
    FILE *file;
    struct stat st;
    MOBIData *m;
    const char *failure;
    char *text;
    size_t length = MAX_TEXT;
    int fd, ret = 0, extended;
    if (argc == 2 && !strcmp(argv[1], "--version")) { printf("wiz-mobi 1.2.0 / libmobi %s\n", mobi_version()); return 0; }
    if (argc == 2 && !strcmp(argv[1], "--capabilities")) {
        puts("{\"library\":\"libmobi\",\"reconstruction\":true,\"kf8\":true,\"huffcdic\":true,\"xmlwriter\":true,\"metadata\":true,\"loadedBookWriter\":true,\"drm\":false,\"newBookEncoder\":false,\"tools\":[\"mobitool\",\"mobimeta\"]}"); return 0;
    }
    if (argc != 3) return hikari_error("usage: wiz-mobi inspect|inspect-all|text|decode <file>");
    extended = !strcmp(argv[1], "decode") || !strcmp(argv[1], "inspect-all");
    if (!extended && strcmp(argv[1], "inspect") && strcmp(argv[1], "text")) return hikari_error("unknown MOBI operation");
    hikari_limits();
    fd = open(argv[2], O_RDONLY | O_NONBLOCK);
    if (fd < 0) return hikari_error("cannot open MOBI input");
    if (fstat(fd, &st) || !S_ISREG(st.st_mode) || st.st_size < 0 || (uint64_t)st.st_size > MAX_INPUT) {
        close(fd); return hikari_error("expected a regular MOBI file at most 64 MiB");
    }
    file = fdopen(fd, "rb");
    if (!file) { close(fd); return hikari_error("cannot open MOBI stream"); }
    failure = hikari_preflight(file, (size_t)st.st_size, extended);
    if (failure) { fclose(file); return hikari_error(failure); }
    m = mobi_init();
    if (!m) { fclose(file); return hikari_error("cannot initialize libmobi"); }
    m->use_kf8 = extended;
    if (mobi_load_file(m, file) != MOBI_SUCCESS) { fclose(file); mobi_free(m); return hikari_error("libmobi could not parse MOBI input"); }
    fclose(file);
    failure = hikari_validate(m, extended);
    if (failure) { mobi_free(m); return hikari_error(failure); }
    text = malloc(MAX_TEXT + 1);
    if (!text) { mobi_free(m); return hikari_error("out of memory"); }
    if (mobi_get_rawml(m, text, &length) != MOBI_SUCCESS || length != m->rh->text_length) {
        free(text); mobi_free(m); return hikari_error("invalid decompressed MOBI text length or compressed data");
    }
    if (length >= 4 && !memcmp(text, "%MOP", 4)) {
        free(text); mobi_free(m); return hikari_error("print-replica MOBI is unsupported");
    }
    if (!strcmp(argv[1], "text")) ret = fwrite(text, 1, length, stdout) == length ? 0 : 1;
    else if (!strcmp(argv[1], "decode")) ret = hikari_decode(m);
    else { ret = hikari_metadata(m, length, extended, 0); if (!ret) puts(""); }
    free(text); mobi_free(m); return ret;
}
