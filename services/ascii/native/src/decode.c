/* Pinned stb handles decoding only; resizing, luminance and rendering are Rust. */
#include <stddef.h>
#include <stdlib.h>
#define STB_IMAGE_IMPLEMENTATION
#define STBI_NO_STDIO
#define STBI_NO_HDR
#define STBI_NO_LINEAR
#define STBI_ONLY_PNG
#define STBI_ONLY_JPEG
#define STBI_ONLY_BMP
#define STBI_ONLY_PNM
#define STBI_MAX_DIMENSIONS 8192
#include "stb_image.h"

unsigned char *wiz_image_decode(const unsigned char *bytes, int length, int *width, int *height) {
    int channels = 0, w = 0, h = 0;
    unsigned char *rgba;
    if (!stbi_info_from_memory(bytes, length, &w, &h, &channels) || w < 1 || h < 1 ||
        w > 8192 || h > 8192 || (size_t)w * (size_t)h > 16 * 1024 * 1024) return NULL;
    rgba = stbi_load_from_memory(bytes, length, width, height, &channels, 4);
    if (rgba && (*width != w || *height != h)) { stbi_image_free(rgba); return NULL; }
    return rgba;
}
void wiz_image_free(void *pixels) { stbi_image_free(pixels); }
