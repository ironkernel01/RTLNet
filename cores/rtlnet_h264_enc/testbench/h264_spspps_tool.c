/*
 * h264_spspps_tool.c -- host tool: write the SPS and PPS of a stream with the driver's writer
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: the harness (h264_harness.ps1) prepends this tool's output to the encoder's Annex B stream, so the
 * SPS and PPS decoded by JM, OpenH264 and FFmpeg are the bytes rtlnet_h264_enc_write_sps_pps() produces.
 * Usage: h264_spspps_tool <width> <height> <display_width> <display_height> <fps> <log2_max_frame_num> <out file> [high [t8]]
 *        h264_spspps_tool mode <0 = 720p30 | 1 = 1080p30> <log2_max_frame_num> <out file>   (sizes from the driver's mode table)
 * Exit codes: 0 written, 2 bad arguments, 1 the driver rejected the request or the file could not be written.
 *
 * Build (repository root; gcc from Resolve-RtlnetHostCc in scripts/rtlnet_tools.ps1):
 *   gcc -std=c11 -Wall -Wextra -Werror -DRTLNET_HOST_TEST -Icores/rtlnet_common/driver
 *       -Icores/rtlnet_h264_enc/driver cores/rtlnet_h264_enc/driver/rtlnet_h264_enc.c
 *       cores/rtlnet_h264_enc/testbench/h264_spspps_tool.c -o h264_spspps_tool.exe
 */
#include "rtlnet_h264_enc.h"
#include "rtlnet_mmio.h"

#include <stdio.h>    /* fopen, fwrite, fprintf */
#include <stdlib.h>   /* strtoul */
#include <string.h>   /* strcmp */

#define ARG_COUNT 8
#define ARG_COUNT_MODE 5

/* The tool never touches registers; the host-test hooks of rtlnet_mmio.h need a definition. */
uint32_t rtlnet_host_reg_read32(uintptr_t addr)
{
    (void)addr;
    return 0u;
}

void rtlnet_host_reg_write32(uintptr_t addr, uint32_t value)
{
    (void)addr;
    (void)value;
}

int main(int argc, char **argv)
{
    rtlnet_h264_enc_sps_cfg_t cfg;
    uint8_t buf[RTLNET_H264_SPS_PPS_MAX_BYTES];
    size_t  len = 0u;
    FILE   *f;
    int     high = 0;
    int     t8   = 0;

    const char *outname;

    /* Optional last arguments "high" or "high t8" select the High profile form of the parameter sets (t8: transform_8x8_mode_flag 1). */
    if ((argc > 2) && (strcmp(argv[argc - 1], "t8") == 0) && (strcmp(argv[argc - 2], "high") == 0)) {
        high = 1;
        t8   = 1;
        argc -= 2;
    } else if ((argc > 1) && (strcmp(argv[argc - 1], "high") == 0)) {
        high = 1;
        argc--;
    }
    if ((argc == ARG_COUNT_MODE) && (strcmp(argv[1], "mode") == 0)) {
        rtlnet_h264_enc_mode_t mode;

        if (rtlnet_h264_enc_get_mode((uint32_t)strtoul(argv[2], NULL, 10), &mode) != 0) {
            fprintf(stderr, "h264_spspps_tool: unknown mode %s\n", argv[2]);
            return 2;
        }
        cfg.width              = mode.width;
        cfg.height             = mode.height;
        cfg.display_width      = mode.display_width;
        cfg.display_height     = mode.display_height;
        cfg.fps                = mode.fps;
        cfg.log2_max_frame_num = (uint32_t)strtoul(argv[3], NULL, 10);
        outname                = argv[4];
    } else if (argc == ARG_COUNT) {
        cfg.width              = (uint32_t)strtoul(argv[1], NULL, 10);
        cfg.height             = (uint32_t)strtoul(argv[2], NULL, 10);
        cfg.display_width      = (uint32_t)strtoul(argv[3], NULL, 10);
        cfg.display_height     = (uint32_t)strtoul(argv[4], NULL, 10);
        cfg.fps                = (uint32_t)strtoul(argv[5], NULL, 10);
        cfg.log2_max_frame_num = (uint32_t)strtoul(argv[6], NULL, 10);
        outname                = argv[7];
    } else {
        fprintf(stderr, "usage: h264_spspps_tool w h display_w display_h fps log2_max_frame_num outfile | mode m log2 outfile\n");
        return 2;
    }
    if (rtlnet_h264_enc_write_sps_pps_tools(buf, sizeof(buf), &cfg, high, t8, &len) != 0) {
        fprintf(stderr, "h264_spspps_tool: rtlnet_h264_enc_write_sps_pps_tools rejected the request\n");
        return 1;
    }
    f = fopen(outname, "wb");
    if (f == NULL) {
        fprintf(stderr, "h264_spspps_tool: cannot open %s\n", outname);
        return 1;
    }
    if (fwrite(buf, 1u, len, f) != len) {
        fprintf(stderr, "h264_spspps_tool: short write to %s\n", outname);
        (void)fclose(f);
        return 1;
    }
    if (fclose(f) != 0) {
        return 1;
    }
    printf("h264_spspps_tool: %lu bytes\n", (unsigned long)len);
    return 0;
}
