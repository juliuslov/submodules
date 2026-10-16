#include "archive_service.h"
#include "miniz.h"
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

static int fail(mz_zip_archive *zip, const char *message) {
    if (zip->m_pState) mz_zip_reader_end(zip);
    fputs("{\"ok\":false,\"error\":", stderr);
    wiz_json_string(stderr, message);
    fputs("}\n", stderr);
    return 1;
}

/* miniz's archive validator intentionally skips declared zero-length entries.
 * Explicit extraction to a rejecting sink detects payloads disguised as empty. */
static size_t empty_sink(void *opaque, mz_uint64 offset, const void *data, size_t size) {
    (void)opaque; (void)offset; (void)data; (void)size;
    return 0;
}

int wiz_archive_inspect(const char *path) {
    mz_zip_archive zip;
    mz_uint count, i, j;
    mz_uint64 total = 0;
    struct stat st;
    char **names = NULL;
    const char *error = NULL;
    memset(&zip, 0, sizeof(zip));
    if (stat(path, &st) || !S_ISREG(st.st_mode) || st.st_size < 0 ||
        (mz_uint64)st.st_size > WIZ_MAX_ARCHIVE)
        return fail(&zip, "expected a regular ZIP file at most 64 MiB");
    if (!mz_zip_reader_init_file(&zip, path, 0)) return fail(&zip, "invalid ZIP archive");
    count = mz_zip_reader_get_num_files(&zip);
    if (!count || count > WIZ_MAX_FILES) return fail(&zip, "entry count exceeds limit or archive is empty");
    names = calloc(count, sizeof(*names));
    if (!names) return fail(&zip, "out of memory");
    for (i = 0; i < count; ++i) {
        mz_zip_archive_file_stat item;
        mz_uint len = mz_zip_reader_get_filename(&zip, i, NULL, 0);
        if (!len || len > 4096) { error = "invalid or overlong ZIP filename"; break; }
        names[i] = malloc(len);
        if (!names[i]) { error = "out of memory"; break; }
        if (mz_zip_reader_get_filename(&zip, i, names[i], len) != len ||
            strlen(names[i]) != len - 1 || !wiz_safe_path(names[i])) {
            error = "unsafe ZIP path"; break;
        }
        for (j = 0; j < i; ++j) {
            if (!strcmp(names[i], names[j])) { error = "duplicate ZIP path"; break; }
        }
        if (error) break;
        if (!mz_zip_reader_file_stat(&zip, i, &item) || item.m_is_encrypted ||
            !item.m_is_supported || (item.m_method != 0 && item.m_method != 8)) {
            error = "encrypted or unsupported ZIP entry"; break;
        }
        if (item.m_uncomp_size > WIZ_MAX_ENTRY || item.m_uncomp_size > WIZ_MAX_TOTAL - total) {
            error = "uncompressed size exceeds limit"; break;
        }
        if ((item.m_method == 0 && item.m_comp_size != item.m_uncomp_size) ||
            (item.m_method == 8 && item.m_comp_size < 2) ||
            (!item.m_uncomp_size && item.m_crc32 != 0) ||
            (item.m_is_directory && item.m_uncomp_size != 0)) {
            error = "inconsistent ZIP size or empty-entry CRC"; break;
        }
        if (!item.m_is_directory && !item.m_uncomp_size && item.m_comp_size &&
            !mz_zip_reader_extract_to_callback(&zip, i, empty_sink, NULL, 0)) {
            error = "nonempty or corrupt payload declared empty"; break;
        }
        total += item.m_uncomp_size;
    }
    /* Check local headers, decompression and CRC before returning any success. */
    if (!error && !mz_zip_validate_archive(&zip, 0)) error = "ZIP integrity check failed";
    if (!error) {
        printf("{\"ok\":true,\"totalBytes\":%llu,\"entries\":[", (unsigned long long)total);
        for (i = 0; i < count; ++i) {
            mz_zip_archive_file_stat item;
            if (!mz_zip_reader_file_stat(&zip, i, &item)) { error = "ZIP changed while reading"; break; }
            if (i) fputc(',', stdout);
            fputs("{\"name\":", stdout); wiz_json_string(stdout, names[i]);
            printf(",\"size\":%llu,\"compressedSize\":%llu,\"method\":%u}",
                   (unsigned long long)item.m_uncomp_size,
                   (unsigned long long)item.m_comp_size, (unsigned)item.m_method);
        }
        fputs("]}\n", stdout);
    }
    for (i = 0; i < count; ++i) free(names[i]);
    free(names);
    if (error) return fail(&zip, error);
    mz_zip_reader_end(&zip);
    return 0;
}
