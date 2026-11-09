/*
 * rtlnet_h264_enc.h -- RTLNet H.264 encoder driver
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: the one file pair (rtlnet_h264_enc.h / .c) that touches the registers of the rtlnet_h264_enc
 * core and writes the stream's SPS and PPS. Every register offset and bit of the core is defined here,
 * once; hdl/rtlnet_h264_enc_regs.sv mirrors them as localparams with a pointer to this header, and
 * hdl/rtlnet_h264_pkg.sv mirrors the error codes. Change both in the same commit: a mismatch reads the
 * wrong counter, or starts a picture with a configuration the core rejects or misreads.
 *
 * The base address (the core's 4 KiB window) is passed in by the platform layer. Register access goes only
 * through rtlnet_mmio.h.
 *
 * Behaviour. The core encodes one picture per start: it reads packed YUYV 4:2:2 from the input frame, codes
 * it as one or more slices of whole macroblock rows (phase 2b-1: every macroblock is I_PCM), writes the
 * Annex B stream (access unit delimiter, then the slice NAL units) into the compressed ring, one index
 * entry per slice and one per picture into the index ring, and the rebuilt 4:2:0 picture into three planes.
 * Firmware writes the SPS and PPS (rtlnet_h264_enc_write_sps_pps) in front of the first picture.
 *
 * Memory formats (all byte addresses are multiples of 16, the input base and stride of 32):
 *   input frame  packed YUYV, byte order Y0 U0 Y1 V0 per pixel pair, line stride in_stride bytes
 *   rebuilt      Y plane (ry_stride per line), U plane and V plane (rc_stride per line, width / 2 samples)
 *   ring         compressed bytes; the core writes at the write pointer, firmware reads and reports the read
 *                pointer; the core stalls when the ring is full
 *   index entry  16 bytes, little endian words (see RTLNET_H264_IDX_*)
 *
 * This header holds the register map, the types and the function rules; rtlnet_h264_enc.c holds the
 * per-function commentary.
 */
#ifndef RTLNET_H264_ENC_H
#define RTLNET_H264_ENC_H

#include <stddef.h>   /* size_t */
#include <stdint.h>   /* uint32_t, uint8_t, uintptr_t */

#define RTLNET_H264_ID_VALUE             0x48323634u   /* "H264" */
#define RTLNET_H264_VERSION_VALUE        0x11092026u
/* Revision 11-09-2026: initial register map (phase 2b-1). */

/* Registers (ID, VERSION, CAPS at RTLNET_REG_* of rtlnet_mmio.h). */
#define RTLNET_H264_REG_CTRL             0x00Cu   /* START and RING_RESET self-clear, IRQ_EN holds */
#define RTLNET_H264_REG_STATUS           0x010u   /* BUSY, DONE (W1C), ERR (W1C), RING_STALL */
#define RTLNET_H264_REG_ERR_CODE         0x014u   /* RO, first error since the last ERR clear */
#define RTLNET_H264_REG_MB_W             0x020u   /* picture width in macroblocks */
#define RTLNET_H264_REG_MB_H             0x024u   /* picture height in macroblocks */
#define RTLNET_H264_REG_SLICES           0x028u   /* slices per picture, 1..MB_H */
#define RTLNET_H264_REG_QP               0x02Cu   /* slice QP 0..51 (slice_qp_delta = QP - 26) */
#define RTLNET_H264_REG_FRAME_NUM        0x030u   /* frame_num, written in log2_max_frame_num bits */
#define RTLNET_H264_REG_IDR_PIC_ID       0x034u   /* idr_pic_id of an IDR picture */
#define RTLNET_H264_REG_PIC_CFG          0x038u   /* [0] IDR picture, [12:8] log2_max_frame_num */
#define RTLNET_H264_REG_IN_BASE          0x040u   /* input frame base, multiple of 32 */
#define RTLNET_H264_REG_IN_STRIDE        0x044u   /* input line stride in bytes, multiple of 32, >= MB_W * 32 */
#define RTLNET_H264_REG_RY_BASE          0x048u   /* rebuilt luma plane base */
#define RTLNET_H264_REG_RY_STRIDE        0x04Cu   /* rebuilt luma line stride, multiple of 16, >= MB_W * 16 */
#define RTLNET_H264_REG_RU_BASE          0x050u   /* rebuilt Cb plane base */
#define RTLNET_H264_REG_RV_BASE          0x054u   /* rebuilt Cr plane base */
#define RTLNET_H264_REG_RC_STRIDE        0x058u   /* rebuilt chroma line stride, multiple of 16, >= MB_W * 8 */
#define RTLNET_H264_REG_RING_BASE        0x060u   /* compressed ring base, multiple of 16 */
#define RTLNET_H264_REG_RING_SIZE        0x064u   /* compressed ring size in bytes, multiple of 16, >= 1024 */
#define RTLNET_H264_REG_RING_WPTR        0x068u   /* RO, byte offset after the last completed burst */
#define RTLNET_H264_REG_RING_RPTR        0x06Cu   /* RW, byte offset firmware has consumed up to */
#define RTLNET_H264_REG_RING_FILL        0x070u   /* RO, bytes written and not consumed */
#define RTLNET_H264_REG_IDX_BASE         0x078u   /* index ring base, multiple of 16 */
#define RTLNET_H264_REG_IDX_ENTRIES      0x07Cu   /* index ring size in entries (16 bytes each) */
#define RTLNET_H264_REG_IDX_WPTR         0x080u   /* RO, index of the next entry to be written */
#define RTLNET_H264_REG_IDX_RPTR         0x084u   /* RW, index firmware has consumed up to */
#define RTLNET_H264_REG_IDX_FILL         0x088u   /* RO, entries written and not consumed */
#define RTLNET_H264_REG_PIC_COUNT        0x090u   /* RO, pictures completed (low 16 bits stamp the entries) */
#define RTLNET_H264_REG_SLICE_COUNT      0x094u   /* RO, slices completed */
#define RTLNET_H264_REG_MB_COUNT         0x098u   /* RO, macroblocks coded in the current or last picture */
#define RTLNET_H264_REG_CYC_LAST         0x09Cu   /* RO, clocks between the last two macroblock starts */
#define RTLNET_H264_REG_CYC_MAX          0x0A0u   /* RO, largest such interval in the picture */
#define RTLNET_H264_REG_PIC_CYC          0x0A4u   /* RO, clocks from start to done */
#define RTLNET_H264_REG_RD_CYC           0x0A8u   /* RO, clocks the read DMA was busy */
#define RTLNET_H264_REG_PK_CYC           0x0ACu   /* RO, clocks the macroblock coder was busy */
#define RTLNET_H264_REG_WR_CYC           0x0B0u   /* RO, clocks the write master was busy */

