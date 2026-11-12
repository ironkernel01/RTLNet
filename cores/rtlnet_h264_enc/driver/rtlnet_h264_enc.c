/*
 * rtlnet_h264_enc.c -- RTLNet H.264 encoder driver
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: the only code that reads or writes rtlnet_h264_enc registers, and the writer of the stream's SPS and
 * PPS. Register map and function rules: rtlnet_h264_enc.h. No driver state: the hardware holds the
 * configuration, the pointers and the counters.
 */
#include "rtlnet_h264_enc.h"
#include "rtlnet_mmio.h"

#include <stddef.h>   /* NULL */

#define ERR_TIMEOUT_CODE      0xFFu
#define MB_SIZE               16u
#define MAX_QP                51u
#define RBSP_MAX_BYTES        48u
#define NAL_START_CODE_BYTES  4u
#define NAL_REF_IDC_HIGH      3u
#define NAL_TYPE_SPS          7u
#define NAL_TYPE_PPS          8u
#define PROFILE_BASELINE      66u
#define PROFILE_HIGH          100u
#define CHROMA_FORMAT_420     1u
#define POC_TYPE_NONE         2u
#define MAX_REF_FRAMES        1u
#define CROP_UNIT             2u      /* 4:2:0, frame_mbs_only_flag 1: crop units of 2 samples */
#define EP_BYTE               0x03u

/* Level limits, Table A-1: level_idc, MaxFS (macroblocks per frame), MaxMBPS (macroblocks per second). */
typedef struct {
    uint32_t level_idc;
    uint32_t max_fs;
    uint32_t max_mbps;
} level_limit_t;

static const level_limit_t k_levels[] = {
    {10u, 99u, 1485u},     {11u, 396u, 3000u},     {12u, 396u, 6000u},     {13u, 396u, 11880u},
    {20u, 396u, 11880u},   {21u, 792u, 19800u},    {22u, 1620u, 20250u},   {30u, 1620u, 40500u},
    {31u, 3600u, 108000u}, {32u, 5120u, 216000u},  {40u, 8192u, 245760u},  {42u, 8704u, 522240u},
    {50u, 22080u, 589824u}, {51u, 36864u, 983040u}, {52u, 36864u, 2073600u},
};

static const rtlnet_h264_enc_mode_t k_mode_table[] = {
    {80u, 45u, 1280u, 720u, 1280u, 720u, 30u, 31u},     /* RTLNET_H264_MODE_720P30 */
    {120u, 68u, 1920u, 1088u, 1920u, 1080u, 30u, 40u},  /* RTLNET_H264_MODE_1080P30 */
};

/* RBSP bit writer: MSB-first into a fixed byte array. */
typedef struct {
    uint8_t  data[RBSP_MAX_BYTES];
    uint32_t bits;
    int      overflow;
} bitw_t;

/*
 * bitw_put -- append n bits of value, MSB first
 * Steps:
 *   1. Set the overflow flag when the array cannot hold n more bits.
 *   2. Otherwise write each bit at the running bit position.
 * Returns: nothing; the flag is checked once by the caller.
 */
static void bitw_put(bitw_t *w, uint32_t value, uint32_t n)
{
    uint32_t i;

    if (w->bits + n > (RBSP_MAX_BYTES * 8u)) {
        w->overflow = 1;
        return;
    }
    for (i = 0u; i < n; i++) {
        uint32_t bit = (value >> (n - 1u - i)) & 1u;
        uint32_t pos = w->bits + i;

        if (bit != 0u) {
            w->data[pos / 8u] = (uint8_t)(w->data[pos / 8u] | (0x80u >> (pos % 8u)));
        }
    }
    w->bits += n;
}

/*
 * bitw_ue -- append ue(v), ITU-T H.264 clause 9.1
 * Steps:
 *   1. Take m = value + 1 and its bit length n.
 *   2. Write n - 1 zero bits, then m in n bits.
 * Returns: nothing.
 */
static void bitw_ue(bitw_t *w, uint32_t value)
{
    uint32_t m = value + 1u;
    uint32_t n = 0u;

    while ((m >> n) != 0u) {
        n++;
    }
    bitw_put(w, 0u, n - 1u);
    bitw_put(w, m, n);
}

/*
 * bitw_trailing -- append rbsp_trailing_bits: a one bit, then zero bits to the byte boundary (clause 7.3.2.11)
 * Returns: nothing.
 */
static void bitw_trailing(bitw_t *w)
{
    bitw_put(w, 1u, 1u);
    while ((w->bits % 8u) != 0u) {
        bitw_put(w, 0u, 1u);
    }
}

/*
 * emit_nal -- write one NAL unit: start code, header byte, payload with emulation prevention (clause 7.4.1)
 * Steps:
 *   1. Check the buffer holds the start code, the header and the payload.
 *   2. Write 00 00 00 01 and the header byte.
 *   3. Copy the payload, inserting 0x03 before any byte 0..3 that follows two zero bytes.
 * Returns: bytes written, or 0 when the buffer is too small.
 */
