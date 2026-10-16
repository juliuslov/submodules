#include "service.h"
#include <sys/resource.h>
#include <stdint.h>
int hikari_error(const char *message) {
    fputs("{\"ok\":false,\"error\":", stderr);
    wiz_json_string(stderr, message); fputs("}\n", stderr); return 1;
}
void hikari_limits(void) {
    /* Lower existing limits only. Subprocess wall/output deadlines remain in TS. */
    struct rlimit limit;
    if (!getrlimit(RLIMIT_CPU, &limit) && limit.rlim_cur > 25) { limit.rlim_cur = 25; setrlimit(RLIMIT_CPU, &limit); }
#ifdef RLIMIT_AS
    if (!getrlimit(RLIMIT_AS, &limit) && limit.rlim_cur > 512UL * 1024 * 1024) {
        limit.rlim_cur = 512UL * 1024 * 1024; setrlimit(RLIMIT_AS, &limit);
    }
#endif
}
static const char *section(const MOBIData *m, int extended) {
    size_t offset, i;
    if (!m || !m->rh || !m->mh || !m->ph) return "missing MOBI section header";
    if (mobi_is_encrypted(m)) return "DRM/encrypted MOBI is unsupported";
    if (mobi_is_dictionary(m)) return "MOBI dictionaries are unsupported";
    if (mobi_is_replica(m)) return "print-replica MOBI is unsupported";
    if (!m->rh->text_length || m->rh->text_length > MAX_TEXT || !m->rh->text_record_count ||
        !m->rh->text_record_size || m->rh->text_record_size > 4096) return "MOBI text/record limits exceeded";
    if (m->rh->compression_type != 1 && m->rh->compression_type != 2 &&
        !(extended && m->rh->compression_type == 17480)) return "unsupported MOBI compression";
    if (!m->mh->text_encoding || (*m->mh->text_encoding != 65001 && *m->mh->text_encoding != 1252)) return "unsupported MOBI encoding";
    offset = mobi_get_kf8offset(m);
    if (offset >= m->ph->rec_count || m->rh->text_record_count >= m->ph->rec_count - offset) return "invalid text section record count";
    for (i = 1; i <= m->rh->text_record_count; ++i) {
        MOBIPdbRecord *record = mobi_get_record_by_seqnumber(m, i + offset);
        if (!record || record->size > 65536) return "MOBI text record exceeds 64 KiB or is missing";
    }
    return NULL;
}
const char *hikari_validate(const MOBIData *m, int extended) {
    const char *failure = section(m, extended);
    if (failure) return failure;
    if (!extended && mobi_is_hybrid(m)) return "encrypted or hybrid MOBI is unsupported";
    if (mobi_is_hybrid(m)) return section(m->next, extended);
    return NULL;
}
