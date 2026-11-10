# rtlnet_ts_mux: firmware MPEG-TS multiplexer and H.264 stream session (Phase 2b-3)

Copyright (C) 2026 IronKernel. All rights reserved.

Revision: 11-09-2026

## 1. Purpose

Two firmware modules in `microblaze/firmware/src/video/` turn the access units of the two-engine H.264 encoder
(`cores/rtlnet_h264_enc`) into an MPEG-2 transport stream and send it over lwIP UDP:

| File | Role |
|---|---|
| `rtlnet_tsmux.{h,c}` | pure multiplexer: PAT, PMT, PES, PCR, continuity counters, 188-byte packets, seven per datagram; no hardware, no lwIP |
| `rtlnet_venc.{h,c}` | session: frame-buffer take and release, encoder configuration and start, index-ring reading, access-unit assembly, read pointers, statistics, load figures |
| `src/lwip/rtlnet_video_udp.{h,c}` | one unicast `udp_pcb`; copies a datagram into a pbuf and calls `udp_sendto`; retries for at most 2 ms when lwIP has no pbuf or the transmit DMA is busy |

The path is `gige.md` section 9: the datagram leaves through `netif_linkoutput`, the AXI DMA and `cpu_axis_ethernet_stream`; the
checksum offload inserts the IPv4 and UDP checksums.

## 2. Stream layout

* Program 1, transport_stream_id 1, PMT PID 0x1000, video PID 0x0100 (also the PCR PID), stream type 0x1B (H.264).
* Each access unit starts a new datagram with a PAT packet and a PMT packet (each PID has its own continuity counter), then the
  video PES: start code, stream_id 0xE0, PES_packet_length 0, flags 0x84 0xC0, header length 10, PTS and DTS (equal).
* The first video packet carries an adaptation field with the PCR and, for an IDR picture (every picture here), the
  random_access_indicator. The last packet of the access unit is padded with adaptation-field stuffing. Continuity counters step
  per video packet.
* Access unit order: access unit delimiter (6 bytes from engine 0), SPS and PPS (written by `rtlnet_h264_enc_write_sps_pps`, in
  front of every I picture), the rest of engine 0's NAL units (slice), engine 1's NAL units (slice).
* Seven packets per datagram (1316 bytes); the last datagram of an access unit is shorter.

## 3. Time base

The 90 kHz time base is the frame number (the cpu_clk at 90 MHz is not the source: the PTS must step by exactly 3000 per picture, and a counter
running from the 90 MHz timer divided by 1000 would jitter by a timer tick against the frame instants; the frame numbers come from the
100 MHz `ui_clk` of the capture path): PTS (and DTS) of a picture is `90000 + (frame - first_frame) x step`, with
`step = round(FRAME_PERIOD x 9 / 10000)` from `rtlnet_csi2_rx` (3000 at 30 fps, 6000 at 15 fps). The frame numbers are stamped by
the capture path from `ui_clk`, so the count is exact and a frame the encoder skips shows as a PTS gap of two steps. The PCR is the
PTS minus 9000 ticks (100 ms of receiver buffering).

## 4. Memory map (DDR3 byte offsets; CPU address = DDR3 window + offset)

| Region | Offset | Size |
|---|---|---|
| frame buffer (3 slots) | 0x1000_0000 | 12 MiB (`gige.md` section 6) |
| rebuilt picture Y / Cb / Cr | 0x1100_0000 / 0x1130_0000 / 0x1138_0000 | strides 2048 / 1024 / 1024 |
| compressed rings | 0x1200_0000 | 8 MiB, split by the core into one share per engine (4 MiB each) |
| index rings | 0x1300_0000 | 256 entries of 16 bytes, 128 per engine |

The rings are read through the data cache: the lines of each chunk are invalidated first (`plat_dcache_invalidate_range`); the cache
is write-through, so no dirty line exists in these regions.

## 5. Picture flow (`venc_poll`, from the main loop)

1. Idle: LATEST_VALID set and LATEST_FRAME different from the last coded frame: take the slot (`rtlnet_framebuf_fw_take`, the
   firmware reader), map 1280x720 to mode 0 and 1920x1080 to mode 1, configure on a mode change (`set_mode`, SPS and PPS, ring
   reset), write the picture configuration (QP, input base, stride from the S2MM STRIDE register), `start_picture` (IDR, frame_num 0,
   idr_pic_id alternating).
2. Encoding: poll STATUS; on DONE release the slot, clear DONE, and mux; on ERR count it and reconfigure at the next picture; a picture that
   exceeds 500 ms is abandoned.
3. Mux: per engine read index entries from the read pointer to the picture entry (offset and length of the engine's NAL units of
   the picture), check the delimiter, feed the access unit through `tsmux_au_data` in chunks of 1 KiB, then write `RING_RPTR` and
   `IDX_RPTR` of each engine window (`base + 0x100 x e`).

One take and one release cover a picture (both engines read the same slot, the firmware is the one reader). With the firmware as the
only reader, `N = readers + 2 = 3` slots hold (`rtlnet_nexys_video.md` section 6.11). `framebuffer crc` uses the same firmware
reader: while a picture is encoded the take fails with the "already holds a slot" message and the command is repeated.

## 6. CLI

| Command | Mode | Action |
|---|---|---|
| `stream h264 <ip> <port>` | priv | start the stream (UDP socket to the host; VLC: `udp://@:<port>`) |
| `stream stop` | priv | stop it, release the slot, close the socket |
| `encoder qp <n>` | priv | fixed QP 0..51 for the next picture (default 28; the driver writes at least 12) |
| `show stream` | exec | pictures sent, dropped pictures (skipped frame numbers), ES and TS bytes, bit rate, TS packets, datagrams, UDP counters, mux and handling CPU load, frame-buffer drops |
| `show encoder` | exec | identity, build, QP, STATUS, ERR_CODE, per-engine cycle statistics (`PIC_CYC`, `CYC_LAST`, `CYC_MAX`, `RD_CYC`, `PK_CYC`, `WR_CYC`) |

`clear counters` also clears the stream counters.

## 7. CPU load

`show stream` reports, over the last full second, the TS mux busy time (access-unit build and UDP send, including the retry waits in lwIP)
and the handling busy time (take, configure, start, release and mux), both as a share of the `cpu_clk` ticks (90 MHz) read from the
free-running timer. Results per mode are in `rtlnet_nexys_video.md` section 6.11.

## 8. Host test

`microblaze/firmware/test/tsmux_host_test.c` (run by `tsmux_host_test.ps1`, part of `scripts/rtlnet_regression.ps1`) feeds 21 access units
of 0 to 200,000 bytes (sizes around the stuffing cases 164 to 185 and 358 to 361 bytes) in random pieces and parses the datagrams with an
independent checker: sync bytes, seven packets per datagram, PIDs, continuity counters per PID, PAT and PMT contents and CRC-32 (bitwise
reference, check value 0x0376E6E7), PES header, PTS and DTS including a value above 2^32, PCR, random-access flag, stuffing bytes, and the
reassembled elementary stream. `--neg` damages one continuity counter and passes only when the checker reports it.
