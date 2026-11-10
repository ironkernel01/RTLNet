/*
 * csi2_bars_model.c -- host C model of the rtlnet_csi2_rx color-bar generator
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: the reference for the frame the bar generator sends and rtlnet_vdma_s2mm writes into a frame-buffer slot. It
 * implements documentation/gige.md section 5.4 directly and shares no code with the RTL, the bench or the firmware.
 *
 * Frame: eight vertical 75 percent color bars, full height, no moving content. Bar b covers pixels
 * [b * W / 8, (b + 1) * W / 8): 160 pixels at 720p, 240 at 1080p. Colors are the ITU-R BT.709 8-bit limited-range
 * values of the section 5.4 table. YUV422, two pixels per four bytes in memory order Y0 Cb Y1 Cr, both Y of a pair
 * equal (a bar edge is on an even pixel). Lines are packed (stride = W * 2 bytes).
 *
 * Output: one line per mode, "MODEL <mode> width=<W> height=<H> bytes=<n> crc32=0x<hex>", where crc32 is the
 * standard CRC-32 (IEEE 802.3 reflected, initial value and final XOR 0xFFFFFFFF, zlib crc32) of the whole frame.
 *   csi2_bars_model                     print both MODEL lines
 *   csi2_bars_model --dump <file> <720p30|1080p30>   write the frame bytes to a file
 *   csi2_bars_model --selftest          check the CRC engine: crc32("123456789") = 0xCBF43926
 * Exit code 0 on success, 1 on a bad argument, a failed self test or a file error.
 *
 * Build (host gcc from Resolve-RtlnetHostCc in scripts/rtlnet_tools.ps1):
 *   gcc -std=c11 -Wall -Wextra -Werror -pedantic -O2 csi2_bars_model.c -o csi2_bars_model
 *
 * Revision: 11-09-2026
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define BARS            8u
#define BYTES_PER_PIXEL 2u
#define CRC_POLY        0xEDB88320u
#define CRC_INIT        0xFFFFFFFFu
#define CRC_CHECK_VALUE 0xCBF43926u   /* crc32("123456789") */

typedef struct {
    const char *name;
    uint32_t    width;
    uint32_t    height;
} mode_t_;

static const mode_t_ g_modes[] = { { "720p30", 1280u, 720u }, { "1080p30", 1920u, 1080u } };
#define MODE_COUNT (sizeof(g_modes) / sizeof(g_modes[0]))

/* Y, Cb, Cr of white 75 %, yellow, cyan, green, magenta, red, blue, black (gige.md section 5.4). */
static const uint8_t g_bar[BARS][3] = {
    { 180u, 128u, 128u }, { 168u, 44u, 136u }, { 145u, 147u, 44u }, { 133u, 63u, 52u },
    { 63u, 193u, 204u }, { 51u, 109u, 212u }, { 28u, 212u, 120u }, { 16u, 128u, 128u }
};

/* crc32_update -- bitwise reflected CRC-32 register update over a byte buffer. */
static uint32_t crc32_update(uint32_t crc, const uint8_t *buf, size_t n)
{
    for (size_t i = 0; i < n; i++) {
        crc ^= buf[i];
        for (unsigned b = 0; b < 8u; b++) {
            crc = ((crc & 1u) != 0u) ? ((crc >> 1) ^ CRC_POLY) : (crc >> 1);
        }
    }
    return crc;
}

/* build_line -- one frame line in memory order (all lines of a frame are identical). */
static void build_line(const mode_t_ *m, uint8_t *line)
{
    uint32_t bar_px = m->width / BARS;
    for (uint32_t x = 0; x < m->width; x += 2u) {
        uint32_t b = x / bar_px;
        line[x * BYTES_PER_PIXEL + 0u] = g_bar[b][0];   /* Y0 */
        line[x * BYTES_PER_PIXEL + 1u] = g_bar[b][1];   /* Cb */
        line[x * BYTES_PER_PIXEL + 2u] = g_bar[b][0];   /* Y1 */
        line[x * BYTES_PER_PIXEL + 3u] = g_bar[b][2];   /* Cr */
    }
}

/* frame_crc -- CRC-32 of the whole frame of a mode. Returns 0 on success. */
static int frame_crc(const mode_t_ *m, uint32_t *crc_out)
{
    uint8_t *line = (uint8_t *)malloc((size_t)m->width * BYTES_PER_PIXEL);
    uint32_t crc = CRC_INIT;
    if (line == NULL) {
        return 1;
    }
    build_line(m, line);
    for (uint32_t y = 0; y < m->height; y++) {
        crc = crc32_update(crc, line, (size_t)m->width * BYTES_PER_PIXEL);
    }
    free(line);
    *crc_out = ~crc;
    return 0;
}

/* find_mode -- mode of a name, NULL when unknown. */
static const mode_t_ *find_mode(const char *name)
{
    for (size_t i = 0; i < MODE_COUNT; i++) {
        if (strcmp(name, g_modes[i].name) == 0) {
            return &g_modes[i];
        }
    }
    return NULL;
}

int main(int argc, char **argv)
{
    if (argc == 2 && strcmp(argv[1], "--selftest") == 0) {
        static const uint8_t check[] = { '1', '2', '3', '4', '5', '6', '7', '8', '9' };
        uint32_t crc = ~crc32_update(CRC_INIT, check, sizeof(check));
        printf("SELFTEST crc32(\"123456789\")=0x%08X %s\n", (unsigned)crc, (crc == CRC_CHECK_VALUE) ? "PASS" : "FAIL");
        return (crc == CRC_CHECK_VALUE) ? 0 : 1;
    }
    if (argc == 4 && strcmp(argv[1], "--dump") == 0) {
        const mode_t_ *m = find_mode(argv[3]);
        FILE *f;
        uint8_t *line;
        if (m == NULL) {
            fprintf(stderr, "unknown mode \"%s\" (720p30 or 1080p30)\n", argv[3]);
            return 1;
        }
        f = fopen(argv[2], "wb");
        line = (uint8_t *)malloc((size_t)m->width * BYTES_PER_PIXEL);
        if (f == NULL || line == NULL) {
            fprintf(stderr, "cannot write \"%s\"\n", argv[2]);
            if (f != NULL) {
                (void)fclose(f);
            }
            free(line);
            return 1;
        }
        build_line(m, line);
        for (uint32_t y = 0; y < m->height; y++) {
            if (fwrite(line, 1u, (size_t)m->width * BYTES_PER_PIXEL, f) != (size_t)m->width * BYTES_PER_PIXEL) {
                (void)fclose(f);
                free(line);
                return 1;
            }
        }
        free(line);
        return (fclose(f) == 0) ? 0 : 1;
    }
    if (argc != 1) {
        fprintf(stderr, "usage: csi2_bars_model [--selftest | --dump <file> <720p30|1080p30>]\n");
        return 1;
    }
    for (size_t i = 0; i < MODE_COUNT; i++) {
        uint32_t crc;
        if (frame_crc(&g_modes[i], &crc) != 0) {
            return 1;
        }
        printf("MODEL %s width=%u height=%u bytes=%u crc32=0x%08X\n", g_modes[i].name, (unsigned)g_modes[i].width,
               (unsigned)g_modes[i].height, (unsigned)(g_modes[i].width * g_modes[i].height * BYTES_PER_PIXEL), (unsigned)crc);
    }
    return 0;
}