static size_t emit_nal(uint8_t *buf, size_t cap, uint32_t nal_type, const bitw_t *w)
{
    size_t   pos = 0u;
    uint32_t zeros = 0u;
    uint32_t i;
    uint32_t n = w->bits / 8u;

    if (cap < (NAL_START_CODE_BYTES + 1u)) {
        return 0u;
    }
    buf[pos++] = 0u;
    buf[pos++] = 0u;
    buf[pos++] = 0u;
    buf[pos++] = 1u;
    buf[pos++] = (uint8_t)((NAL_REF_IDC_HIGH << 5) | nal_type);
    for (i = 0u; i < n; i++) {
        uint8_t b = w->data[i];

        if ((zeros >= 2u) && (b <= EP_BYTE)) {
            if (pos >= cap) {
                return 0u;
            }
            buf[pos++] = (uint8_t)EP_BYTE;
            zeros = 0u;
        }
        if (pos >= cap) {
            return 0u;
        }
        buf[pos++] = b;
        zeros = (b == 0u) ? (zeros + 1u) : 0u;
    }
    return pos;
}

/*
 * pick_level -- smallest level whose MaxFS and MaxMBPS hold the stream (Table A-1)
 * Returns: level_idc, or 0 when no level up to 5.2 holds it.
 */
static uint32_t pick_level(uint32_t mbs_per_frame, uint32_t fps, uint32_t mb_w, uint32_t mb_h)
{
    size_t i;

    for (i = 0u; i < (sizeof(k_levels) / sizeof(k_levels[0])); i++) {
        uint32_t fs = k_levels[i].max_fs;
        uint32_t dim_limit = 0u;

        /* Frame width and height are each at most sqrt(8 * MaxFS) macroblocks. */
        while (((dim_limit + 1u) * (dim_limit + 1u)) <= (8u * fs)) {
            dim_limit++;
        }
        if ((mbs_per_frame <= fs) && ((mbs_per_frame * fps) <= k_levels[i].max_mbps) &&
            (mb_w <= dim_limit) && (mb_h <= dim_limit)) {
            return k_levels[i].level_idc;
        }
    }
    return 0u;
}

/*
 * rtlnet_h264_enc_write_sps_pps_profile -- see the header
 * Steps:
 *   1. Validate the request; pick the level.
 *   2. Build the SPS rbsp field by field in the order of clause 7.3.2.1.1 and wrap it as a NAL unit: Constrained Baseline, or High
 *      (profile_idc 100, chroma_format_idc 1, 8 bit samples, no scaling matrices).
 *   3. Build the PPS rbsp (clause 7.3.2.2) and wrap it: entropy_coding_mode_flag 0 (CAVLC) or, for High, 1 (CABAC).
 * Returns: 0 or -1.
 */
