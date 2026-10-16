#include "archive_service.h"
#include <string.h>

/* JSON replies are UTF-8. Reject malformed/overlong UTF-8 and surrogate codepoints
 * rather than writing invalid JSON or silently replacing filename bytes. */
static int valid_utf8(const unsigned char *p) {
    while (*p) {
        unsigned char c = *p++;
        unsigned int value, minimum, remaining;
        if (c < 0x80) continue;
        if (c >= 0xc2 && c <= 0xdf) { value = c & 0x1f; remaining = 1; minimum = 0x80; }
        else if (c >= 0xe0 && c <= 0xef) { value = c & 0x0f; remaining = 2; minimum = 0x800; }
        else if (c >= 0xf0 && c <= 0xf4) { value = c & 0x07; remaining = 3; minimum = 0x10000; }
        else return 0;
        while (remaining--) {
            /* Stop at NUL before moving farther into a truncated string. */
            if ((*p & 0xc0) != 0x80) return 0;
            value = (value << 6) | (*p++ & 0x3f);
        }
        if (value < minimum || value > 0x10ffff || (value >= 0xd800 && value <= 0xdfff)) return 0;
    }
    return 1;
}

/* ZIP paths are relative POSIX names. No extraction is ever performed. */
int wiz_safe_path(const char *name) {
    const char *start = name, *p = name;
    if (!name || !*name || *name == '/' || !valid_utf8((const unsigned char *)name)) return 0;
    for (;;) {
        unsigned char c = (unsigned char)*p;
        if (c == '\\' || c == ':' || (c && c < 32) || c == 127) return 0;
        if (!c || c == '/') {
            size_t n = (size_t)(p - start);
            if (!n || (n == 1 && *start == '.') ||
                (n == 2 && start[0] == '.' && start[1] == '.')) return 0;
            if (!c || !p[1]) return 1; /* directory slash is allowed */
            start = p + 1;
        }
        ++p;
    }
}
