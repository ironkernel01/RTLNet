/*
 * rtlnet_tsmux.h -- MPEG-2 transport stream multiplexer for one H.264 video elementary stream
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: turns access units (Annex B H.264) into 188-byte transport stream packets and hands them to a sink seven
 * packets (1316 bytes) per datagram, the UDP payload VLC and FFmpeg read from udp://@:port. Pure C with no hardware and no
 * lwIP, so the host test (test/tsmux_host_test.c) checks it byte for byte.
 *
 * Stream layout (ISO/IEC 13818-1): program 1, PMT PID 0x1000, video PID 0x0100 (also the PCR PID), stream type 0x1B (H.264),
 * transport_stream_id 1. Every access unit starts a new datagram with a PAT packet and a PMT packet (continuity counters of
 * their own PIDs), then the video PES packet: PES stream_id 0xE0, PES_packet_length 0 (unbounded, allowed for video),
 * PTS and DTS (equal) in 90 kHz units. The first video packet of an access unit carries an adaptation field with the PCR
 * (27 MHz value pcr90 * 300, extension 0) and, for a random-access picture, the random_access_indicator. The last packet
 * of an access unit is padded with adaptation-field stuffing bytes, so no PES data of the next picture shares a packet.
 * The continuity counter of the video PID steps for every video packet (payload present), of PAT and PMT once per packet.
 *
 * Use: tsmux_init; per access unit tsmux_au_begin, any number of tsmux_au_data calls (the bytes in order), tsmux_au_end.
 * The datagram buffer is filled in place (one copy of the payload); the sink is called with a complete datagram of 1316
 * bytes, or the shorter last datagram of an access unit, and returns 0 when it sent the datagram.
 *
 * This header holds the types and the function contract; rtlnet_tsmux.c holds the per-function commentary.
 *
 * Revision: 11-09-2026
 */
#ifndef RTLNET_TSMUX_H
#define RTLNET_TSMUX_H

#include <stdint.h>   /* uint8_t, uint32_t, uint64_t */

#define TSMUX_PKT_BYTES        188u
#define TSMUX_PKTS_PER_DGRAM   7u
#define TSMUX_DGRAM_BYTES      (TSMUX_PKT_BYTES * TSMUX_PKTS_PER_DGRAM)
#define TSMUX_PID_PAT          0x0000u
#define TSMUX_PID_PMT          0x1000u
#define TSMUX_PID_VIDEO        0x0100u
#define TSMUX_PROGRAM          1u
#define TSMUX_STREAM_TYPE_H264 0x1Bu
#define TSMUX_PES_STREAM_ID    0xE0u
#define TSMUX_PES_HDR_BYTES    19u   /* start code 3, stream_id 1, length 2, flags 2, header length 1, PTS 5, DTS 5 */

/* Sink: send one datagram; 0 on success, nonzero when it was dropped. */
typedef int (*tsmux_sink_fn)(void *ctx, const uint8_t *dgram, uint32_t len);

typedef struct {
    tsmux_sink_fn sink;
    void         *ctx;
    uint8_t       cc_pat;
    uint8_t       cc_pmt;
    uint8_t       cc_video;
    uint8_t       dgram[TSMUX_DGRAM_BYTES];
    uint32_t      fill;          /* bytes of complete packets in dgram */
    int           open;          /* a video packet is being filled at dgram + fill */
    uint32_t      hdr;           /* header bytes of the open packet (4, or 12 with the PCR adaptation field) */
    uint32_t      pay;           /* payload bytes in the open packet */
    int           first;         /* the open packet is the first of the access unit */
    uint64_t      pcr90;         /* PCR base of the current access unit */
    int           random_access;
    /* counters, cleared by tsmux_clear_counters */
    uint32_t      packets;       /* TS packets built */
    uint32_t      datagrams;     /* datagrams handed to the sink */
    uint32_t      bytes;         /* bytes handed to the sink */
    uint32_t      sink_errors;   /* datagrams the sink refused */
    uint32_t      access_units;
} tsmux_t;

/* Reset the multiplexer: counters, continuity counters and buffers to zero. */
void tsmux_init(tsmux_t *m, tsmux_sink_fn sink, void *ctx);

/* Clear the counters only (continuity counters keep running). */
void tsmux_clear_counters(tsmux_t *m);

/* Start an access unit: PAT and PMT packets, then the PES header with pts90 (and DTS = pts90) and the PCR pcr90, both in 90 kHz
 * units, 33 bits. random_access 1 sets the random_access_indicator (an IDR picture). */
void tsmux_au_begin(tsmux_t *m, uint64_t pts90, uint64_t pcr90, int random_access);

/* Append len bytes of the access unit's elementary stream. */
void tsmux_au_data(tsmux_t *m, const uint8_t *data, uint32_t len);

/* Finish the access unit: pad and emit the last packet, send the last datagram. */
void tsmux_au_end(tsmux_t *m);

/* CRC-32/MPEG-2 (polynomial 0x04C11DB7, initial value 0xFFFFFFFF, no reflection, no final XOR) of len bytes. */
uint32_t tsmux_crc32_mpeg(const uint8_t *data, uint32_t len);

#endif /* RTLNET_TSMUX_H */