int rtlnet_h264_enc_write_sps_pps_profile(uint8_t *buf, size_t cap, const rtlnet_h264_enc_sps_cfg_t *cfg, int high, size_t *out_len)
{
    bitw_t   w;
    uint32_t mb_w, mb_h, level, i;
    uint32_t crop_r, crop_b;
    size_t   n_sps, n_pps;

    if ((buf == NULL) || (cfg == NULL) || (out_len == NULL)) {
        return -1;
    }
    if ((cfg->width == 0u) || (cfg->height == 0u) || ((cfg->width % MB_SIZE) != 0u) || ((cfg->height % MB_SIZE) != 0u) ||
        (cfg->display_width == 0u) || (cfg->display_height == 0u) || (cfg->display_width > cfg->width) ||
        (cfg->display_height > cfg->height) || ((cfg->display_width % CROP_UNIT) != 0u) ||
        ((cfg->display_height % CROP_UNIT) != 0u) || (cfg->fps == 0u) ||
        (cfg->log2_max_frame_num < RTLNET_H264_LOG2_FN_MIN) || (cfg->log2_max_frame_num > RTLNET_H264_LOG2_FN_MAX)) {
        return -1;
    }
    mb_w = cfg->width / MB_SIZE;
    mb_h = cfg->height / MB_SIZE;
    level = pick_level(mb_w * mb_h, cfg->fps, mb_w, mb_h);
    if (level == 0u) {
        return -1;
    }
    crop_r = (cfg->width - cfg->display_width) / CROP_UNIT;
    crop_b = (cfg->height - cfg->display_height) / CROP_UNIT;

    for (i = 0u; i < sizeof(w.data); i++) {
        w.data[i] = 0u;
    }
    w.bits = 0u;
    w.overflow = 0;
    bitw_put(&w, (high != 0) ? PROFILE_HIGH : PROFILE_BASELINE, 8u);   /* profile_idc */
    bitw_put(&w, 0u, 1u);                           /* constraint_set0_flag */
    bitw_put(&w, (high != 0) ? 0u : 1u, 1u);        /* constraint_set1_flag: Constrained Baseline (0 for High) */
    bitw_put(&w, 0u, 2u);                           /* constraint_set2_flag, constraint_set3_flag */
    bitw_put(&w, 0u, 4u);                           /* reserved_zero_4bits */
    bitw_put(&w, level, 8u);                        /* level_idc */
    bitw_ue(&w, 0u);                                /* seq_parameter_set_id */
    if (high != 0) {
        bitw_ue(&w, CHROMA_FORMAT_420);             /* chroma_format_idc */
        bitw_ue(&w, 0u);                            /* bit_depth_luma_minus8 */
        bitw_ue(&w, 0u);                            /* bit_depth_chroma_minus8 */
        bitw_put(&w, 0u, 1u);                       /* qpprime_y_zero_transform_bypass_flag */
        bitw_put(&w, 0u, 1u);                       /* seq_scaling_matrix_present_flag */
    }
    bitw_ue(&w, cfg->log2_max_frame_num - RTLNET_H264_LOG2_FN_MIN);   /* log2_max_frame_num_minus4 */
    bitw_ue(&w, POC_TYPE_NONE);                     /* pic_order_cnt_type */
    bitw_ue(&w, MAX_REF_FRAMES);                    /* max_num_ref_frames */
    bitw_put(&w, 0u, 1u);                           /* gaps_in_frame_num_value_allowed_flag */
    bitw_ue(&w, mb_w - 1u);                         /* pic_width_in_mbs_minus1 */
    bitw_ue(&w, mb_h - 1u);                         /* pic_height_in_map_units_minus1 */
    bitw_put(&w, 1u, 1u);                           /* frame_mbs_only_flag */
    bitw_put(&w, 1u, 1u);                           /* direct_8x8_inference_flag */
    if ((crop_r != 0u) || (crop_b != 0u)) {
        bitw_put(&w, 1u, 1u);                       /* frame_cropping_flag */
        bitw_ue(&w, 0u);                            /* frame_crop_left_offset */
        bitw_ue(&w, crop_r);                        /* frame_crop_right_offset */
        bitw_ue(&w, 0u);                            /* frame_crop_top_offset */
        bitw_ue(&w, crop_b);                        /* frame_crop_bottom_offset */
    } else {
        bitw_put(&w, 0u, 1u);
    }
    bitw_put(&w, 0u, 1u);                           /* vui_parameters_present_flag */
    bitw_trailing(&w);
    if (w.overflow != 0) {
        return -1;
    }
    n_sps = emit_nal(buf, cap, NAL_TYPE_SPS, &w);
    if (n_sps == 0u) {
        return -1;
    }

    for (i = 0u; i < sizeof(w.data); i++) {
        w.data[i] = 0u;
    }
    w.bits = 0u;
    bitw_ue(&w, 0u);                                /* pic_parameter_set_id */
    bitw_ue(&w, 0u);                                /* seq_parameter_set_id */
    bitw_put(&w, (high != 0) ? 1u : 0u, 1u);        /* entropy_coding_mode_flag: CAVLC, or CABAC for High */
    bitw_put(&w, 0u, 1u);                           /* bottom_field_pic_order_in_frame_present_flag */
    bitw_ue(&w, 0u);                                /* num_slice_groups_minus1 */
    bitw_ue(&w, 0u);                                /* num_ref_idx_l0_default_active_minus1 */
    bitw_ue(&w, 0u);                                /* num_ref_idx_l1_default_active_minus1 */
    bitw_put(&w, 0u, 1u);                           /* weighted_pred_flag */
    bitw_put(&w, 0u, 2u);                           /* weighted_bipred_idc */
    bitw_ue(&w, 0u);                                /* pic_init_qp_minus26 as se(0) */
    bitw_ue(&w, 0u);                                /* pic_init_qs_minus26 as se(0) */
    bitw_ue(&w, 0u);                                /* chroma_qp_index_offset as se(0) */
    bitw_put(&w, 1u, 1u);                           /* deblocking_filter_control_present_flag */
    bitw_put(&w, 0u, 1u);                           /* constrained_intra_pred_flag */
    bitw_put(&w, 0u, 1u);                           /* redundant_pic_cnt_present_flag */
    bitw_trailing(&w);
    if (w.overflow != 0) {
        return -1;
    }
    n_pps = emit_nal(buf + n_sps, cap - n_sps, NAL_TYPE_PPS, &w);
    if (n_pps == 0u) {
        return -1;
    }
    *out_len = n_sps + n_pps;
    return 0;
}

/*
 * rtlnet_h264_enc_write_sps_pps -- see the header (Constrained Baseline form of rtlnet_h264_enc_write_sps_pps_profile)
 */
int rtlnet_h264_enc_write_sps_pps(uint8_t *buf, size_t cap, const rtlnet_h264_enc_sps_cfg_t *cfg, size_t *out_len)
{
    return rtlnet_h264_enc_write_sps_pps_profile(buf, cap, cfg, 0, out_len);
}

/*
 * rtlnet_h264_enc_get_mode -- see the header
 * Returns: 0 or -1.
 */
int rtlnet_h264_enc_get_mode(uint32_t video_mode, rtlnet_h264_enc_mode_t *out)
{
    if ((out == NULL) || (video_mode >= (sizeof(k_mode_table) / sizeof(k_mode_table[0])))) {
        return -1;
    }
    *out = k_mode_table[video_mode];
    return 0;
}

