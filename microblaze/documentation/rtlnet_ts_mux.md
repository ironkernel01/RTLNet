# rtlnet_ts_mux: firmware MPEG-TS multiplexer and H.264 stream session (Phase 2b-3, GOP and P pictures since Phase 2c)

Copyright (C) 2026 IronKernel. All rights reserved.

Revision: 11-10-2026

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
* The first video packet carries an adaptation field with the PCR and, for an IDR picture only, the random_access_indicator. The
  PCR stays on every access unit: ISO/IEC 13818-1 requires a PCR at least every 100 ms, and an IDR every 30 pictures (1 s) would
  break that. P pictures carry the PCR and no random-access indicator. The PES header (PTS, DTS, flags) is the same for both
  picture types. The last packet of the access unit is padded with adaptation-field stuffing. Continuity counters step
  per video packet.
* Access unit order: access unit delimiter (6 bytes from engine 0), SPS and PPS (written by `rtlnet_h264_enc_write_sps_pps`, in
  front of every IDR picture only), the rest of engine 0's NAL units (slice), engine 1's NAL units (slice). A P access unit is the
  delimiter and the slices.
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
| rebuilt picture A, luma tiles / chroma tiles | 0x1100_0000 / 0x1120_0000 | 256 B and 128 B per macroblock (macroblock-tiled, raster order), 2 MiB areas; 1080p needs 2,088,960 B and 1,044,480 B (3,133,440 B per picture) |
| rebuilt picture B, luma tiles / chroma tiles | 0x1140_0000 / 0x1160_0000 | the second rebuilt buffer (Phase 2c, 2 MiB areas, 3,133,440 B used at 1080p): the encoder writes A and B alternately and a P picture reads the other one, the previous picture, as its reference |
| compressed rings | 0x1200_0000 | 8 MiB, split by the core into one share per engine (4 MiB each) |
| index rings | 0x1300_0000 | 256 records of 128 bytes (32 KiB), 128 per engine |

The rebuilt picture is written by the encoder (one 16-beat burst for the luma tile and one 8-beat burst for the chroma tile of each
macroblock) and, from Phase 2c, read back by the encoder as the reference of the next P picture (the motion search window reads); the firmware
never reads it. The areas are clear of the frame buffer (0x1000_0000 to 0x10C0_0000), the rings (0x1200_0000), the index records (0x1300_0000), the
`ddr test` region (from offset 0, at most 64 MiB) and the DDR3 firmware image (offset 0, 64 MiB). An index record is one 8-beat burst of 128 bytes: the four entry words
(`rtlnet_h264_enc.md` section 7) in the first 16 bytes and 112 reserved bytes written as zero; the firmware reads the first 16 bytes
(`RTLNET_H264_IDX_ENTRY_BYTES` is the record pitch, `RTLNET_H264_IDX_WORDS` the entry words). The record is 128 bytes so that every index
write is a burst of 8 beats (the DDR3 rule: no single-beat transaction); the index ring holds a few records per picture, so the
extra 112 bytes cost nothing measurable (5 records per picture at 2 engines and 2 slices).

The rings and the index records are written by hardware and read by the CPU through the data cache, which is write-back with 64-byte lines
(8 KiB, over the DDR3 window). Before every read the lines of the range are invalidated (`plat_dcache_invalidate_range`, whole 64-byte
lines); the CPU never writes these regions, so no dirty line exists in them and the invalidate cannot discard CPU data. The rings and the
index ring are 64-byte aligned (offsets 0x1200_0000 and 0x1300_0000, records of 128 bytes). The CPU's own DDR3 stores
(only the `ddr test` region) are written back with `plat_dcache_flush_range` before hardware or the test's read-back needs them.

## 5. Picture flow (`venc_poll`, from the main loop)

1. Idle: LATEST_VALID set and LATEST_FRAME different from the last coded frame: take the slot (`rtlnet_framebuf_fw_take`, the
   firmware reader), map 1280x720 to mode 0 and 1920x1080 to mode 1, configure on a mode change (`set_mode`, SPS and PPS, ring
   reset), write the picture configuration (QP, input base, stride from the S2MM STRIDE register), choose the picture type (below), write
   the rebuilt and reference bases of the two buffers (`rtlnet_h264_enc_buffers_begin`) and `rtlnet_h264_enc_start_picture_ex`: an IDR
   picture has frame_num 0 and an idr_pic_id that alternates 0 and 1 per IDR picture; a P picture has `rtlnet_h264_enc_next_frame_num`
   of the previous picture (the driver's wrap rule at 2^4). The padding lines of the slot below the display height (1080 to 1087 at
   1080p) are filled once per slot and mode (section 5.1).
