/*
 * rtlnet_tsmux.c -- MPEG-2 transport stream multiplexer for one H.264 video elementary stream
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: implementation of the contract in rtlnet_tsmux.h.
 *
 * Revision: 11-09-2026
 */
#include "rtlnet_tsmux.h"

#include <string.h>   /* memcpy, memmove, memset */

#define PCR_FLAG         0x10u
#define RAI_FLAG         0x40u
#define PUSI_FLAG        0x40u
#define AF_PCR_BYTES     8u    /* adaptation_field_length, flags, 6 PCR bytes */

/* crc_update -- CRC-32/MPEG-2 over a buffer, bitwise (called twice per access unit on 17 and 21 bytes). */
static uint32_t crc_update(uint32_t crc, const uint8_t *p, uint32_t n)
{
    while (n-- != 0u) {
        crc ^= (uint32_t)(*p++) << 24;
        for (int b = 0; b < 8; b++) {
            crc = ((crc & 0x80000000u) != 0u) ? ((crc << 1) ^ 0x04C11DB7u) : (crc << 1);
        }
    }
    return crc;
}

uint32_t tsmux_crc32_mpeg(const uint8_t *data, uint32_t len)
{
    return crc_update(0xFFFFFFFFu, data, len);
}

/*
 * dgram_flush -- hand the complete packets in the buffer to the sink and empty the buffer.
 * A refused datagram is counted and dropped; the continuity counters make the loss visible to the receiver.
 */
static void dgram_flush(tsmux_t *m)
{
    if (m->fill == 0u) {
        return;
    }
    if (m->sink != NULL && m->sink(m->ctx, m->dgram, m->fill) != 0) {
        m->sink_errors++;
    } else {
        m->datagrams++;
        m->bytes += m->fill;
    }
    m->fill = 0u;
}

/* pkt_done -- one packet of 188 bytes at dgram + fill is complete: count it, flush at seven. */
static void pkt_done(tsmux_t *m)
{
    m->fill += TSMUX_PKT_BYTES;
    m->packets++;
    if (m->fill >= TSMUX_DGRAM_BYTES) {
        dgram_flush(m);
    }
}

/*
 * psi_packet -- one PSI packet: header, pointer_field 0, the section with its CRC-32, 0xFF padding.
 * pid and cc select the PID and its counter; section is the section without CRC, len its length.
 */
static void psi_packet(tsmux_t *m, uint16_t pid, uint8_t *cc, const uint8_t *section, uint32_t len)
{
    uint8_t *p = &m->dgram[m->fill];
    uint32_t crc = tsmux_crc32_mpeg(section, len);
    memset(p, 0xFF, TSMUX_PKT_BYTES);
    p[0] = 0x47u;
    p[1] = (uint8_t)(PUSI_FLAG | (pid >> 8));
    p[2] = (uint8_t)pid;
    p[3] = (uint8_t)(0x10u | (*cc & 0x0Fu));
    *cc = (uint8_t)((*cc + 1u) & 0x0Fu);
    p[4] = 0u;   /* pointer_field */
    memcpy(&p[5], section, len);
    p[5 + len]     = (uint8_t)(crc >> 24);
    p[5 + len + 1] = (uint8_t)(crc >> 16);
    p[5 + len + 2] = (uint8_t)(crc >> 8);
    p[5 + len + 3] = (uint8_t)crc;
    pkt_done(m);
}

/* put_pts -- the 5-byte PES timestamp field with prefix nibble (0011 PTS with DTS following, 0001 DTS). */
static void put_pts(uint8_t *p, uint8_t prefix, uint64_t t)
{
    p[0] = (uint8_t)((prefix << 4) | (((t >> 30) & 0x07u) << 1) | 1u);
    p[1] = (uint8_t)(t >> 22);
    p[2] = (uint8_t)((((t >> 15) & 0x7Fu) << 1) | 1u);
    p[3] = (uint8_t)(t >> 7);
    p[4] = (uint8_t)(((t & 0x7Fu) << 1) | 1u);
}

/*
 * pkt_open -- start a video packet at dgram + fill. The first packet of an access unit has PUSI and the PCR
 * adaptation field (flags: PCR, plus random access when requested); later packets have payload only.
 */
static void pkt_open(tsmux_t *m)
{
    uint8_t *p = &m->dgram[m->fill];
    p[0] = 0x47u;
    p[1] = (uint8_t)((m->first ? PUSI_FLAG : 0u) | (TSMUX_PID_VIDEO >> 8));
    p[2] = (uint8_t)TSMUX_PID_VIDEO;
    if (m->first) {
        uint64_t base = m->pcr90 & 0x1FFFFFFFFull;
        p[3] = (uint8_t)(0x30u | (m->cc_video & 0x0Fu));
        p[4] = (uint8_t)(AF_PCR_BYTES - 1u);
        p[5] = (uint8_t)(PCR_FLAG | (m->random_access ? RAI_FLAG : 0u));
        p[6]  = (uint8_t)(base >> 25);
        p[7]  = (uint8_t)(base >> 17);
        p[8]  = (uint8_t)(base >> 9);
        p[9]  = (uint8_t)(base >> 1);
        p[10] = (uint8_t)(((base & 1u) << 7) | 0x7Eu);   /* 6 reserved bits set, extension bit 8 = 0 */
        p[11] = 0u;                                       /* extension 0 */
        m->hdr = 4u + AF_PCR_BYTES;
    } else {
        p[3] = (uint8_t)(0x10u | (m->cc_video & 0x0Fu));
        m->hdr = 4u;
    }
    m->cc_video = (uint8_t)((m->cc_video + 1u) & 0x0Fu);
    m->pay = 0u;
    m->open = 1;
    m->first = 0;
}