/*
 * rtlnet_h264_enc_band_rows -- see the header
 * Steps:
 *   1. Take ceil(mb_h / num_engines) rows for every engine but the last.
 *   2. Give the last engine the remainder; reject when it is empty.
 * Returns: 0 or -1.
 */
int rtlnet_h264_enc_band_rows(uint32_t mb_h, uint32_t num_engines, uint32_t engine, uint32_t *first_row, uint32_t *rows)
{
    uint32_t per;

    if ((num_engines == 0u) || (engine >= num_engines) || (mb_h == 0u) || (first_row == NULL) || (rows == NULL)) {
        return -1;
    }
    per = (mb_h + num_engines - 1u) / num_engines;
    if ((per * (num_engines - 1u)) >= mb_h) {
        return -1;
    }
    *first_row = engine * per;
    *rows = (engine < (num_engines - 1u)) ? per : (mb_h - (per * (num_engines - 1u)));
    return 0;
}

/*
 * rtlnet_h264_enc_set_mode -- see the header
 * Steps:
 *   1. Read CAPS; look up the mode.
 *   2. Reject a picture wider or taller than the build, or a band split that leaves an engine empty.
 *   3. Write MB_W and MB_H and fill the SPS parameters.
 * Returns: 0 or -1.
 */
int rtlnet_h264_enc_set_mode(uintptr_t base, uint32_t video_mode, rtlnet_h264_enc_sps_cfg_t *sps)
{
    rtlnet_h264_enc_caps_t caps;
    rtlnet_h264_enc_mode_t mode;
    uint32_t first, rows, e;

    if ((sps == NULL) || (rtlnet_h264_enc_probe(base, &caps) != 0) || (rtlnet_h264_enc_get_mode(video_mode, &mode) != 0)) {
        return -1;
    }
    if ((mode.mb_w > caps.max_mb_w) || (mode.mb_h > caps.max_mb_h)) {
        return -1;
    }
    for (e = 0u; e < caps.num_engines; e++) {
        if (rtlnet_h264_enc_band_rows(mode.mb_h, caps.num_engines, e, &first, &rows) != 0) {
            return -1;
        }
    }
    rtlnet_reg_write32(base, RTLNET_H264_REG_MB_W, mode.mb_w);
    rtlnet_reg_write32(base, RTLNET_H264_REG_MB_H, mode.mb_h);
    sps->width              = mode.width;
    sps->height             = mode.height;
    sps->display_width      = mode.display_width;
    sps->display_height     = mode.display_height;
    sps->fps                = mode.fps;
    sps->log2_max_frame_num = (rtlnet_reg_read32(base, RTLNET_H264_REG_PIC_CFG) >> RTLNET_H264_PIC_CFG_LOG2FN_SHIFT) &
                              RTLNET_H264_PIC_CFG_LOG2FN_MASK;
    if (sps->log2_max_frame_num < RTLNET_H264_LOG2_FN_MIN) {
        sps->log2_max_frame_num = RTLNET_H264_LOG2_FN_MIN;
    }
    return 0;
}

/*
 * rtlnet_h264_enc_probe -- see the header
 * Steps:
 *   1. Check ID and VERSION.
 *   2. Decode CAPS into caps when it is not NULL.
 * Returns: 0 when present and matching, -1 otherwise.
 */
int rtlnet_h264_enc_probe(uintptr_t base, rtlnet_h264_enc_caps_t *caps)
{
    uint32_t c;

    if (rtlnet_reg_read32(base, RTLNET_REG_ID) != RTLNET_H264_ID_VALUE) {
        return -1;
    }
    if (rtlnet_reg_read32(base, RTLNET_REG_VERSION) != RTLNET_H264_VERSION_VALUE) {
        return -1;
    }
    if (caps != NULL) {
        c = rtlnet_reg_read32(base, RTLNET_REG_CAPS);
        caps->max_mb_w    = c & RTLNET_H264_CAPS_MB_W_MASK;
        caps->max_mb_h    = (c >> RTLNET_H264_CAPS_MB_H_SHIFT) & RTLNET_H264_CAPS_MB_H_MASK;
        caps->num_engines = (c >> RTLNET_H264_CAPS_ENG_SHIFT) & RTLNET_H264_CAPS_ENG_MASK;
        caps->hp_seam     = (c & RTLNET_H264_CAPS_HP_SEAM) != 0u ? 1u : 0u;
    }
    return 0;
}

/*
 * rtlnet_h264_enc_configure -- see the header
 * Steps:
 *   1. Read CAPS and reject a picture larger than the build.
 *   2. Reject sizes and alignments the core rejects at start (input in 128-byte granules, tile bases, index records).
 *   3. Write the configuration registers.
 * Returns: 0 or -1; nothing is written on -1.
 */