/* CTRL bits. */
#define RTLNET_H264_CTRL_START           (1u << 0)    /* self-clearing: code one picture */
#define RTLNET_H264_CTRL_RING_RESET      (1u << 1)    /* self-clearing: clear ring and index pointers (core idle) */
#define RTLNET_H264_CTRL_IRQ_EN          (1u << 8)    /* irq high while IRQ_EN and (DONE or ERR) */

/* STATUS bits. */
#define RTLNET_H264_STATUS_BUSY          (1u << 0)
#define RTLNET_H264_STATUS_DONE          (1u << 1)    /* write 1 to clear */
#define RTLNET_H264_STATUS_ERR           (1u << 2)    /* write 1 to clear; also clears ERR_CODE */
#define RTLNET_H264_STATUS_RING_STALL    (1u << 3)    /* the ring is full and the writer waits */

/* ERR_CODE values (hdl/rtlnet_h264_pkg.sv ERR_*). */
#define RTLNET_H264_ERR_NONE             0u
#define RTLNET_H264_ERR_CONFIG           1u   /* start rejected: an illegal register setting */
#define RTLNET_H264_ERR_AXI              2u   /* memory response other than OKAY */
#define RTLNET_H264_ERR_RPTR             3u   /* read pointer write beyond the data written, or >= ring size */
#define RTLNET_H264_ERR_BUSY             4u   /* start while a picture runs */

/* PIC_CFG fields. */
#define RTLNET_H264_PIC_CFG_IDR          (1u << 0)
#define RTLNET_H264_PIC_CFG_LOG2FN_SHIFT 8u
#define RTLNET_H264_PIC_CFG_LOG2FN_MASK  0x1Fu

/* CAPS fields. */
#define RTLNET_H264_CAPS_MB_W_MASK       0xFFu          /* [7:0] MAX_MB_W */
#define RTLNET_H264_CAPS_MB_H_SHIFT      8u             /* [15:8] MAX_MB_H */
#define RTLNET_H264_CAPS_MB_H_MASK       0xFFu
#define RTLNET_H264_CAPS_ENG_SHIFT       16u            /* [19:16] NUM_ENGINES */
#define RTLNET_H264_CAPS_ENG_MASK        0xFu

/*
 * Index entry: four little-endian 32-bit words, 16 bytes, at idx_base + 16 * index.
 *   word 0  byte offset in the ring of the NAL unit's first byte (picture entry: of the access unit
 *           delimiter that opens the picture)
 *   word 1  length in bytes, start code and emulation-prevention bytes included (picture entry: the sum
 *           over the access unit delimiter and all slice NAL units)
 *   word 2  [15:0] picture number, [31:16] slice number (picture entry: number of slices)
 *   word 3  [7:0] slice type (7 = I), [15:8] QP, [16] last slice of the picture, [17] IDR picture,
 *           [24] entry kind (0 slice, 1 picture)
 * A slice entry appears when every byte of its NAL unit is in memory; the picture entry follows the last
 * slice entry. Slices and the picture are contiguous in the ring and may wrap the ring end.
 */
