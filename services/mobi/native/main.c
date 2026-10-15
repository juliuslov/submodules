/* Original companion adapter. libmobi is loaded as a replaceable shared library. */
#include "mobi.h"
#include "archive_service.h"
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>

#define MAX_INPUT (64UL * 1024 * 1024)
#define MAX_TEXT (8UL * 1024 * 1024)
#define MAX_RECORDS 4096
static unsigned int be16(const unsigned char *p) { return ((unsigned int)p[0] << 8) | p[1]; }
static uint32_t be32(const unsigned char *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3];
}
static int error(const char *message) {
    fputs("{\"ok\":false,\"error\":", stderr); wiz_json_string(stderr, message); fputs("}\n", stderr); return 1;
}
/* Reject invalid PDB tables before handing offsets to either upstream parser. */
static const char *preflight(FILE *file, size_t size) {
    unsigned char header[78], entry[8], record[248];
    size_t count, first = 0, second = 0, previous = 0, i;
    if (size < 78 || fread(header, 1, 78, file) != 78 || memcmp(header + 60, "BOOKMOBI", 8)) return "expected a BOOK/MOBI Palm database";
    count = be16(header + 76);
    if (count < 2 || count > MAX_RECORDS || 78 + count * 8 + 2 >= size || be32(header + 72)) return "invalid PDB record count or chained database";
    for (i = 0; i < count; ++i) {
        size_t offset;
        if (fread(entry, 1, 8, file) != 8) return "truncated PDB table";
        offset = be32(entry);
        if (offset < 78 + count * 8 + 2 || offset >= size || (i && offset <= previous)) return "invalid or nonmonotonic PDB offsets";
        if (!i) first = offset;
        if (i == 1) second = offset;
        previous = offset;
    }
    if (second - first < 248 || fseek(file, (long)first, SEEK_SET) || fread(record, 1, 248, file) != 248 || memcmp(record + 16, "MOBI", 4)) return "truncated or unsupported MOBI header";
    if (be16(record + 12)) return "DRM/encrypted MOBI is unsupported";
    if (be32(record + 36) != 6 && be32(record + 36) != 7) return "only legacy MOBI 6/7 is supported; KF8/AZW3/KFX is unsupported";
    if (be16(record) != 1 && be16(record) != 2) return "only uncompressed or PalmDOC-compressed MOBI is supported";
    if (!be32(record + 4) || be32(record + 4) > MAX_TEXT || !be16(record + 8) || be16(record + 8) >= count || !be16(record + 10) || be16(record + 10) > 4096) return "MOBI text/record limits exceeded";
    if (be32(record + 20) < 232 || be32(record + 20) > second - first - 16 || be32(record + 24) != 2) return "unsupported MOBI header or document type";
    if (be32(record + 28) != 65001 && be32(record + 28) != 1252) return "only UTF-8 and Windows-1252 MOBI text is supported";
    if (be32(record + 40) != UINT32_MAX || be32(record + 44) != UINT32_MAX) return "MOBI dictionaries are unsupported";
    rewind(file);
    return NULL;
}
int main(int argc, char **argv) {
    FILE *file;
    struct stat statbuf;
    MOBIData *m;
    MOBIPdbRecord *record;
    const char *failure;
    char *text, *title, *author, *language;
    size_t length = MAX_TEXT, i = 0;
    int ret = 0, fd;
    if (argc == 2 && !strcmp(argv[1], "--version")) { printf("wiz-mobi 1.0.0 / libmobi %s\n", mobi_version()); return 0; }
    if (argc != 3 || (strcmp(argv[1], "inspect") && strcmp(argv[1], "text"))) return error("usage: wiz-mobi inspect|text <file.mobi>");
    fd = open(argv[2], O_RDONLY | O_NONBLOCK);
    if (fd < 0) return error("cannot open MOBI input");
    if (fstat(fd, &statbuf) || !S_ISREG(statbuf.st_mode) || statbuf.st_size < 0 || (uint64_t)statbuf.st_size > MAX_INPUT) {
        close(fd); return error("expected a regular MOBI file at most 64 MiB");
    }
    file = fdopen(fd, "rb");
    if (!file) { close(fd); return error("cannot open MOBI input stream"); }
    failure = preflight(file, (size_t)statbuf.st_size);
    if (failure) { fclose(file); return error(failure); }
    m = mobi_init();
    if (!m) { fclose(file); return error("cannot initialize libmobi"); }
    /* Prefer the legacy part of a hybrid. The adapter rejects hybrids below. */
    m->use_kf8 = false;
    if (mobi_load_file(m, file) != MOBI_SUCCESS) { fclose(file); mobi_free(m); return error("libmobi could not parse MOBI input"); }
    fclose(file);
    if (!m->rh || !m->mh || mobi_is_encrypted(m) || mobi_is_hybrid(m) || mobi_is_dictionary(m)) { mobi_free(m); return error("encrypted or hybrid MOBI is unsupported"); }
    for (record = m->rec; record && i <= m->rh->text_record_count; record = record->next, ++i) {
        if (i && record->size > 65536) { mobi_free(m); return error("MOBI text record exceeds 64 KiB"); }
    }
    text = malloc(MAX_TEXT + 1);
    if (!text) { mobi_free(m); return error("out of memory"); }
    if (mobi_get_rawml(m, text, &length) != MOBI_SUCCESS || length != m->rh->text_length) {
        free(text); mobi_free(m); return error("invalid decompressed MOBI text length or compressed data");
    }
    if (length >= 4 && !memcmp(text, "%MOP", 4)) {
        free(text); mobi_free(m); return error("print-replica MOBI is unsupported");
    }
    if (!strcmp(argv[1], "text")) {
        if (fwrite(text, 1, length, stdout) != length) ret = 1;
    } else {
        title = mobi_meta_get_title(m); author = mobi_meta_get_author(m); language = mobi_meta_get_language(m);
        if ((title && strlen(title) > 4096) || (author && strlen(author) > 4096) || (language && strlen(language) > 128)) {
            free(title); free(author); free(language); free(text); mobi_free(m); return error("MOBI metadata exceeds limit");
        }
        printf("{\"ok\":true,\"version\":%zu,\"compression\":%u,\"encoding\":%u,\"textBytes\":%zu,\"records\":%u,\"title\":",
               mobi_get_fileversion(m), m->rh->compression_type, m->mh->text_encoding ? (unsigned int)*m->mh->text_encoding : 0, length, m->ph->rec_count);
        wiz_json_string(stdout, title ? title : "Untitled"); fputs(",\"author\":", stdout);
        wiz_json_string(stdout, author ? author : "Anonymous"); fputs(",\"language\":", stdout);
        wiz_json_string(stdout, language ? language : "und"); fputs("}\n", stdout);
        free(title); free(author); free(language);
    }
    free(text); mobi_free(m); return ret;
}
