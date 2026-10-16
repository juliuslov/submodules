#include "service.h"
int hikari_decode(MOBIData *m) {
    MOBIRawml *raw = mobi_init_rawml(m);
    MOBIPart *part;
    size_t total = 0, count = 0, i;
    int result;
    if (!raw) return hikari_error("cannot initialize reconstruction");
    /* Reconstruct source, references, flows and KF8 skeleton/fragments in memory.
       No paths supplied by a book are written to the filesystem. */
    if (mobi_parse_rawml_opt(raw, m, true, false, true) != MOBI_SUCCESS) {
        mobi_free_rawml(raw); return hikari_error("libmobi reconstruction failed");
    }
    for (part = raw->markup; part; part = part->next) {
        if (++count > 256 || part->size > MAX_TEXT - total || !part->data) {
            mobi_free_rawml(raw); return hikari_error("reconstructed markup limits exceeded");
        }
        total += part->size;
    }
    if (!count || !total) { mobi_free_rawml(raw); return hikari_error("no reconstructed markup"); }
    result = hikari_metadata(m, m->rh->text_length, 1, 1);
    if (result) { mobi_free_rawml(raw); return result; }
    fputs(",\"parts\":[", stdout);
    count = 0;
    for (part = raw->markup; part; part = part->next) {
        if (count++) fputs(",", stdout);
        /* Hex is unambiguous for any source byte; TS decodes reconstructed UTF-8. */
        fputs("\"", stdout);
        for (i = 0; i < part->size; ++i) printf("%02x", part->data[i]);
        fputs("\"", stdout);
    }
    fputs("]}\n", stdout); mobi_free_rawml(raw); return ferror(stdout) ? 1 : 0;
}
