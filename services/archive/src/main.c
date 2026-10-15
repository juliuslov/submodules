#include "archive_service.h"
#include <string.h>
int main(int argc, char **argv) {
    if (argc == 2 && !strcmp(argv[1], "--version")) {
        puts("wiz-archive 1.0.0"); return 0;
    }
    if (argc != 3 || strcmp(argv[1], "inspect")) {
        fputs("usage: wiz-archive inspect <file.zip>\n", stderr); return 2;
    }
    return wiz_archive_inspect(argv[2]);
}
