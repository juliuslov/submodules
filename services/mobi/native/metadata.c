#include "service.h"
#include <stdlib.h>
#include <string.h>
typedef char *(*getter)(const MOBIData *);
int hikari_metadata(const MOBIData *m, size_t length, int extended, int nested) {
    const char *keys[] = { "title", "author", "language", "publisher", "imprint", "description", "isbn", "subject", "publishdate", "review", "contributor", "copyright", "asin" };
    getter getters[] = { mobi_meta_get_title, mobi_meta_get_author, mobi_meta_get_language, mobi_meta_get_publisher,
        mobi_meta_get_imprint, mobi_meta_get_description, mobi_meta_get_isbn, mobi_meta_get_subject,
        mobi_meta_get_publishdate, mobi_meta_get_review, mobi_meta_get_contributor, mobi_meta_get_copyright, mobi_meta_get_asin };
    char *values[13] = {0};
    size_t count = extended ? 13 : 3, i;
    for (i = 0; i < count; ++i) {
        values[i] = getters[i](m);
        if (values[i] && strlen(values[i]) > (i == 2 ? 128 : 4096)) {
            size_t j; for (j = 0; j <= i; ++j) free(values[j]);
            return hikari_error("MOBI metadata exceeds limit");
        }
    }
    if (nested) fputs("{\"info\":", stdout);
    printf("{\"ok\":true,\"version\":%zu,\"compression\":%u,\"encoding\":%u,\"textBytes\":%zu,\"records\":%u",
        mobi_get_fileversion(m), m->rh->compression_type, (unsigned int)*m->mh->text_encoding, length, m->ph->rec_count);
    for (i = 0; i < count; ++i) {
        const char *fallback = i == 0 ? "Untitled" : i == 1 ? "Anonymous" : i == 2 ? "und" : "";
        fputs(",", stdout); wiz_json_string(stdout, keys[i]); fputs(":", stdout);
        wiz_json_string(stdout, values[i] ? values[i] : fallback); free(values[i]);
    }
    if (extended) printf(",\"hybrid\":%s,\"kf8\":%s", mobi_is_hybrid(m) ? "true" : "false", mobi_is_kf8(m) ? "true" : "false");
    fputs("}", stdout); return 0;
}
