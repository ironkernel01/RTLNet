# H.264 Baseline Encoder on the Nexys Video

Revision 11-13-2026

The public RTLNet H.264 encoder: Constrained Baseline profile (CAVLC), in-loop deblocking filter, two engines, 1080p30 and 720p30.
The board generates test patterns, encodes them and sends an MPEG-TS stream over UDP. There is no time limit.
License: `LICENSE.md` in the repository root.

## What you need

- Digilent Nexys Video board, its power supply and two USB cables (PROG for JTAG, UART for the console).
- An Ethernet cable from the board to the network of the PC. A DHCP server on that network gives the board its address.
- Vivado 2026.1 with its free license, to program the board.
- A terminal on the board's USB serial port at 115200 baud, 8N1.
- VLC or ffplay on the PC.

## Steps

1. Program the board over JTAG. The image is not written to the flash; it is gone after a power cycle.

   ```
   powershell -NoProfile -ExecutionPolicy Bypass -File boards/nexys_video/scripts/program.ps1 -Bit demos/h264_baseline/nexys_video/rtlnet_nexys_video.bit
   ```

2. Open the serial console. `show ip` prints the board's address once DHCP has answered.

3. Start the player on the PC first:

   ```
   ffplay -fflags nobuffer udp://@:5004
   ```

   or in VLC: Media, Open Network Stream, `udp://@:5004`.

4. On the console choose the picture and start the stream to the PC (use the PC's IP address):

   ```
   camera mode 1080p30
   camera pattern all 4
   encoder bitrate 8000
   stream h264 <PC address> 5004
   ```

   `camera mode 720p30` selects 720p. The patterns are `bars`, `scroll`, `box`, `noise` and `all`; the number is the speed.

5. Watch the encoder: `show stream` and `show encoder` print the picture counts, the bit rate, dropped pictures and the encoder state.

6. `stream stop` ends the stream.

## Useful commands

| Command | Effect |
|---|---|
| `encoder bitrate <kb/s>` | constant bit rate; `encoder bitrate 0` returns to constant QP |
| `encoder qp <n>` | the QP for constant-QP operation |
| `encoder gop <n>` | pictures between IDR pictures |
| `encoder deblock on` / `encoder deblock off` | the in-loop deblocking filter |
| `encoder notify interrupt` / `encoder notify polled` | how the firmware learns of a finished picture |

`build_info.txt` in this folder lists the source revision, the timing result and the utilization of the image.
