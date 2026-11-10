/*
 * test_rtlnet_h264_enc_driver.c -- host unit test of the H.264 encoder driver
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: runs driver/rtlnet_h264_enc.c on the PC against a register model (ID/VERSION/CAPS, the configuration
 * registers read back as written, self-clearing START, write-1-to-clear DONE and ERR) through the
 * RTLNET_HOST_TEST hooks of rtlnet_mmio.h, and checks the SPS and PPS bytes of rtlnet_h264_enc_write_sps_pps()
 * with an independent bit reader written here from ITU-T Rec. H.264 clauses 7.3.2.1.1, 7.3.2.2 and 7.4.1:
 * field values, emulation prevention, level selection and cropping for QCIF, 720p and 1080p (coded 1088).
 * Phase 2c-1 adds the P picture fields: PIC_CFG bit 1 (start_picture_ex, the earlier start clears it), REF_Y_BASE / REF_U_BASE and
 * their alignment, frame_num wrap, the two-buffer helper (alternation, reference choice, no P without a reference).
 * Prints one line "DRIVER TEST PASS: rtlnet_h264_enc checks=<n>" or "DRIVER TEST FAIL: ..." and returns 0 / 1.
 * The decoders (JM, OpenH264, FFmpeg) decode the same bytes in the harness.
 *
 * Build and run (repository root; gcc from Resolve-RtlnetHostCc in scripts/rtlnet_tools.ps1):
 *   gcc -std=c11 -Wall -Wextra -Werror -DRTLNET_HOST_TEST -Icores/rtlnet_common/driver
 *       -Icores/rtlnet_h264_enc/driver cores/rtlnet_h264_enc/driver/rtlnet_h264_enc.c
 *       cores/rtlnet_h264_enc/testbench/test_rtlnet_h264_enc_driver.c -o test_h264 && ./test_h264
 */
#include "rtlnet_h264_enc.h"
#include "rtlnet_mmio.h"

#include <stdio.h>    /* printf */
#include <string.h>   /* memset */

#define TEST_BASE     0x44A10000u
#define TEST_WINDOW   0x1000u
#define MODEL_CAPS    0x00024478u   /* MAX_MB_W 120, MAX_MB_H 68, 2 engines */

static uint32_t g_reg[TEST_WINDOW / 4u];
static int      g_checks;
static int      g_fails;

static void check(int cond, const char *what)
{
    g_checks++;
    if (!cond) {
        g_fails++;
        printf("CHECK FAILED: %s\n", what);
    }
}

uint32_t rtlnet_host_reg_read32(uintptr_t addr)
{
    uint32_t off = (uint32_t)(addr - TEST_BASE);

    if ((addr < TEST_BASE) || (off >= TEST_WINDOW) || ((off & 3u) != 0u)) {
        g_fails++;
        printf("CHECK FAILED: register read outside the window 0x%lx\n", (unsigned long)addr);
        return 0u;
    }
    return g_reg[off / 4u];
}

void rtlnet_host_reg_write32(uintptr_t addr, uint32_t value)
{
    uint32_t off = (uint32_t)(addr - TEST_BASE);

    if ((addr < TEST_BASE) || (off >= TEST_WINDOW) || ((off & 3u) != 0u)) {
        g_fails++;
        printf("CHECK FAILED: register write outside the window 0x%lx\n", (unsigned long)addr);
        return;
    }
    if (off == RTLNET_H264_REG_STATUS) {
        g_reg[off / 4u] &= ~(value & (RTLNET_H264_STATUS_DONE | RTLNET_H264_STATUS_ERR));
        return;
    }
    if (off == RTLNET_H264_REG_CTRL) {
        g_reg[off / 4u] = value & RTLNET_H264_CTRL_IRQ_EN;   /* START and RING_RESET self-clear */
        g_reg[0x0F0u / 4u] = value;                           /* last CTRL write, for the checks */
        return;
    }
    g_reg[off / 4u] = value;
}

/* Independent bit reader over an RBSP with the emulation-prevention bytes removed. */
typedef struct {
    uint8_t  data[128];
    uint32_t len;
    uint32_t pos;
} rd_t;

static uint32_t rd_bits(rd_t *r, uint32_t n)
{
    uint32_t v = 0u;
    uint32_t i;

    for (i = 0u; i < n; i++) {
        v = (v << 1) | (uint32_t)((r->data[r->pos / 8u] >> (7u - (r->pos % 8u))) & 1u);
        r->pos++;
    }
    return v;
}