#define RTLNET_H264_IDX_ENTRY_BYTES      16u
#define RTLNET_H264_IDX_PIC_MASK         0xFFFFu
#define RTLNET_H264_IDX_SLICE_SHIFT      16u
#define RTLNET_H264_IDX_TYPE_MASK        0xFFu
#define RTLNET_H264_IDX_QP_SHIFT         8u
#define RTLNET_H264_IDX_QP_MASK          0xFFu
#define RTLNET_H264_IDX_LAST             (1u << 16)
#define RTLNET_H264_IDX_IDR              (1u << 17)
#define RTLNET_H264_IDX_KIND_PICTURE     (1u << 24)

/* Video modes (VIDEO_MODE of the camera design): 720p30 is the default, 1080p30 the option. One build codes both: the
 * frame size comes from registers. */
#define RTLNET_H264_MODE_720P30          0u   /* 1280x720, 80 x 45 macroblocks, no cropping, level 3.1 */
#define RTLNET_H264_MODE_1080P30         1u   /* 1920x1080 coded as 1920x1088, 120 x 68 macroblocks, crop 8 lines, level 4.0 */
#define RTLNET_H264_MODE_DEFAULT         RTLNET_H264_MODE_720P30

/* Limits of the stream-parameter writer. */
#define RTLNET_H264_LOG2_FN_MIN          4u
#define RTLNET_H264_LOG2_FN_MAX          16u
#define RTLNET_H264_SPS_PPS_MAX_BYTES    64u   /* a buffer this size always holds the SPS and the PPS */

/* Build parameters read from CAPS. */
typedef struct {
    uint32_t max_mb_w;
    uint32_t max_mb_h;
    uint32_t num_engines;
} rtlnet_h264_enc_caps_t;

/* Picture-level configuration written by rtlnet_h264_enc_configure(). */
typedef struct {
    uint32_t mb_w;
    uint32_t mb_h;
    uint32_t slices;
    uint32_t qp;
    uint32_t log2_max_frame_num;   /* 4..16, equal to the SPS value */
    uint32_t in_base;
    uint32_t in_stride;
    uint32_t ry_base;
    uint32_t ry_stride;
    uint32_t ru_base;
    uint32_t rv_base;
    uint32_t rc_stride;
    uint32_t ring_base;
    uint32_t ring_size;
    uint32_t idx_base;
    uint32_t idx_entries;
} rtlnet_h264_enc_cfg_t;

/* One index-ring entry, decoded. */
typedef struct {
    uint32_t offset;
    uint32_t length;
    uint32_t picture;
    uint32_t slice;
    uint32_t slice_type;
    uint32_t qp;
    int      last_slice;
    int      idr;
    int      is_picture;
} rtlnet_h264_enc_index_entry_t;

/* Frame geometry of one video mode. */
typedef struct {
    uint32_t mb_w;            /* coded width in macroblocks */
    uint32_t mb_h;            /* coded height in macroblocks */
    uint32_t width;           /* coded width in pixels */
    uint32_t height;          /* coded height in pixels (1088 for 1080p) */
    uint32_t display_width;   /* width after SPS cropping */
    uint32_t display_height;  /* height after SPS cropping (1080 for 1080p) */
    uint32_t fps;
    uint32_t level_idc;       /* the level the SPS writer selects for this mode */
} rtlnet_h264_enc_mode_t;

/* Per-picture statistics. */
typedef struct {
    uint32_t mb_count;
    uint32_t cyc_last;
    uint32_t cyc_max;
    uint32_t pic_cyc;
    uint32_t rd_cyc;
    uint32_t pk_cyc;
    uint32_t wr_cyc;
} rtlnet_h264_enc_stats_t;

/* Stream parameters of the SPS and PPS (Constrained Baseline, profile_idc 66). */
typedef struct {
    uint32_t width;                /* coded width in pixels, a multiple of 16 */
    uint32_t height;               /* coded height in pixels, a multiple of 16 (1088 for 1080p) */
    uint32_t display_width;        /* cropped width, even, <= width */
    uint32_t display_height;       /* cropped height, even, <= height (1080 for 1080p) */
    uint32_t fps;                  /* frames per second, selects level_idc with the frame size */
    uint32_t log2_max_frame_num;   /* 4..16 */
} rtlnet_h264_enc_sps_cfg_t;

/*
 * Function rules. Every function returns 0 on success and -1 on failure, and never writes a register of a
 * rejected request: the caller aborts or fixes the request. No function waits unbounded; waiting loops are
 * bounded by the poll count the caller passes.
 */