int rtlnet_h264_enc_configure(uintptr_t base, const rtlnet_h264_enc_cfg_t *cfg)
{
    rtlnet_h264_enc_caps_t caps;

    if ((cfg == NULL) || (rtlnet_h264_enc_probe(base, &caps) != 0)) {
        return -1;
    }
    if ((cfg->mb_w == 0u) || (cfg->mb_w > caps.max_mb_w) || (cfg->mb_h == 0u) || (cfg->mb_h > caps.max_mb_h) ||
        (cfg->slices == 0u) || (cfg->slices > cfg->mb_h) || (cfg->qp > MAX_QP) ||
        (cfg->log2_max_frame_num < RTLNET_H264_LOG2_FN_MIN) || (cfg->log2_max_frame_num > RTLNET_H264_LOG2_FN_MAX)) {
        return -1;
    }
    if (((cfg->in_base % RTLNET_H264_IN_ALIGN) != 0u) || ((cfg->in_stride % RTLNET_H264_IN_ALIGN) != 0u) ||
        (cfg->in_stride < (cfg->mb_w * 32u)) ||
        ((cfg->ry_base % RTLNET_H264_REC_LUMA_TILE_BYTES) != 0u) ||
        ((cfg->ru_base % RTLNET_H264_REC_CHROMA_TILE_BYTES) != 0u)) {
        return -1;
    }
    if (((cfg->ring_base % 16u) != 0u) || ((cfg->ring_size % 16u) != 0u) || (cfg->ring_size < 1024u) ||
        ((cfg->idx_base % RTLNET_H264_IDX_ENTRY_BYTES) != 0u) || (cfg->idx_entries == 0u)) {
        return -1;
    }
    rtlnet_reg_write32(base, RTLNET_H264_REG_MB_W, cfg->mb_w);
    rtlnet_reg_write32(base, RTLNET_H264_REG_MB_H, cfg->mb_h);
    rtlnet_reg_write32(base, RTLNET_H264_REG_SLICES, cfg->slices);
    rtlnet_reg_write32(base, RTLNET_H264_REG_QP,
                       (cfg->qp < RTLNET_H264_QP_MIN_REALTIME) ? RTLNET_H264_QP_MIN_REALTIME : cfg->qp);
    rtlnet_reg_write32(base, RTLNET_H264_REG_MB_MODE, (cfg->mb_pcm != 0u) ? 1u : 0u);
    rtlnet_reg_write32(base, RTLNET_H264_REG_IN_BASE, cfg->in_base);
    rtlnet_reg_write32(base, RTLNET_H264_REG_IN_STRIDE, cfg->in_stride);
    rtlnet_reg_write32(base, RTLNET_H264_REG_RY_BASE, cfg->ry_base);
    rtlnet_reg_write32(base, RTLNET_H264_REG_RU_BASE, cfg->ru_base);
    rtlnet_reg_write32(base, RTLNET_H264_REG_RING_BASE, cfg->ring_base);
    rtlnet_reg_write32(base, RTLNET_H264_REG_RING_SIZE, cfg->ring_size);
    rtlnet_reg_write32(base, RTLNET_H264_REG_IDX_BASE, cfg->idx_base);
    rtlnet_reg_write32(base, RTLNET_H264_REG_IDX_ENTRIES, cfg->idx_entries);
    rtlnet_reg_write32(base, RTLNET_H264_REG_PIC_CFG,
                       (cfg->log2_max_frame_num << RTLNET_H264_PIC_CFG_LOG2FN_SHIFT) | RTLNET_H264_PIC_CFG_IDR);
    return 0;
}

/*
 * rtlnet_h264_enc_next_frame_num -- see the header
 * Returns: (prev + 1) mod 2^log2_max_frame_num, or 0 for a log2_max_frame_num outside 4..16.
 */
uint32_t rtlnet_h264_enc_next_frame_num(uint32_t prev_frame_num, uint32_t log2_max_frame_num)
{
    if ((log2_max_frame_num < RTLNET_H264_LOG2_FN_MIN) || (log2_max_frame_num > RTLNET_H264_LOG2_FN_MAX)) {
        return 0u;
    }
    return (prev_frame_num + 1u) & ((1u << log2_max_frame_num) - 1u);
}

/*
 * rtlnet_h264_enc_set_reference -- see the header
 * Returns: 0, or -1 for a misaligned base (nothing written).
 */
int rtlnet_h264_enc_set_reference(uintptr_t base, uint32_t ref_y_base, uint32_t ref_u_base)
{
    if (((ref_y_base % RTLNET_H264_REC_LUMA_TILE_BYTES) != 0u) || ((ref_u_base % RTLNET_H264_REC_CHROMA_TILE_BYTES) != 0u)) {
        return -1;
    }
    rtlnet_reg_write32(base, RTLNET_H264_REG_REFY_BASE, ref_y_base);
    rtlnet_reg_write32(base, RTLNET_H264_REG_REFU_BASE, ref_u_base);
    return 0;
}

/*
 * rtlnet_h264_enc_buffers_init -- see the header
 * Returns: 0, or -1 for a NULL pointer or a misaligned base.
 */