2. Encoding: poll STATUS; on DONE release the slot, clear DONE, swap the two buffers (`rtlnet_h264_enc_buffers_end`) and mux; on ERR count it and reconfigure at the next picture; a picture that
   exceeds 500 ms is abandoned.
3. Mux: per engine read index entries from the read pointer to the picture entry (offset and length of the engine's NAL units of
   the picture), check the delimiter, feed the access unit through `tsmux_au_data` in chunks of 1 KiB, then write `RING_RPTR` and
   `IDX_RPTR` of each engine window (`base + 0x100 x e`).

### 5.1 GOP, IDR and P pictures (Phase 2c)

The picture type follows `encoder gop <n>` (1..255, default 30): the first picture after a start, and every n-th picture after it, is an IDR
picture; the others are P pictures that reference the previous picture's rebuilt buffer (one reference frame, `max_num_ref_frames` 1). GOP 1 makes every
picture an IDR picture. The next picture is an IDR picture, whatever the GOP position, after: a stream start, a dropped picture (a jump in the frame
numbers), a mode change, an encoder error, a timeout and a failed mux. So a P picture never references a picture
that was not coded or that was coded under another mode. A QP change does not force an IDR picture: the slice QP of an H.264 P picture is free (the
slice header carries `slice_qp_delta`), so `encoder qp` and the per-picture QP of the rate controller (`rtlnet_ratectl.md`) change it at any picture.
The index entry of a P picture is a picture entry like an IDR picture's; the firmware
knows the type it started and does not read it back. The counters of `show stream` (`GOP` line) split the pictures into IDR and P with the
average elementary-stream bytes of each.

The video write DMA writes only the picture's 1080 lines; the encoder reads 1088 (68 macroblock rows). Lines 1080 to 1087 of a slot therefore held
whatever the DDR3 had before. The firmware writes the last picture line into those lines once per slot and mode (the slot is held, so the DMA is not
writing it; `plat_dcache_flush_range` after the copy). Without it a slot with stale lines coded 11 kB more and made P pictures across that slot non-skip
(`rtlnet_nexys_video.md` section 6.13).

One take and one release cover a picture (both engines read the same slot, the firmware is the one reader). With the firmware as the
only reader, `N = readers + 2 = 3` slots hold (`rtlnet_nexys_video.md` section 6.11). `framebuffer crc` uses the same firmware
reader: while a picture is encoded the take fails with the "already holds a slot" message and the command is repeated.

## 6. CLI

| Command | Mode | Action |
|---|---|---|
| `stream h264 <ip> <port>` | priv | start the stream (UDP socket to the host; VLC: `udp://@:<port>`) |
| `stream stop` | priv | stop it, release the slot, close the socket |
| `encoder qp <n>` | priv | QP of constant QP mode, 0..51 for the next picture (default 28; the driver writes at least 12); it does not force an IDR picture |
| `encoder bitrate <kbps>` | priv | constant bit rate target 0..100000 kb/s; 0 = constant QP (default); see `rtlnet_ratectl.md` |
| `encoder buffer <ms>` | priv | rate control virtual buffer 100..2000 ms of the target rate (default 500) |
| `encoder qprange <min> <max>` | priv | rate control QP range, 12 <= min <= max <= 51 (default 12 51) |
| `encoder gop <n>` | priv | GOP length 1..255 (default 30): an IDR picture every n pictures, P pictures between; 1 = all IDR |
| `show encoder history [n]` | exec | the per-second record: bits, mean QP, buffer fill and pictures of the last n seconds (default 20, at most 3600), oldest first |
| `show stream` | exec | rate-control lines (mode and target, measured rate over 1 s and 10 s, buffer fill, QP, overflow and underflow counts, test pattern), GOP, IDR and P picture counts with their average bytes, pictures sent, dropped pictures (skipped frame numbers), ES and TS bytes, bit rate, TS packets, datagrams, UDP counters, mux and handling CPU load, frame-buffer drops |
| `show encoder` | exec | identity, build, QP, GOP and the type of the last picture, the rate-control lines of `show stream`, STATUS, ERR_CODE, per-engine cycle statistics (`PIC_CYC`, `CYC_LAST`, `CYC_MAX`, `RD_CYC`, `PK_CYC`, `WR_CYC`) |

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
