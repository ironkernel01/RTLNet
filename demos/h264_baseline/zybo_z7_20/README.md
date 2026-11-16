# H.264 Baseline Camera Demo on the Zybo Z7-20

Revision 11-16-2026

A real camera streamed to a PC: a Digilent Pcam 5C (OV5640 sensor, two MIPI CSI-2 lanes) on a Digilent Zybo Z7-20 (Zynq-7000 XC7Z020). The IronKernel MIPI receiver `rtlnet_csi2_rx` takes the sensor's D-PHY lanes in the FPGA fabric, converts the picture to YUV422 and writes it to the DDR3 memory of the Zynq; one RTLNet H.264 encoder (Constrained Baseline profile, CAVLC, in-loop deblocking filter) reads it back and writes the compressed pictures; a bare-metal firmware on ARM core 0 multiplexes them into MPEG-TS and sends them over UDP through the PS Gigabit Ethernet and lwIP. The stream is 1280 x 720 at 30 pictures per second (every sensor frame) or 1920 x 1080 at 15 pictures per second (every second frame of the 30 fps sensor). There is no time limit and no netlist in this image.
License: `LICENSE.md` in the repository root.

The brief (`h264_baseline_zybo_z7_20_brief.pdf`, `.md`) has the data path, the measured results, the resources and what is not verified.

## What is in this folder

| File | Content |
|---|---|
| `rtlnet_zybo_z7_20.bit` | the bitstream of the FPGA fabric (image `own9`) |
| `rtlnet_zybo.elf` | the firmware for ARM core 0 (build `fw19`), built against the same hardware design |
| `ps7_init.tcl` | the initialization of the Zynq processing system (clocks, DDR3 controller, pins) that belongs to the bitstream; the loader sources it before the bitstream |
| `build_info.txt` | source revision, timing result and utilization of the image |

A Zynq runs nothing from the bitstream alone: the processing system has to be initialized, the bitstream loaded and the firmware started on the ARM core. `boards/zybo_z7_20/scripts/program_demo.ps1` does all three over JTAG from the three files above (it needs no build folder, no XSA and no source). The load is volatile: nothing is written to the QSPI flash or an SD card, and a power cycle removes the image. A boot from the SD card or the QSPI flash has not been built or tested.

## What you need

- Digilent Zybo Z7-20 with its power supply (or a direct PC USB port: through a weak USB port the board lost power as soon as the fabric was configured and the ARM ran) and a micro-USB cable in the PROG UART port (JTAG and the console UART on one cable).
- Digilent Pcam 5C in the Pcam camera connector of the board, with its ribbon cable.
- An Ethernet cable from the board to the network of the PC. A DHCP server on that network gives the board its address (there is no static fallback). The firmware's default MAC address is locally administered and the same on every board: use one board per network.
- On the PC: AMD Vitis or Vivado 2026.1 (the loader runs `xsdb`, which is part of both; the free Vivado license is enough, nothing is built), PowerShell, a serial terminal (PuTTY, Tera Term or similar) at 115200 baud, 8 data bits, no parity, 1 stop bit, and VLC or ffplay (part of FFmpeg).
- The PC's firewall must let UDP port 5004 in, or the player shows nothing.
- Not recorded for the tested board: the positions of the boot-mode and power-source jumpers.

## Steps

1. Program the board over JTAG, from the repository root. The script takes the machine-wide board lock, refuses unless the JTAG chain holds an `xc7z020` device and the Cortex-A9 targets, and runs `ps7_init`, `fpga`, `ps7_post_config`, the download of the ELF to ARM core 0 and `con`. Core 1 is not touched.

   ```
   powershell -NoProfile -ExecutionPolicy Bypass -File boards/zybo_z7_20/scripts/program_demo.ps1
   ```

   The script reads the files of this folder (`demos/h264_baseline/zybo_z7_20`); `-Dir <folder>` selects another folder that holds the same three files. It ends with `RTLNET_ZYBO_PROGRAM: PASS (exit 0)` and prints `core #0 state: Running`. If another JTAG board is on the PC's chain (an Artix-7 board, for example), it is not touched: the loader selects the `xc7z020` device by name.

