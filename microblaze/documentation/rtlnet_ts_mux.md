# rtlnet_ts_mux: firmware MPEG-TS multiplexer and H.264 stream session (Phase 2b-3, GOP and P pictures since Phase 2c)

Copyright (C) 2026 IronKernel. All rights reserved.

Revision: 11-11-2026 (the mux runs apart from the encoder: picture queue, resumable send)

## 1. Purpose

Two firmware modules in `microblaze/firmware/src/video/` turn the access units of the two-engine H.264 encoder
(`cores/rtlnet_h264_enc`) into an MPEG-2 transport stream and send it over lwIP UDP:

| File | Role |
|---|---|
| `rtlnet_tsmux.{h,c}` | pure multiplexer: PAT, PMT, PES, PCR, continuity counters, 188-byte packets, seven per datagram; no hardware, no lwIP |
| `rtlnet_venc.{h,c}` | session: frame-buffer take and release, encoder configuration and start, index-ring reading, the picture queue and the mux service (section 5.2), read pointers, statistics, load figures |
| `rtlnet_picq.{h,c}` | queue of coded pictures: a descriptor per picture, coding order, the admit gate; no hardware |
| `rtlnet_muxjob.{h,c}` | resumable send of one queued picture through `tsmux`, a bounded number of bytes per call; no hardware |
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
2. Encoding: poll STATUS; on DONE release the slot, clear DONE, swap the two buffers (`rtlnet_h264_enc_buffers_end`) and queue the picture
   (step 3); on ERR count it and reconfigure at the next picture; a picture that exceeds 500 ms is abandoned.
3. Queue (on DONE): per engine read index entries from the scan position to the picture entry (offset and length of the engine's NAL units of
   the picture), check the delimiter, write a descriptor (section 5.2), run the rate controller on the coded size, push the descriptor. The
   encoder is free at once: `venc_poll` starts the next picture in the same call when a new frame is ready.
4. Mux (every `venc_poll` call): send one chunk of the oldest queued picture (section 5.2).

### 5.2 Queue and resumable mux (Phase 2f)

Before Phase 2f the firmware muxed the whole access unit in one blocking call after DONE, so the encoder was idle for the mux time and a
picture cost T_enc + T_mux. Now the encoder and the mux are independent:

* **Descriptor** (`picq_desc_t`): frame number, picture type, QP written, PTS, the access unit delimiter bytes, the SPS and PPS as they were
  when the picture was coded (an IDR picture; a later profile change rewrites the live copy, not this one), and for every engine the ring offset
  and length of the picture, the ring read pointer and the index read pointer that are free once the picture is sent, and the elementary
  stream size. `muxjob_step` reads everything from it and from the ring, nothing from the live encoder state.
* **Order**: pictures leave in coding order. The rate controller runs at DONE (the sizes are known there), so its order is the coding order
  whatever the multiplexer is doing.
* **Chunks**: each `venc_poll` call, after the DONE and frame checks, sends `MUXJOB_BUDGET` = 5,152 elementary stream bytes (28 packets, four
  datagrams, about 1.2 ms) of the oldest picture and returns; the main loop (console, lwIP, link monitor) runs between chunks. The datagrams are
  byte-identical to a one-call send (host test).
* **Ring space**: the ring read pointers (`RING_RPTR`, `IDX_RPTR` of each engine window, `base + 0x100 x e`) are written when a picture is
  completely sent, not at DONE; the index scan position (`scan_idx`) runs ahead of the index read pointer by the queued pictures.
* **Backlog policy**: a picture is queued from DONE until it is sent. When `PICQ_LIMIT` = 3 pictures are queued and a new frame is ready, the
  frame is skipped: not taken, counted in `dropped pictures` and in its own counter ("frames skipped for the backlog" in `show stream`), and the
  next picture is an IDR picture (as after any dropped picture). The limit follows the rings: a 1080p picture is at most about 0.5 MB at QP 12, so
  one engine's share (4 MiB of the 8 MiB ring, 128 of the 256 index records, about 5 records per picture) holds the limit, the picture being coded
  and the one being sent (5 pictures, 1.3 MiB per engine at the worst case) with room to spare; the encoder's RING_STALL cannot occur. The queue
  has 8 descriptor slots; a push into a full queue is an error that the limit makes unreachable.
* **Latency and PCR**: a picture waits at most `PICQ_LIMIT` picture periods in the queue (3 x 33.3 ms = 100 ms) before its datagrams leave, plus
  the time to send it, so the stream leaves the board up to 100 ms later than with the blocking mux under load, and about 15 ms later than
  the encoder's DONE in steady state at light load (one chunk per main-loop pass). PTS and PCR stay what they were: the PTS is
  `90000 + (frame - first_frame) x step`, the PCR is the PTS minus 9000 ticks (100 ms), so the PCR is monotonic in coding order and its
  lead equals the largest queue delay; a receiver buffering 100 ms or more plays the stream without underflow.
* **Mode change and errors**: while pictures are queued the rings are not reset. A mode change or an encoder error that leaves the rings
  to be reset (`cfg_mode` invalid) waits until the queue is drained, then `configure_mode` resets them.
* **Counters** (`show stream`, cleared with `clear counters`): picture cycle time (begin to begin, minimum, average, maximum), lag at
  `begin_picture` (now minus the frame's time stamp, relative to the smallest lag seen: the capture path stamps `ui_clk` cycles, and the firmware
  tick counts the same 90 MHz clock from another origin), the mux time per picture in three parts (ring read and TS build; the copy of each
  datagram into its pbuf; pbuf allocation, `udp_sendto` with the netif and the DMA, pbuf release), the queue depth now and at the maximum.

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

`microblaze/firmware/test/picq_host_test.c` (`picq_host_test.ps1`) checks the queue: coding order across 40 rounds of wrap-around, the descriptor
contents from push to front, the admit gate at `PICQ_LIMIT` with its refusal count, a push into a full queue and a bad descriptor refused; and
the mux job: three pictures (an IDR picture, a P picture whose engine data wraps the end of the ring share, a P picture ending at the share end)
sent with budgets of 1, 7, 188, 1,024, 5,152 and 99,999 bytes give the same datagrams as one piece through `tsmux` directly, a large budget sends a
picture in one call, a bounded budget needs several, and the random-access flag is on the IDR picture only. `--neg` damages a descriptor after the
push. `txring_host_test.c` (`txring_host_test.ps1`) checks the console transmit ring of `rtlnet_cpu_microblaze.md` section 9.2.