int rtlnet_h264_enc_buffers_init(rtlnet_h264_enc_buffers_t *b, uint32_t y0, uint32_t u0, uint32_t y1, uint32_t u1)
{
    if (b == NULL) {
        return -1;
    }
    if (((y0 % RTLNET_H264_REC_LUMA_TILE_BYTES) != 0u) || ((y1 % RTLNET_H264_REC_LUMA_TILE_BYTES) != 0u) ||
        ((u0 % RTLNET_H264_REC_CHROMA_TILE_BYTES) != 0u) || ((u1 % RTLNET_H264_REC_CHROMA_TILE_BYTES) != 0u)) {
        return -1;
    }
    b->y_base[0] = y0;
    b->y_base[1] = y1;
    b->u_base[0] = u0;
    b->u_base[1] = u1;
    b->cur       = 0u;
    b->has_ref   = 0u;
    return 0;
}

/*
 * rtlnet_h264_enc_buffers_begin -- see the header
 * Steps:
 *   1. Reject a NULL argument, an unknown type, or a P picture with no reference yet.
 *   2. Write RY_BASE and RU_BASE of the current buffer.
 *   3. For a P picture write REF_Y_BASE and REF_U_BASE of the other buffer.
 * Returns: 0 or -1 (nothing written on -1).
 */
int rtlnet_h264_enc_buffers_begin(uintptr_t base, const rtlnet_h264_enc_buffers_t *b, uint32_t pic_type)
{
    uint32_t other;

    if ((b == NULL) || (b->cur > 1u) || ((pic_type != RTLNET_H264_PIC_IDR) && (pic_type != RTLNET_H264_PIC_P))) {
        return -1;
    }
    if ((pic_type == RTLNET_H264_PIC_P) && (b->has_ref == 0u)) {
        return -1;
    }
    other = 1u - b->cur;
    rtlnet_reg_write32(base, RTLNET_H264_REG_RY_BASE, b->y_base[b->cur]);
    rtlnet_reg_write32(base, RTLNET_H264_REG_RU_BASE, b->u_base[b->cur]);
    if (pic_type == RTLNET_H264_PIC_P) {
        rtlnet_reg_write32(base, RTLNET_H264_REG_REFY_BASE, b->y_base[other]);
        rtlnet_reg_write32(base, RTLNET_H264_REG_REFU_BASE, b->u_base[other]);
    }
    return 0;
}

/*
 * rtlnet_h264_enc_buffers_end -- see the header
 */
void rtlnet_h264_enc_buffers_end(rtlnet_h264_enc_buffers_t *b)
{
    if (b != NULL) {
        b->cur     = 1u - (b->cur & 1u);
        b->has_ref = 1u;
    }
}

/*
 * rtlnet_h264_enc_ring_reset -- see the header
 * Returns: nothing.
 */
void rtlnet_h264_enc_ring_reset(uintptr_t base)
{
    rtlnet_reg_write32(base, RTLNET_H264_REG_CTRL,
                       (rtlnet_reg_read32(base, RTLNET_H264_REG_CTRL) & RTLNET_H264_CTRL_IRQ_EN) |
                       RTLNET_H264_CTRL_RING_RESET);
}

/*
 * rtlnet_h264_enc_start_picture -- see the header
 * Steps:
 *   1. Reject when BUSY is set.
 *   2. Write PIC_CFG (keeping log2_max_frame_num), frame_num and idr_pic_id.
 *   3. Clear DONE and write CTRL.START.
 * Returns: 0 or -1.
 */
int rtlnet_h264_enc_start_picture(uintptr_t base, uint32_t frame_num, uint32_t idr_pic_id, int idr)
{
    uint32_t cfg;

    if ((rtlnet_reg_read32(base, RTLNET_H264_REG_STATUS) & RTLNET_H264_STATUS_BUSY) != 0u) {
        return -1;
    }
    cfg = rtlnet_reg_read32(base, RTLNET_H264_REG_PIC_CFG) & ~(RTLNET_H264_PIC_CFG_IDR | RTLNET_H264_PIC_CFG_P);
    if (idr != 0) {
        cfg |= RTLNET_H264_PIC_CFG_IDR;
    }
    rtlnet_reg_write32(base, RTLNET_H264_REG_PIC_CFG, cfg);
    rtlnet_reg_write32(base, RTLNET_H264_REG_FRAME_NUM, frame_num);
    rtlnet_reg_write32(base, RTLNET_H264_REG_IDR_PIC_ID, idr_pic_id);
    rtlnet_reg_write32(base, RTLNET_H264_REG_STATUS, RTLNET_H264_STATUS_DONE);
    rtlnet_reg_write32(base, RTLNET_H264_REG_CTRL,
                       (rtlnet_reg_read32(base, RTLNET_H264_REG_CTRL) & RTLNET_H264_CTRL_IRQ_EN) |
                       RTLNET_H264_CTRL_START);
    return 0;
}

/*
 * rtlnet_h264_enc_start_picture_ex -- see the header
 * Steps:
 *   1. Reject an unknown type, a P frame_num beyond log2_max_frame_num bits, or BUSY.
 *   2. Write PIC_CFG (the IDR or the P flag, log2_max_frame_num kept), frame_num and idr_pic_id (IDR only).
 *   3. Clear DONE and write CTRL.START.
 * Returns: 0 or -1.
 */