void tsmux_init(tsmux_t *m, tsmux_sink_fn sink, void *ctx)
{
    memset(m, 0, sizeof(*m));
    m->sink = sink;
    m->ctx = ctx;
}

void tsmux_clear_counters(tsmux_t *m)
{
    m->packets = 0u;
    m->datagrams = 0u;
    m->bytes = 0u;
    m->sink_errors = 0u;
    m->access_units = 0u;
}

/*
 * tsmux_au_begin -- PAT, PMT, then the video PES header as the first payload bytes.
 * PAT section (8 bytes + one program entry): table_id 0, section_length 13, transport_stream_id 1, version 0 current,
 * program 1 -> PMT PID. PMT section: table_id 2, section_length 18, program 1, PCR PID = video PID, no program
 * descriptors, one stream (type 0x1B, video PID, no descriptors).
 */
void tsmux_au_begin(tsmux_t *m, uint64_t pts90, uint64_t pcr90, int random_access)
{
    uint8_t pat[12];
    uint8_t pmt[17];
    uint8_t pes[TSMUX_PES_HDR_BYTES];

    dgram_flush(m);   /* an access unit starts a datagram */
    pat[0] = 0x00u;
    pat[1] = 0xB0u;
    pat[2] = 13u;
    pat[3] = 0x00u; pat[4] = 0x01u;
    pat[5] = 0xC1u;
    pat[6] = 0x00u; pat[7] = 0x00u;
    pat[8] = (uint8_t)(TSMUX_PROGRAM >> 8); pat[9] = (uint8_t)TSMUX_PROGRAM;
    pat[10] = (uint8_t)(0xE0u | (TSMUX_PID_PMT >> 8)); pat[11] = (uint8_t)TSMUX_PID_PMT;
    psi_packet(m, TSMUX_PID_PAT, &m->cc_pat, pat, sizeof(pat));

    pmt[0] = 0x02u;
    pmt[1] = 0xB0u;
    pmt[2] = 18u;
    pmt[3] = (uint8_t)(TSMUX_PROGRAM >> 8); pmt[4] = (uint8_t)TSMUX_PROGRAM;
    pmt[5] = 0xC1u;
    pmt[6] = 0x00u; pmt[7] = 0x00u;
    pmt[8] = (uint8_t)(0xE0u | (TSMUX_PID_VIDEO >> 8)); pmt[9] = (uint8_t)TSMUX_PID_VIDEO;
    pmt[10] = 0xF0u; pmt[11] = 0x00u;
    pmt[12] = TSMUX_STREAM_TYPE_H264;
    pmt[13] = (uint8_t)(0xE0u | (TSMUX_PID_VIDEO >> 8)); pmt[14] = (uint8_t)TSMUX_PID_VIDEO;
    pmt[15] = 0xF0u; pmt[16] = 0x00u;
    psi_packet(m, TSMUX_PID_PMT, &m->cc_pmt, pmt, sizeof(pmt));

    m->first = 1;
    m->open = 0;
    m->pcr90 = pcr90;
    m->random_access = random_access;
    pes[0] = 0x00u; pes[1] = 0x00u; pes[2] = 0x01u; pes[3] = TSMUX_PES_STREAM_ID;
    pes[4] = 0x00u; pes[5] = 0x00u;           /* PES_packet_length 0: unbounded */
    pes[6] = 0x84u;                           /* marker 10, data_alignment_indicator 1 */
    pes[7] = 0xC0u;                           /* PTS and DTS present */
    pes[8] = 10u;                             /* PES header data length */
    put_pts(&pes[9], 0x3u, pts90 & 0x1FFFFFFFFull);
    put_pts(&pes[14], 0x1u, pts90 & 0x1FFFFFFFFull);
    m->access_units++;
    tsmux_au_data(m, pes, sizeof(pes));
}

void tsmux_au_data(tsmux_t *m, const uint8_t *data, uint32_t len)
{
    while (len != 0u) {
        uint32_t room;
        uint32_t n;
        if (!m->open) {
            pkt_open(m);
        }
        room = TSMUX_PKT_BYTES - m->hdr - m->pay;
        n = (len < room) ? len : room;
        memcpy(&m->dgram[m->fill + m->hdr + m->pay], data, n);
        m->pay += n;
        data += n;
        len -= n;
        if (m->hdr + m->pay == TSMUX_PKT_BYTES) {
            m->open = 0;
            pkt_done(m);
        }
    }
}

/*
 * tsmux_au_end -- pad the open packet. With stuffing s = 188 - header - payload bytes missing: a packet that already
 * has the PCR adaptation field grows it by s stuffing bytes; a plain payload packet gets an adaptation field of s bytes
 * (length byte, flags byte 0, s - 2 stuffing bytes; for s = 1 the length byte alone, value 0). The payload moves up behind it.
 */
void tsmux_au_end(tsmux_t *m)
{
    if (m->open) {
        uint8_t *p = &m->dgram[m->fill];
        uint32_t s = TSMUX_PKT_BYTES - m->hdr - m->pay;
        if (s != 0u) {
            if (m->hdr == 4u) {
                memmove(&p[4 + s], &p[4], m->pay);
                p[3] = (uint8_t)(0x30u | (p[3] & 0x0Fu));
                p[4] = (uint8_t)(s - 1u);
                if (s >= 2u) {
                    p[5] = 0u;
                    memset(&p[6], 0xFF, s - 2u);
                }
            } else {
                memmove(&p[m->hdr + s], &p[m->hdr], m->pay);
                p[4] = (uint8_t)(p[4] + s);
                memset(&p[m->hdr], 0xFF, s);
            }
        }
        m->open = 0;
        pkt_done(m);
    }
    dgram_flush(m);
}
