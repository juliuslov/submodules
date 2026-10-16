#ifndef HIKARI_MOBI_SERVICE_H
#define HIKARI_MOBI_SERVICE_H
#include "mobi.h"
#include "archive_service.h"
#include <stdint.h>
#include <stdio.h>
#define MAX_INPUT (64UL * 1024 * 1024)
#define MAX_TEXT (8UL * 1024 * 1024)
#define MAX_RECORDS 4096
int hikari_error(const char *message);
void hikari_limits(void);
const char *hikari_preflight(FILE *file, size_t size, int extended);
const char *hikari_validate(const MOBIData *m, int extended);
int hikari_metadata(const MOBIData *m, size_t length, int extended, int nested);
int hikari_decode(MOBIData *m);
#endif