int rtlnet_h264_enc_start_picture_ex(uintptr_t base, uint32_t frame_num, uint32_t idr_pic_id, uint32_t pic_type)
{
    uint32_t cfg;
    uint32_t log2fn;

    if ((pic_type != RTLNET_H264_PIC_IDR) && (pic_type != RTLNET_H264_PIC_P)) {
        return -1;
    }
    if ((rtlnet_reg_read32(base, RTLNET_H264_REG_STATUS) & RTLNET_H264_STATUS_BUSY) != 0u) {
        return -1;
    }
    cfg    = rtlnet_reg_read32(base, RTLNET_H264_REG_PIC_CFG) & ~(RTLNET_H264_PIC_CFG_IDR | RTLNET_H264_PIC_CFG_P);
    log2fn = (cfg >> RTLNET_H264_PIC_CFG_LOG2FN_SHIFT) & RTLNET_H264_PIC_CFG_LOG2FN_MASK;
    if ((pic_type == RTLNET_H264_PIC_P) && ((log2fn < RTLNET_H264_LOG2_FN_MIN) || (log2fn > RTLNET_H264_LOG2_FN_MAX) ||
                                           (frame_num >= (1u << log2fn)))) {
        return -1;
    }
    if (pic_type == RTLNET_H264_PIC_IDR) {
        cfg |= RTLNET_H264_PIC_CFG_IDR;
        frame_num = 0u;
    } else {
        cfg |= RTLNET_H264_PIC_CFG_P;
        idr_pic_id = 0u;
    }
    rtlnet_reg_write32(base, RTLNET_H264_REG_PIC_CFG, cfg);
    rtlnet_reg_write32(base, RTLNET_H264_REG_FRAME_NUM, frame_num);
    rtlnet_reg_write32(base, RTLNET_H264_REG_IDR_PIC_ID, idr_pic_id);
    rtlnet_reg_write32(base, RTLNET_H264_REG_STATUS, RTLNET_H264_STATUS_DONE);
    rtlnet_reg_write32(base, RTLNET_H264_REG_CTRL,
                       (rtlnet_reg_read32(base, RTLNET_H264_REG_CTRL) & RTLNET_H264_CTRL_IRQ_EN) |
                       RTLNET_H264_CTRL_START);
    return 0;
}

/*
 * rtlnet_h264_enc_wait_done -- see the header
 * Returns: 0 on DONE, -1 on ERR or timeout.
 */
int rtlnet_h264_enc_wait_done(uintptr_t base, uint32_t max_polls, uint32_t *err_code)
{
    uint32_t n;
    uint32_t st;

    for (n = 0u; n < max_polls; n++) {
        st = rtlnet_reg_read32(base, RTLNET_H264_REG_STATUS);
        if ((st & RTLNET_H264_STATUS_ERR) != 0u) {
            if (err_code != NULL) {
                *err_code = rtlnet_reg_read32(base, RTLNET_H264_REG_ERR_CODE);
            }
            return -1;
        }
        if ((st & RTLNET_H264_STATUS_DONE) != 0u) {
            return 0;
        }
    }
    if (err_code != NULL) {
        *err_code = ERR_TIMEOUT_CODE;
    }
    return -1;
}

/*
 * hp_decode -- HP_STATUS into the struct
 */
static void hp_decode(uint32_t v, rtlnet_h264_enc_hp_t *out)
{
    out->present      = ((v & RTLNET_H264_HP_STATUS_PRESENT) != 0u) ? 1u : 0u;
    out->licensed     = ((v & RTLNET_H264_HP_STATUS_LICENSED) != 0u) ? 1u : 0u;
    out->active       = ((v & RTLNET_H264_HP_STATUS_ACTIVE) != 0u) ? 1u : 0u;
    out->enabled      = ((v & RTLNET_H264_HP_STATUS_ENABLED) != 0u) ? 1u : 0u;
    out->profile_chg  = ((v & RTLNET_H264_HP_STATUS_CHG) != 0u) ? 1u : 0u;
    out->caps         = (v >> RTLNET_H264_HP_STATUS_CAPS_SHIFT) & RTLNET_H264_HP_STATUS_CAPS_MASK;
    out->seconds_left = v >> RTLNET_H264_HP_STATUS_SEC_SHIFT;
}

/*
 * hp_seam_present -- 1 when CAPS bit 20 says the build has the High profile registers
 */
static int hp_seam_present(uintptr_t base)
{
    return (rtlnet_reg_read32(base, RTLNET_REG_CAPS) & RTLNET_H264_CAPS_HP_SEAM) != 0u;
}

/*
 * rtlnet_h264_enc_hp_status -- see the header
 */
int rtlnet_h264_enc_hp_status(uintptr_t base, rtlnet_h264_enc_hp_t *out)
{
    if (out == NULL) {
        return -1;
    }
    if (!hp_seam_present(base)) {
        return RTLNET_H264_HP_ERR_NO_SEAM;
    }
    hp_decode(rtlnet_reg_read32(base, RTLNET_H264_REG_HP_STATUS), out);
    return 0;
}

