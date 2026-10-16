#include "service.h"
#include <string.h>
#include <stdint.h>
static unsigned int be16(const unsigned char *p) { return ((unsigned int)p[0] << 8) | p[1]; }
static uint32_t be32(const unsigned char *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3];
}
/* Reject invalid PDB tables before handing offsets to either upstream parser. */
const char *hikari_preflight(FILE *file, size_t size, int extended) {
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
    if (be32(record + 36) != 6 && be32(record + 36) != 7 && !(extended && be32(record + 36) == 8)) return "only legacy MOBI 6/7 is supported; KF8/AZW3/KFX is unsupported";
    if (be16(record) != 1 && be16(record) != 2 && !(extended && be16(record) == 17480)) return "only uncompressed or PalmDOC-compressed MOBI is supported";
    if (!be32(record + 4) || be32(record + 4) > MAX_TEXT || !be16(record + 8) || be16(record + 8) >= count || !be16(record + 10) || be16(record + 10) > 4096) return "MOBI text/record limits exceeded";
    if (be32(record + 20) < 232 || be32(record + 20) > second - first - 16 || be32(record + 24) != 2) return "unsupported MOBI header or document type";
    if (be32(record + 28) != 65001 && be32(record + 28) != 1252) return "only UTF-8 and Windows-1252 MOBI text is supported";
    if (be32(record + 40) != UINT32_MAX || be32(record + 44) != UINT32_MAX) return "MOBI dictionaries are unsupported";
    rewind(file);
    return NULL;
}