static uint32_t rd_ue(rd_t *r)
{
    uint32_t zeros = 0u;

    while (rd_bits(r, 1u) == 0u) {
        zeros++;
    }
    return (1u << zeros) - 1u + rd_bits(r, zeros);
}

/* Split Annex B: returns the NAL start (after the 4-byte start code) and removes emulation prevention. */
static uint32_t unwrap_nal(const uint8_t *buf, uint32_t start, uint32_t end, rd_t *r, uint32_t *next)
{
    uint32_t i = start + 4u;
    uint32_t zeros = 0u;
    uint32_t header;

    check((buf[start] == 0u) && (buf[start + 1u] == 0u) && (buf[start + 2u] == 0u) && (buf[start + 3u] == 1u),
          "start code 00 00 00 01");
    header = buf[i++];
    r->len = 0u;
    r->pos = 0u;
    while (i < end) {
        if ((buf[i] == 0u) && (buf[i + 1u] == 0u) && (i + 3u < end) && (buf[i + 2u] == 0u) && (buf[i + 3u] == 1u)) {
            break;   /* next start code */
        }
        if ((zeros >= 2u) && (buf[i] == 3u)) {
            zeros = 0u;
            i++;
            continue;
        }
        zeros = (buf[i] == 0u) ? (zeros + 1u) : 0u;
        r->data[r->len++] = buf[i++];
    }
    *next = i;
    return header;
}

static void check_sps_pps(const rtlnet_h264_enc_sps_cfg_t *cfg, uint32_t exp_level, uint32_t exp_crop_b, const char *name)
{
    uint8_t  buf[RTLNET_H264_SPS_PPS_MAX_BYTES];
    size_t   len = 0u;
    rd_t     r;
    uint32_t next, hdr, v;

    check(rtlnet_h264_enc_write_sps_pps(buf, sizeof(buf), cfg, &len) == 0, name);
    check(len > 0u, "length");
    hdr = unwrap_nal(buf, 0u, (uint32_t)len, &r, &next);
    check(hdr == 0x67u, "SPS NAL header 0x67");
    check(rd_bits(&r, 8u) == 66u, "profile_idc 66");
    check(rd_bits(&r, 1u) == 0u, "constraint_set0_flag");
    check(rd_bits(&r, 1u) == 1u, "constraint_set1_flag");
    check(rd_bits(&r, 2u) == 0u, "constraint_set2/3_flag");
    check(rd_bits(&r, 4u) == 0u, "reserved_zero_4bits");
    v = rd_bits(&r, 8u);
    check(v == exp_level, "level_idc");
    check(rd_ue(&r) == 0u, "seq_parameter_set_id");
    check(rd_ue(&r) == (cfg->log2_max_frame_num - 4u), "log2_max_frame_num_minus4");
    check(rd_ue(&r) == 2u, "pic_order_cnt_type 2");
    check(rd_ue(&r) == 1u, "max_num_ref_frames 1");
    check(rd_bits(&r, 1u) == 0u, "gaps_in_frame_num_value_allowed_flag");
    check(rd_ue(&r) == (cfg->width / 16u - 1u), "pic_width_in_mbs_minus1");
    check(rd_ue(&r) == (cfg->height / 16u - 1u), "pic_height_in_map_units_minus1");
    check(rd_bits(&r, 1u) == 1u, "frame_mbs_only_flag");
    check(rd_bits(&r, 1u) == 1u, "direct_8x8_inference_flag");
    if (exp_crop_b != 0u) {
        check(rd_bits(&r, 1u) == 1u, "frame_cropping_flag");
        check(rd_ue(&r) == 0u, "crop left");
        check(rd_ue(&r) == 0u, "crop right");
        check(rd_ue(&r) == 0u, "crop top");
        check(rd_ue(&r) == exp_crop_b, "crop bottom");
    } else {
        check(rd_bits(&r, 1u) == 0u, "frame_cropping_flag 0");
    }
    check(rd_bits(&r, 1u) == 0u, "vui_parameters_present_flag");
    check(rd_bits(&r, 1u) == 1u, "SPS stop bit");

    hdr = unwrap_nal(buf, next, (uint32_t)len, &r, &next);
    check(hdr == 0x68u, "PPS NAL header 0x68");
    check(rd_ue(&r) == 0u, "pic_parameter_set_id");
    check(rd_ue(&r) == 0u, "PPS seq_parameter_set_id");
    check(rd_bits(&r, 1u) == 0u, "entropy_coding_mode_flag 0 (CAVLC)");
    check(rd_bits(&r, 1u) == 0u, "bottom_field_pic_order_in_frame_present_flag");
    check(rd_ue(&r) == 0u, "num_slice_groups_minus1");
    check(rd_ue(&r) == 0u, "num_ref_idx_l0_default_active_minus1");
    check(rd_ue(&r) == 0u, "num_ref_idx_l1_default_active_minus1");
    check(rd_bits(&r, 1u) == 0u, "weighted_pred_flag");
    check(rd_bits(&r, 2u) == 0u, "weighted_bipred_idc");
    check(rd_ue(&r) == 0u, "pic_init_qp_minus26 = 0 (pic_init_qp 26)");
    check(rd_ue(&r) == 0u, "pic_init_qs_minus26");
    check(rd_ue(&r) == 0u, "chroma_qp_index_offset");
    check(rd_bits(&r, 1u) == 1u, "deblocking_filter_control_present_flag");
    check(rd_bits(&r, 1u) == 0u, "constrained_intra_pred_flag");
    check(rd_bits(&r, 1u) == 0u, "redundant_pic_cnt_present_flag");
    check(rd_bits(&r, 1u) == 1u, "PPS stop bit");
    check(next == (uint32_t)len, "PPS ends the output");
}