2. Open the serial console. About 40 seconds after the load the prompt `rtlnet>` appears (sensor start-up and DHCP). Enter privileged mode and look at the board:

   ```
   enable
   show version
   show ip
   ```

   `show version` prints `RTLNet Zybo Z7-20 <revision>`; `show ip` prints `PHY 001cc916 link=1 DHCP=1 IP <board address>` once DHCP has answered.

3. Start the player on the PC first:

   ```
   ffplay -fflags nobuffer udp://@:5004
   ```

   or in VLC: Media, Open Network Stream, `udp://@:5004`.

4. Start the stream to the PC (use the PC's IP address):

   ```
   camera mode 720p30
   stream start <PC address> 5004
   ```

   The picture of the Pcam appears in the player after a second or two. `camera mode 1080p15` (with the stream stopped) selects 1920 x 1080 at 15 pictures per second. The default is constant QP 28 (`encoder qp <n>`); `encoder bitrate <kb/s>` selects constant bit rate (8000 is 8 Mb/s) and `encoder bitrate 0` returns to constant QP; `encoder gop <n>` sets the number of pictures between IDR pictures (default 30).

5. Watch the design while it runs:

   | Command | Shows |
   |---|---|
   | `show camera` | sensor mode and the frame counters: `seen` (frames from the receiver) and `admitted` (frames passed to the encoder) |
   | `show rx` | receiver state, the twelve error counters (all 0 on a healthy link), the Bayer processing settings and the raw maxima of the last frame |
   | `show stream` | `pictures`, `IDR`, `P`, `errors`, MPEG-TS bytes and datagrams, `drops`, `bit/s` |
   | `show encoder` | the same encoder statistics |
   | `rx clear` | clears the receiver counters (read `show rx` again after a few seconds) |

6. `stream stop` ends the stream.

## Expected output

After `camera mode 720p30` and `stream start`, a few seconds into the stream (measured on this image on 11-16-2026 in a dark room; addresses are documentation values):

```
rtlnet# show stream
running=1 size=1280x720 qp=28 gop=30 pictures=277 IDR=10 P=267 errors=0
TS bytes=196460 datagrams=307 drops=0 backlog=0 bit/s=168448
rtlnet# show rx
RX ctrl=0x0d status=0xf61 taps=11,10 settle=28 filter=0x2b00 lines=720 pixels=1280
RX counters ECC_CORR=0 ECC_UNC=0 CRC=0 SOT=0 FRAMES=... DT=0 TRUNC=0 OVF=0 SIZE=0 ORPHAN=0 LEN=0 CLKLOSS=0
```

The bit rate depends on the scene: at constant QP a dark scene needs a few hundred kb/s and a lit, detailed scene several Mb/s. `FRAMES` counts the sensor frames since the last `rx clear` at 30 per second in both modes. After `rx clear` a few seconds into the stream, every counter other than `FRAMES` stays 0 (60 s per mode, `rx_test.ps1`). The counters run from the start of the receiver and are not cleared by a mode change: a read taken right after a mode change showed `CLKLOSS=1` (a clock stop of the sensor during the change, not analysed further), so clear the counters after the stream has started and read them again.

## Host tests

`boards/zybo_z7_20/scripts/stream_test.ps1 -Mode both -Port <console port>` receives the stream on the PC, checks the MPEG-TS structure, the h264 stream and the frame rates and decodes it with ffmpeg; `rx_test.ps1 -Port <console port> -Action counters` reads the receiver counters over 60 seconds per mode. Both take the console port explicitly (`rx_test.ps1` also refuses a missing argument) and the machine-wide board lock. The picture check of `stream_test.ps1` needs a lit scene: a dark room fails its two picture steps (luma range below 40) and passes the other fourteen.

`boards/zybo_z7_20/scripts/demo_captures.ps1 -Port <console port>` takes the decoded frames and the console captures of the brief again; see `../images/README.md`.

## Not verified

Boot from the SD card or the QSPI flash; temperature, supply, other cables, boards and sensors; the non-continuous clock mode; a real sunlit scene with this image (the room was dark); the D-PHY sampling margin over temperature (the static timing of the two high-speed input samplers fails hold and is a named, open deviation; see the brief).
