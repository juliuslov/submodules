#ifndef WIZ_ARCHIVE_SERVICE_H
#define WIZ_ARCHIVE_SERVICE_H
#include <stddef.h>
#include <stdio.h>
#define WIZ_MAX_ARCHIVE (64ULL * 1024 * 1024)
#define WIZ_MAX_ENTRY (16ULL * 1024 * 1024)
#define WIZ_MAX_TOTAL (128ULL * 1024 * 1024)
#define WIZ_MAX_FILES 4096
int wiz_safe_path(const char *name);
void wiz_json_string(FILE *out, const char *text);
int wiz_archive_inspect(const char *path);
#endif