/*
 * rtlnet_h264_enc_set_profile -- see the header
 * Steps: baseline writes hp_enable 0 (when the seam exists); high checks seam, module, caps and license in that order and
 * writes hp_enable 1 only when all hold.
 */
int rtlnet_h264_enc_set_profile(uintptr_t base, int high)
{
    rtlnet_h264_enc_hp_t hp;
    if (!hp_seam_present(base)) {
        return high ? RTLNET_H264_HP_ERR_NO_SEAM : 0;
    }
    if (!high) {
        rtlnet_reg_write32(base, RTLNET_H264_REG_HP_CTRL, 0u);
        return 0;
    }
    hp_decode(rtlnet_reg_read32(base, RTLNET_H264_REG_HP_STATUS), &hp);
    if (hp.present == 0u) {
        return RTLNET_H264_HP_ERR_NO_MODULE;
    }
    if (hp.caps == 0u) {
        return RTLNET_H264_HP_ERR_NO_CAPS;
    }
    if (hp.licensed == 0u) {
        return RTLNET_H264_HP_ERR_NOT_LICENSED;
    }
    rtlnet_reg_write32(base, RTLNET_H264_REG_HP_CTRL, 1u);
    return 0;
}

/*
 * rtlnet_h264_enc_hp_clear_change -- see the header
 */
int rtlnet_h264_enc_hp_clear_change(uintptr_t base)
{
    if (!hp_seam_present(base)) {
        return -1;
    }
    if ((rtlnet_reg_read32(base, RTLNET_H264_REG_HP_STATUS) & RTLNET_H264_HP_STATUS_CHG) == 0u) {
        return 0;
    }
    rtlnet_reg_write32(base, RTLNET_H264_REG_HP_STATUS, RTLNET_H264_HP_STATUS_CHG);
    return 1;
}

/*
 * rtlnet_h264_enc_status -- see the header
 */
uint32_t rtlnet_h264_enc_status(uintptr_t base)
{
    return rtlnet_reg_read32(base, RTLNET_H264_REG_STATUS);
}

/*
 * rtlnet_h264_enc_clear_status -- see the header
 */
void rtlnet_h264_enc_clear_status(uintptr_t base)
{
    rtlnet_reg_write32(base, RTLNET_H264_REG_STATUS, RTLNET_H264_STATUS_DONE | RTLNET_H264_STATUS_ERR);
}

/*
 * rtlnet_h264_enc_set_read_pointers -- see the header
 */
void rtlnet_h264_enc_set_read_pointers(uintptr_t base, uint32_t ring_rptr, uint32_t idx_rptr)
{
    rtlnet_reg_write32(base, RTLNET_H264_REG_RING_RPTR, ring_rptr);
    rtlnet_reg_write32(base, RTLNET_H264_REG_IDX_RPTR, idx_rptr);
}

/*
 * rtlnet_h264_enc_index_wptr -- see the header
 */
uint32_t rtlnet_h264_enc_index_wptr(uintptr_t base)
{
    return rtlnet_reg_read32(base, RTLNET_H264_REG_IDX_WPTR);
}

/*
 * rtlnet_h264_enc_decode_index_entry -- split the four words of an index entry into fields
 */
void rtlnet_h264_enc_decode_index_entry(const uint32_t words[4], rtlnet_h264_enc_index_entry_t *out)
{
    out->offset     = words[0];
    out->length     = words[1];
    out->picture    = words[2] & RTLNET_H264_IDX_PIC_MASK;
    out->slice      = words[2] >> RTLNET_H264_IDX_SLICE_SHIFT;
    out->slice_type = words[3] & RTLNET_H264_IDX_TYPE_MASK;
    out->qp         = (words[3] >> RTLNET_H264_IDX_QP_SHIFT) & RTLNET_H264_IDX_QP_MASK;
    out->last_slice = ((words[3] & RTLNET_H264_IDX_LAST) != 0u);
    out->idr        = ((words[3] & RTLNET_H264_IDX_IDR) != 0u);
    out->is_picture = ((words[3] & RTLNET_H264_IDX_KIND_PICTURE) != 0u);
}

/*
 * rtlnet_h264_enc_read_stats -- see the header
 */
void rtlnet_h264_enc_read_stats(uintptr_t base, rtlnet_h264_enc_stats_t *out)
{
    out->mb_count = rtlnet_reg_read32(base, RTLNET_H264_REG_MB_COUNT);
    out->cyc_last = rtlnet_reg_read32(base, RTLNET_H264_REG_CYC_LAST);
    out->cyc_max  = rtlnet_reg_read32(base, RTLNET_H264_REG_CYC_MAX);
    out->pic_cyc  = rtlnet_reg_read32(base, RTLNET_H264_REG_PIC_CYC);
    out->rd_cyc   = rtlnet_reg_read32(base, RTLNET_H264_REG_RD_CYC);
    out->pk_cyc   = rtlnet_reg_read32(base, RTLNET_H264_REG_PK_CYC);
    out->wr_cyc   = rtlnet_reg_read32(base, RTLNET_H264_REG_WR_CYC);
}