int main(void)
{
    rtlnet_h264_enc_sps_cfg_t sps;
    rtlnet_h264_enc_caps_t caps;
    rtlnet_h264_enc_cfg_t cfg;
    rtlnet_h264_enc_index_entry_t ent;
    rtlnet_h264_enc_stats_t stats;
    uint32_t words[4];
    uint32_t err = 0u;
    uint8_t  small[8];
    size_t   len = 0u;

    /* SPS and PPS bytes. */
    sps.width = 176u; sps.height = 144u; sps.display_width = 176u; sps.display_height = 144u;
    sps.fps = 30u; sps.log2_max_frame_num = 4u;
    check_sps_pps(&sps, 11u, 0u, "QCIF");
    sps.width = 1280u; sps.height = 720u; sps.display_width = 1280u; sps.display_height = 720u;
    check_sps_pps(&sps, 31u, 0u, "720p30");
    sps.width = 1920u; sps.height = 1088u; sps.display_width = 1920u; sps.display_height = 1080u;
    sps.log2_max_frame_num = 8u;
    check_sps_pps(&sps, 40u, 4u, "1080p30");
    sps.fps = 60u;
    check_sps_pps(&sps, 42u, 4u, "1080p60");
    sps.width = 3840u; sps.height = 2160u; sps.display_width = 3840u; sps.display_height = 2160u; sps.fps = 30u;
    check_sps_pps(&sps, 51u, 0u, "4K30");
    sps.height = 2176u;
    sps.display_height = 2160u;
    check_sps_pps(&sps, 51u, 8u, "4K30 coded 2176");

    /* Rejections. */
    sps.width = 1920u; sps.height = 1088u; sps.display_width = 1920u; sps.display_height = 1080u; sps.fps = 30u;
    sps.log2_max_frame_num = 17u;
    check(rtlnet_h264_enc_write_sps_pps(small, sizeof(small), &sps, &len) != 0, "log2_max_frame_num 17 rejected");
    sps.log2_max_frame_num = 8u;
    check(rtlnet_h264_enc_write_sps_pps(small, sizeof(small), &sps, &len) != 0, "buffer too small rejected");
    sps.display_height = 1090u;
    check(rtlnet_h264_enc_write_sps_pps(small, 64u, &sps, &len) != 0, "crop beyond the picture rejected");
    sps.display_height = 1080u;
    sps.width = 1921u;
    check(rtlnet_h264_enc_write_sps_pps(small, 64u, &sps, &len) != 0, "width not a macroblock multiple rejected");
    sps.width = 8192u; sps.height = 8192u; sps.display_width = 8192u; sps.display_height = 8192u;
    check(rtlnet_h264_enc_write_sps_pps(small, 64u, &sps, &len) != 0, "level above 5.2 rejected");

    /* Register access. */
    memset(g_reg, 0, sizeof(g_reg));
    check(rtlnet_h264_enc_probe(TEST_BASE, &caps) != 0, "probe rejects an unidentified core");
    g_reg[RTLNET_REG_ID / 4u] = RTLNET_H264_ID_VALUE;
    g_reg[RTLNET_REG_VERSION / 4u] = RTLNET_H264_VERSION_VALUE;
    g_reg[RTLNET_REG_CAPS / 4u] = MODEL_CAPS;
    check(rtlnet_h264_enc_probe(TEST_BASE, &caps) == 0, "probe");
    check((caps.max_mb_w == 120u) && (caps.max_mb_h == 68u) && (caps.num_engines == 2u), "caps decode");

    /* Video modes: 720p30 default, 1080p30; band split of two engines. */
    {
        rtlnet_h264_enc_mode_t m;
        rtlnet_h264_enc_sps_cfg_t ms;
        uint32_t f0, r0, f1, r1;

        check((rtlnet_h264_enc_get_mode(RTLNET_H264_MODE_DEFAULT, &m) == 0) && (m.mb_w == 80u) && (m.mb_h == 45u) &&
              (m.display_height == 720u) && (m.level_idc == 31u), "720p30 mode");
        check((rtlnet_h264_enc_get_mode(RTLNET_H264_MODE_1080P30, &m) == 0) && (m.mb_w == 120u) && (m.mb_h == 68u) &&
              (m.height == 1088u) && (m.display_height == 1080u) && (m.level_idc == 40u), "1080p30 mode");
        check(rtlnet_h264_enc_get_mode(2u, &m) != 0, "unknown mode rejected");
        check((rtlnet_h264_enc_band_rows(45u, 2u, 0u, &f0, &r0) == 0) && (rtlnet_h264_enc_band_rows(45u, 2u, 1u, &f1, &r1) == 0) &&
              (f0 == 0u) && (r0 == 23u) && (f1 == 23u) && (r1 == 22u), "720p bands 23 and 22");
        check((rtlnet_h264_enc_band_rows(68u, 2u, 0u, &f0, &r0) == 0) && (rtlnet_h264_enc_band_rows(68u, 2u, 1u, &f1, &r1) == 0) &&
              (f0 == 0u) && (r0 == 34u) && (f1 == 34u) && (r1 == 34u), "1080p bands 34 and 34");
        check(rtlnet_h264_enc_band_rows(1u, 2u, 1u, &f1, &r1) != 0, "empty band rejected");
        check(rtlnet_h264_enc_set_mode(TEST_BASE, RTLNET_H264_MODE_DEFAULT, &ms) == 0, "set_mode 720p30");
        check((g_reg[RTLNET_H264_REG_MB_W / 4u] == 80u) && (g_reg[RTLNET_H264_REG_MB_H / 4u] == 45u), "720p MB_W and MB_H written");
        check((ms.width == 1280u) && (ms.height == 720u) && (ms.display_height == 720u) && (ms.log2_max_frame_num == 4u),
              "720p SPS parameters");
        check_sps_pps(&ms, 31u, 0u, "720p30 SPS from the mode");
        check(rtlnet_h264_enc_set_mode(TEST_BASE, RTLNET_H264_MODE_1080P30, &ms) == 0, "set_mode 1080p30");
        check((g_reg[RTLNET_H264_REG_MB_W / 4u] == 120u) && (g_reg[RTLNET_H264_REG_MB_H / 4u] == 68u), "1080p MB_W and MB_H written");
        check_sps_pps(&ms, 40u, 4u, "1080p30 SPS from the mode (crop_bottom 4)");
        check(rtlnet_h264_enc_set_mode(TEST_BASE, 5u, &ms) != 0, "set_mode rejects an unknown mode");
    }


    memset(&cfg, 0, sizeof(cfg));
    cfg.mb_w = 11u; cfg.mb_h = 9u; cfg.slices = 3u; cfg.qp = 26u; cfg.log2_max_frame_num = 4u;
    cfg.in_base = 0u; cfg.in_stride = 384u; cfg.ry_base = 0x10000u;
    cfg.ru_base = 0x20000u;
    cfg.ring_base = 0x40000u; cfg.ring_size = 0x8000u; cfg.idx_base = 0x50000u; cfg.idx_entries = 64u;
    check(rtlnet_h264_enc_configure(TEST_BASE, &cfg) == 0, "configure");
    check(g_reg[RTLNET_H264_REG_MB_W / 4u] == 11u, "MB_W written");
    check(g_reg[RTLNET_H264_REG_SLICES / 4u] == 3u, "SLICES written");
    check(g_reg[RTLNET_H264_REG_RY_BASE / 4u] == 0x10000u, "RY_BASE (luma tile base) written");
    check(g_reg[RTLNET_H264_REG_RU_BASE / 4u] == 0x20000u, "RU_BASE (chroma tile base) written");
    cfg.in_stride = 352u;
    check(rtlnet_h264_enc_configure(TEST_BASE, &cfg) != 0, "configure rejects an input stride that is not a multiple of 128");
    cfg.in_stride = 384u; cfg.ry_base = 0x10080u;
    check(rtlnet_h264_enc_configure(TEST_BASE, &cfg) != 0, "configure rejects a luma tile base that is not a multiple of 256");
    cfg.ry_base = 0x10000u; cfg.idx_base = 0x50010u;
    check(rtlnet_h264_enc_configure(TEST_BASE, &cfg) != 0, "configure rejects an index base that is not a multiple of 128");
    cfg.idx_base = 0x50000u;
    check(g_reg[RTLNET_H264_REG_IDX_ENTRIES / 4u] == 64u, "IDX_ENTRIES written");
    check(g_reg[RTLNET_H264_REG_QP / 4u] == 26u, "QP written");
    check(g_reg[RTLNET_H264_REG_MB_MODE / 4u] == 0u, "MB_MODE 0 (Intra16x16) by default");
    cfg.qp = 5u;
    check(rtlnet_h264_enc_configure(TEST_BASE, &cfg) == 0, "configure with QP 5");
    check(g_reg[RTLNET_H264_REG_QP / 4u] == RTLNET_H264_QP_MIN_REALTIME, "QP 5 clamped to the real-time minimum");
    cfg.qp = RTLNET_H264_QP_MIN_REALTIME;
    check(rtlnet_h264_enc_configure(TEST_BASE, &cfg) == 0, "configure with the minimum QP");
    check(g_reg[RTLNET_H264_REG_QP / 4u] == RTLNET_H264_QP_MIN_REALTIME, "minimum QP written as is");
    cfg.qp = 51u;
    check(rtlnet_h264_enc_configure(TEST_BASE, &cfg) == 0, "configure with QP 51");
    check(g_reg[RTLNET_H264_REG_QP / 4u] == 51u, "QP 51 written as is");
    cfg.qp = 26u;
    check(rtlnet_h264_enc_configure(TEST_BASE, &cfg) == 0, "configure with QP 26 again");
    cfg.mb_pcm = 1u;
    check(rtlnet_h264_enc_configure(TEST_BASE, &cfg) == 0, "configure with mb_pcm");
    check(g_reg[RTLNET_H264_REG_MB_MODE / 4u] == 1u, "MB_MODE 1 (I_PCM) written");
    cfg.mb_pcm = 0u;
    check(rtlnet_h264_enc_configure(TEST_BASE, &cfg) == 0, "configure back to Intra16x16");
    check(g_reg[RTLNET_H264_REG_MB_MODE / 4u] == 0u, "MB_MODE cleared");
    cfg.mb_w = 121u;
    check(rtlnet_h264_enc_configure(TEST_BASE, &cfg) != 0, "picture wider than the build rejected");
    check(g_reg[RTLNET_H264_REG_MB_W / 4u] == 11u, "rejected configure writes nothing");
    cfg.mb_w = 11u; cfg.in_stride = 336u;
    check(rtlnet_h264_enc_configure(TEST_BASE, &cfg) != 0, "input stride below the picture width rejected");
    cfg.in_stride = 352u; cfg.slices = 10u;
    check(rtlnet_h264_enc_configure(TEST_BASE, &cfg) != 0, "more slices than rows rejected");

    rtlnet_h264_enc_ring_reset(TEST_BASE);
    check((g_reg[0x0F0u / 4u] & RTLNET_H264_CTRL_RING_RESET) != 0u, "ring reset strobe written");
    check(rtlnet_h264_enc_start_picture(TEST_BASE, 0u, 1u, 1) == 0, "start picture");
    check((g_reg[0x0F0u / 4u] & RTLNET_H264_CTRL_START) != 0u, "START written");
    check(g_reg[RTLNET_H264_REG_IDR_PIC_ID / 4u] == 1u, "idr_pic_id written");
    check((g_reg[RTLNET_H264_REG_PIC_CFG / 4u] & RTLNET_H264_PIC_CFG_IDR) != 0u, "IDR flag set");
    check(((g_reg[RTLNET_H264_REG_PIC_CFG / 4u] >> 8) & 0x1Fu) == 4u, "log2_max_frame_num kept");
    g_reg[RTLNET_H264_REG_STATUS / 4u] = RTLNET_H264_STATUS_BUSY;
    check(rtlnet_h264_enc_start_picture(TEST_BASE, 0u, 2u, 1) != 0, "start while busy rejected");
    g_reg[RTLNET_H264_REG_STATUS / 4u] = RTLNET_H264_STATUS_DONE;
    check(rtlnet_h264_enc_wait_done(TEST_BASE, 3u, &err) == 0, "wait_done on DONE");
    g_reg[RTLNET_H264_REG_STATUS / 4u] = RTLNET_H264_STATUS_ERR;
    g_reg[RTLNET_H264_REG_ERR_CODE / 4u] = RTLNET_H264_ERR_CONFIG;
    check((rtlnet_h264_enc_wait_done(TEST_BASE, 3u, &err) != 0) && (err == RTLNET_H264_ERR_CONFIG), "wait_done on ERR");
    rtlnet_h264_enc_clear_status(TEST_BASE);
    check(rtlnet_h264_enc_status(TEST_BASE) == 0u, "DONE and ERR cleared");
    check((rtlnet_h264_enc_wait_done(TEST_BASE, 3u, &err) != 0) && (err == 0xFFu), "wait_done timeout");
    rtlnet_h264_enc_set_read_pointers(TEST_BASE, 0x1230u, 5u);
    check((g_reg[RTLNET_H264_REG_RING_RPTR / 4u] == 0x1230u) && (g_reg[RTLNET_H264_REG_IDX_RPTR / 4u] == 5u), "read pointers");
    g_reg[RTLNET_H264_REG_IDX_WPTR / 4u] = 7u;
    check(rtlnet_h264_enc_index_wptr(TEST_BASE) == 7u, "index wptr");

    words[0] = 0x100u; words[1] = 0x2345u; words[2] = (2u << 16) | 3u;
    words[3] = 7u | (26u << 8) | RTLNET_H264_IDX_LAST | RTLNET_H264_IDX_IDR;
    rtlnet_h264_enc_decode_index_entry(words, &ent);
    check((ent.offset == 0x100u) && (ent.length == 0x2345u) && (ent.picture == 3u) && (ent.slice == 2u) &&
          (ent.slice_type == 7u) && (ent.qp == 26u) && ent.last_slice && ent.idr && !ent.is_picture, "slice entry decode");
    words[3] |= RTLNET_H264_IDX_KIND_PICTURE;
    rtlnet_h264_enc_decode_index_entry(words, &ent);
    check(ent.is_picture, "picture entry decode");

    g_reg[RTLNET_H264_REG_MB_COUNT / 4u] = 99u; g_reg[RTLNET_H264_REG_CYC_MAX / 4u] = 391u;
    rtlnet_h264_enc_read_stats(TEST_BASE, &stats);
    check((stats.mb_count == 99u) && (stats.cyc_max == 391u), "stats");

    /* P pictures (phase 2c-1): PIC_CFG bit 1, the reference registers, frame_num, the two-buffer helper. */
    {
        rtlnet_h264_enc_buffers_t bufs;

        check(RTLNET_H264_VERSION_VALUE == 0x11102C01u, "VERSION of phase 2c-1");
        check((RTLNET_H264_REG_REFY_BASE == 0x054u) && (RTLNET_H264_REG_REFU_BASE == 0x058u), "reference register offsets");
        g_reg[RTLNET_H264_REG_STATUS / 4u] = 0u;
        g_reg[RTLNET_H264_REG_PIC_CFG / 4u] = (4u << RTLNET_H264_PIC_CFG_LOG2FN_SHIFT) | RTLNET_H264_PIC_CFG_IDR;
        check(rtlnet_h264_enc_start_picture_ex(TEST_BASE, 5u, 9u, RTLNET_H264_PIC_P) == 0, "start P picture");
        check((g_reg[RTLNET_H264_REG_PIC_CFG / 4u] & RTLNET_H264_PIC_CFG_P) != 0u, "P flag set");
        check((g_reg[RTLNET_H264_REG_PIC_CFG / 4u] & RTLNET_H264_PIC_CFG_IDR) == 0u, "IDR flag cleared for a P picture");
        check(((g_reg[RTLNET_H264_REG_PIC_CFG / 4u] >> RTLNET_H264_PIC_CFG_LOG2FN_SHIFT) & 0x1Fu) == 4u, "log2_max_frame_num kept by a P start");
        check(g_reg[RTLNET_H264_REG_FRAME_NUM / 4u] == 5u, "P frame_num written");
        check(g_reg[RTLNET_H264_REG_IDR_PIC_ID / 4u] == 0u, "idr_pic_id 0 for a P picture");
        check((g_reg[0x0F0u / 4u] & RTLNET_H264_CTRL_START) != 0u, "START written for a P picture");
        check(rtlnet_h264_enc_start_picture_ex(TEST_BASE, 16u, 0u, RTLNET_H264_PIC_P) != 0, "P frame_num beyond log2_max_frame_num rejected");
        check(rtlnet_h264_enc_start_picture_ex(TEST_BASE, 1u, 0u, 7u) != 0, "unknown picture type rejected");
        g_reg[RTLNET_H264_REG_STATUS / 4u] = RTLNET_H264_STATUS_BUSY;
        check(rtlnet_h264_enc_start_picture_ex(TEST_BASE, 1u, 0u, RTLNET_H264_PIC_P) != 0, "P start while busy rejected");
        g_reg[RTLNET_H264_REG_STATUS / 4u] = 0u;
        check(rtlnet_h264_enc_start_picture_ex(TEST_BASE, 3u, 4u, RTLNET_H264_PIC_IDR) == 0, "start IDR picture with the extended start");
        check(((g_reg[RTLNET_H264_REG_PIC_CFG / 4u] & RTLNET_H264_PIC_CFG_IDR) != 0u) &&
              ((g_reg[RTLNET_H264_REG_PIC_CFG / 4u] & RTLNET_H264_PIC_CFG_P) == 0u), "IDR flag set, P flag cleared");
        check((g_reg[RTLNET_H264_REG_FRAME_NUM / 4u] == 0u) && (g_reg[RTLNET_H264_REG_IDR_PIC_ID / 4u] == 4u), "IDR: frame_num 0, idr_pic_id written");
        g_reg[RTLNET_H264_REG_PIC_CFG / 4u] |= RTLNET_H264_PIC_CFG_P;
        check(rtlnet_h264_enc_start_picture(TEST_BASE, 0u, 1u, 1) == 0, "the earlier start still works");
        check((g_reg[RTLNET_H264_REG_PIC_CFG / 4u] & RTLNET_H264_PIC_CFG_P) == 0u, "the earlier start clears the P flag");

        check(rtlnet_h264_enc_next_frame_num(0u, 4u) == 1u, "next frame_num after the IDR picture");
        check(rtlnet_h264_enc_next_frame_num(14u, 4u) == 15u, "next frame_num below the wrap");
        check(rtlnet_h264_enc_next_frame_num(15u, 4u) == 0u, "frame_num wraps at 2^log2_max_frame_num (16)");
        check(rtlnet_h264_enc_next_frame_num(0xFFFFu, 16u) == 0u, "frame_num wraps at 65536");
        check(rtlnet_h264_enc_next_frame_num(3u, 3u) == 0u, "log2_max_frame_num 3 rejected (0)");
        check(rtlnet_h264_enc_next_frame_num(3u, 17u) == 0u, "log2_max_frame_num 17 rejected (0)");

        g_reg[RTLNET_H264_REG_REFY_BASE / 4u] = 0xAAAAu;
        check(rtlnet_h264_enc_set_reference(TEST_BASE, 0x30080u, 0x40000u) != 0, "luma reference base not a multiple of 256 rejected");
        check(rtlnet_h264_enc_set_reference(TEST_BASE, 0x30000u, 0x40040u) != 0, "chroma reference base not a multiple of 128 rejected");
        check(g_reg[RTLNET_H264_REG_REFY_BASE / 4u] == 0xAAAAu, "a rejected reference writes nothing");
        check(rtlnet_h264_enc_set_reference(TEST_BASE, 0x30100u, 0x40080u) == 0, "set_reference");
        check((g_reg[RTLNET_H264_REG_REFY_BASE / 4u] == 0x30100u) && (g_reg[RTLNET_H264_REG_REFU_BASE / 4u] == 0x40080u), "reference bases written");

        check(rtlnet_h264_enc_buffers_init(&bufs, 0x10000u, 0x20000u, 0x10080u, 0x20000u) != 0, "buffer init rejects a misaligned luma base");
        check(rtlnet_h264_enc_buffers_init(&bufs, 0x10000u, 0x20000u, 0x50000u, 0x60040u) != 0, "buffer init rejects a misaligned chroma base");
        check(rtlnet_h264_enc_buffers_init(&bufs, 0x10000u, 0x20000u, 0x50000u, 0x60000u) == 0, "buffer init");
        g_reg[RTLNET_H264_REG_RY_BASE / 4u] = 0x1111u; g_reg[RTLNET_H264_REG_REFY_BASE / 4u] = 0x2222u;
        check(rtlnet_h264_enc_buffers_begin(TEST_BASE, &bufs, RTLNET_H264_PIC_P) != 0, "a P picture without a reference is rejected");
        check((g_reg[RTLNET_H264_REG_RY_BASE / 4u] == 0x1111u) && (g_reg[RTLNET_H264_REG_REFY_BASE / 4u] == 0x2222u), "a rejected begin writes nothing");
        check(rtlnet_h264_enc_buffers_begin(TEST_BASE, &bufs, RTLNET_H264_PIC_IDR) == 0, "begin the first (IDR) picture");
        check((g_reg[RTLNET_H264_REG_RY_BASE / 4u] == 0x10000u) && (g_reg[RTLNET_H264_REG_RU_BASE / 4u] == 0x20000u), "picture 0 writes buffer 0");
        check(g_reg[RTLNET_H264_REG_REFY_BASE / 4u] == 0x2222u, "an IDR picture leaves the reference registers alone");
        rtlnet_h264_enc_buffers_end(&bufs);
        check(rtlnet_h264_enc_buffers_begin(TEST_BASE, &bufs, RTLNET_H264_PIC_P) == 0, "begin the first P picture");
        check((g_reg[RTLNET_H264_REG_RY_BASE / 4u] == 0x50000u) && (g_reg[RTLNET_H264_REG_RU_BASE / 4u] == 0x60000u), "picture 1 writes buffer 1");
        check((g_reg[RTLNET_H264_REG_REFY_BASE / 4u] == 0x10000u) && (g_reg[RTLNET_H264_REG_REFU_BASE / 4u] == 0x20000u), "picture 1 reads buffer 0");
        rtlnet_h264_enc_buffers_end(&bufs);
        check(rtlnet_h264_enc_buffers_begin(TEST_BASE, &bufs, RTLNET_H264_PIC_P) == 0, "begin the second P picture");
        check((g_reg[RTLNET_H264_REG_RY_BASE / 4u] == 0x10000u) && (g_reg[RTLNET_H264_REG_REFY_BASE / 4u] == 0x50000u) &&
              (g_reg[RTLNET_H264_REG_REFU_BASE / 4u] == 0x60000u), "picture 2 writes buffer 0 and reads buffer 1");
        check(rtlnet_h264_enc_buffers_begin(TEST_BASE, &bufs, 9u) != 0, "unknown type rejected by the buffer helper");
        check(rtlnet_h264_enc_buffers_begin(TEST_BASE, NULL, RTLNET_H264_PIC_P) != 0, "NULL buffers rejected");
        rtlnet_h264_enc_buffers_init(&bufs, 0x10000u, 0x20000u, 0x50000u, 0x60000u);
        check((bufs.cur == 0u) && (bufs.has_ref == 0u), "a new IDR picture restarts the buffers");
    }

    if (g_fails == 0) {
        printf("DRIVER TEST PASS: rtlnet_h264_enc checks=%d\n", g_checks);
        return 0;
    }
    printf("DRIVER TEST FAIL: rtlnet_h264_enc fails=%d checks=%d\n", g_fails, g_checks);
    return 1;
}