/* Check ID and VERSION; read the build parameters into caps when it is not NULL. 0 when present. */
int rtlnet_h264_enc_probe(uintptr_t base, rtlnet_h264_enc_caps_t *caps);

/* Geometry of a video mode (720p30 or 1080p30). -1 for any other mode. */
int rtlnet_h264_enc_get_mode(uint32_t video_mode, rtlnet_h264_enc_mode_t *out);

/* Slice band of engine `engine` of `num_engines` for a picture of mb_h macroblock rows: the engines before the last take
 * ceil(mb_h / num_engines) rows each, the last engine the rest (720p with 2 engines: 23 and 22 rows; 1080p: 34 and 34).
 * -1 when an engine would get no row. */
int rtlnet_h264_enc_band_rows(uint32_t mb_h, uint32_t num_engines, uint32_t engine, uint32_t *first_row, uint32_t *rows);

/* Select a video mode: reads CAPS, checks that the picture fits the build and that every engine gets at least one row,
 * writes MB_W and MB_H, and fills sps with the matching SPS/PPS parameters (coded and display size, 30 fps, the
 * log2_max_frame_num held in PIC_CFG) for rtlnet_h264_enc_write_sps_pps(). Writes no register on -1. The core splits
 * the bands itself from MB_H and the engine count; slices per picture (SLICES) stay a multiple of the engine count. */
int rtlnet_h264_enc_set_mode(uintptr_t base, uint32_t video_mode, rtlnet_h264_enc_sps_cfg_t *sps);

/* Check the request against the core's rules (sizes, alignment, caps) and write the configuration
 * registers; the caller then calls rtlnet_h264_enc_ring_reset() once and rtlnet_h264_enc_start_picture(). */
int rtlnet_h264_enc_configure(uintptr_t base, const rtlnet_h264_enc_cfg_t *cfg);

/* Clear the ring and index pointers and fill levels. The core must be idle with the ring consumed. */
void rtlnet_h264_enc_ring_reset(uintptr_t base);

/* Write frame_num, idr_pic_id and the IDR flag, clear DONE, and start one picture. frame_num is 0 for an IDR
 * picture and idr_pic_id differs between consecutive IDR pictures (ITU-T H.264 clause 7.4.3). -1 when the core is busy. */
int rtlnet_h264_enc_start_picture(uintptr_t base, uint32_t frame_num, uint32_t idr_pic_id, int idr);

/* Poll STATUS up to max_polls times for DONE or ERR. Returns 0 on DONE, -1 on ERR (err_code receives the
 * ERR_CODE value when it is not NULL) or when the poll count runs out (err_code gets 0xFF). */
int rtlnet_h264_enc_wait_done(uintptr_t base, uint32_t max_polls, uint32_t *err_code);

/* Read STATUS, clearing nothing. */
uint32_t rtlnet_h264_enc_status(uintptr_t base);

/* Clear the DONE and ERR flags. */
void rtlnet_h264_enc_clear_status(uintptr_t base);

/* Report consumption: set the ring read pointer (byte offset) and the index read pointer (entry index). */
void rtlnet_h264_enc_set_read_pointers(uintptr_t base, uint32_t ring_rptr, uint32_t idx_rptr);

/* Read the index write pointer (index of the next entry the core will write). */
uint32_t rtlnet_h264_enc_index_wptr(uintptr_t base);

/* Decode the 16 bytes of an index entry (words as read from memory, word 0 first). */
void rtlnet_h264_enc_decode_index_entry(const uint32_t words[4], rtlnet_h264_enc_index_entry_t *out);

/* Read the statistics registers. */
void rtlnet_h264_enc_read_stats(uintptr_t base, rtlnet_h264_enc_stats_t *out);

/*
 * Write the Annex B SPS and PPS NAL units into buf: 00 00 00 01 67 <SPS rbsp> 00 00 00 01 68 <PPS rbsp>, with
 * emulation prevention. SPS: profile_idc 66, constraint_set1_flag 1 (Constrained Baseline), level_idc from the
 * frame size and rate (Table A-1), pic_order_cnt_type 2, max_num_ref_frames 1, frame_mbs_only_flag 1,
 * frame cropping to display_width x display_height. PPS: entropy_coding_mode_flag 0 (CAVLC),
 * deblocking_filter_control_present_flag 1, pic_init_qp 26. Returns 0 and the length in *out_len, or -1 when
 * the request is illegal (sizes not macroblock multiples, cropping outside the picture, log2_max_frame_num out
 * of range, level above 5.2) or the buffer is smaller than the stream (RTLNET_H264_SPS_PPS_MAX_BYTES always fits).
 */
int rtlnet_h264_enc_write_sps_pps(uint8_t *buf, size_t cap, const rtlnet_h264_enc_sps_cfg_t *cfg, size_t *out_len);

#endif /* RTLNET_H264_ENC_H */
