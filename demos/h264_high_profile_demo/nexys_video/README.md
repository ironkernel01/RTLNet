# H.264 High Profile Demonstration on the Nexys Video

Revision 11-13-2026

The RTLNet H.264 encoder with the High profile extension: CABAC entropy coding, in-loop deblocking filter, two engines, 1080p30 and 720p30.
The board generates test patterns, encodes them and sends an MPEG-TS stream over UDP.

This is the demonstration form: **High profile runs for 30 minutes after each configuration of the FPGA.** At the end of the 30 minutes the
encoder sends one IDR picture and continues in Constrained Baseline; the stream does not stop. Programming the board again starts a new 30 minutes.

License: `LICENSE_DEMO.md` in the `demos` folder. The extension without the time limit is a paid feature: a paid license from IronKernel (ironkernel.com).

The demonstration is this bitstream only. Using the High profile extension in your own design or in simulation needs a paid license.

## What you need

- Digilent Nexys Video board, its power supply and two USB cables (PROG for JTAG, UART for the console).
- An Ethernet cable from the board to the network of the PC. A DHCP server on that network gives the board its address.
- Vivado 2026.1 with its free license, to program the board.
- A terminal on the board's USB serial port at 115200 baud, 8N1.
- VLC or ffplay on the PC.

## Steps

1. Program the board over JTAG. The image is not written to the flash; it is gone after a power cycle.

   ```
   powershell -NoProfile -ExecutionPolicy Bypass -File boards/nexys_video/scripts/program.ps1 -Bit demos/h264_high_profile_demo/nexys_video/rtlnet_nexys_video.bit
   ```

2. Open the serial console. `show ip` prints the board's address once DHCP has answered.

3. Start the player on the PC first:

   ```
   ffplay -fflags nobuffer udp://@:5004
   ```

   or in VLC: Media, Open Network Stream, `udp://@:5004`.

4. On the console choose the picture, select High profile and start the stream to the PC (use the PC's IP address):

   ```
   enable
   camera mode 1080p30
   camera pattern all 4
   encoder bitrate 8000
   encoder profile high
   stream h264 <PC address> 5004
   ```

   `enable` enters privileged mode, which the camera, encoder and stream commands need. `camera mode 720p30` selects 720p. The patterns are `bars`, `scroll`, `box`, `noise` and `all`; the number is the speed.

5. Watch the encoder: `show stream` and `show encoder` print the picture counts, the bit rate, dropped pictures and the encoder state.
   The High profile line of `show encoder` gives the license state and the time left.

6. `stream stop` ends the stream.

## Link speed

The board negotiates 10/100/1000 Mb/s full duplex after programming and takes the best rate both sides support.
The demos run at 100 Mb/s and at 1000 Mb/s. Set the speed before `stream h264`. `speed` takes `10`, `100` or `auto`;
the last `speed` command is the one in force.

Run at 100 Mb/s (full duplex):

```
enable
configure terminal
interface eth0
speed 100
end
```

Return to 10/100/1000 Mb/s, best rate:

```
enable
configure terminal
interface eth0
speed auto
end
```

`speed 10` selects 10 Mb/s. The link returns in 3 to 4 s and the DHCP address stays the same. `show phy` prints the link
speed, the advertised modes and the partner's modes.

## Useful commands

| Command | Effect |
|---|---|
| `encoder profile high` / `encoder profile baseline` | High profile (CABAC) or Constrained Baseline (CAVLC) |
| `encoder bitrate <kb/s>` | constant bit rate; the value is in kb/s (8000 is 8 Mb/s); `encoder bitrate 0` returns to constant QP |
| `encoder qp <n>` | the QP for constant-QP operation |
| `encoder gop <n>` | pictures between IDR pictures |
| `encoder deblock on` / `encoder deblock off` | the in-loop deblocking filter |
| `encoder notify interrupt` / `encoder notify polled` | how the firmware learns of a finished picture |

`build_info.txt` in this folder lists the source revision, the timing result and the utilization of the image.
