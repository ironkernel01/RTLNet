# RTLNet Demos

Revision 11-13-2026

This folder holds the ready-to-run demonstration images of RTLNet. Each demo is a prebuilt FPGA bitstream with the
firmware inside it: program the board, type a few commands on the serial console and the result is on the PC. Nothing
has to be built.

## 1. What is in this folder

| Path | Content |
|---|---|
| `demos.md` | this guide |
| `demorelease.bat` | maintainer script: copies freshly built images into the demo folders (section 6) |
| `build_brief_pdf.ps1` | maintainer script: builds the PDF of a demo brief (section 6) |
| `<demo name>/` | one demo (every folder under `demos` is one demo) |
| `<demo name>/release.txt` | what `demorelease.bat` copies for this demo: one line `<board> <build tag>` per board image |
| `<demo name>/<board>/` | the demo on one board |
| `<demo name>/<board>/README.md` | the steps to run that demo |
| `<demo name>/<board>/rtlnet_<board>.bit` | the bitstream, firmware included |
| `<demo name>/<board>/build_info.txt` | source revision, timing result and utilization of the image |
| `<demo name>/<demo name>_brief.md` and `.pdf` | the demo brief: what the demo shows, data path, test pattern, measured results, build variants, utilization and limits |

## 2. Demos available

Every folder under `demos` is one demo. Its brief (`<demo name>/<demo name>_brief.pdf`) says what it shows, how it is
built, the measured results, and its time limit and license if it has any; its `README.md` (`<demo name>/<board>/`) has the
steps to run it. This guide does not list the demos, so it is the same for every demo that is added.

The images contain the complete RTLNet design for the board: the gigabit Ethernet stack, the MicroBlaze V processor
with its command-line console, the DDR3 memory path and the H.264 encoder, all on one 90 MHz clock.

## 3. What you need

### Board and cables

| Item | Notes |
|---|---|
| Digilent Nexys Video | Artix-7 XC7A200T. The mode jumper JP4 is on JTAG. |
| 12 V power supply | the one supplied with the board |
| Micro-USB cable to the PROG port | programming over JTAG |
| Micro-USB cable to the UART port | serial console |
| Ethernet cable | from the board to the same network as the PC; the demos run on 100 Mb/s and 1000 Mb/s links (the README of each demo has the console commands that select the speed) |

No camera is needed: the demos use test patterns generated on the board.

### On the PC (Windows)

| Tool | Used for |
|---|---|
| Vivado 2026.1 with its free license | programming the board (`boards/nexys_video/scripts/program.ps1`) |
| PowerShell | runs the programming script |
| A serial terminal (PuTTY, Tera Term or similar) | the board console: the UART port at 115200 baud, 8 data bits, no parity, 1 stop bit |
| VLC or ffplay (part of FFmpeg) | shows the video |

### Network

A DHCP server on the network (a home router is enough) gives the board its address; `show ip` on the console prints it.
The PC's firewall must let UDP port 5004 in, or the player shows nothing.

## 4. Running a demo

The README in each demo folder has the exact commands. In short:

1. Program the board:
   `powershell -NoProfile -ExecutionPolicy Bypass -File boards/nexys_video/scripts/program.ps1 -Bit demos/<demo name>/nexys_video/rtlnet_nexys_video.bit`
2. Open the serial console and wait for the prompt. `show ip` prints the board's address.
3. Start the player on the PC: `ffplay -fflags nobuffer udp://@:5004`, or in VLC open the network stream `udp://@:5004`.
4. On the console: `enable` (privileged mode), `camera mode 1080p30`, `camera pattern all 4`, `encoder bitrate 8000`, then `stream h264 <PC address> 5004`.
5. `show stream` and `show encoder` print the picture counts, the bit rate and the encoder state. `stream stop` ends the stream.

The image is loaded into the FPGA only, not into the flash: a power cycle removes it.

## 5. What to expect

| Item | Value |
|---|---|
| Picture sizes | 1920 x 1080 and 1280 x 720 at 30 pictures per second |
| Bit rate | set by `encoder bitrate <kb/s>`; 8,000 kb/s is a good start for 1080p30 |
| Dropped pictures | 0 in `show stream` at 8,000 and 16,000 kb/s |
| Time-limited demo | the README and the brief of such a demo say what the limit is and how `show encoder` reports the time left |

If the player stays black: check the PC address in the `stream` command, the firewall rule for UDP 5004, and that
`show stream` counts pictures.

## 6. For maintainers: updating and adding demos

After a board build (`boards/<board>/scripts/build.ps1 ... -Tag <tag> -Image`) run

```
demos\demorelease.bat
```

It finds every `demos/<demo name>/release.txt` and, for each `<board> <build tag>` line in it, copies the bitstream and
`build_info.txt` from `boards/<board>/build/<tag>/` into `demos/<demo name>/<board>/`. It prints one line per file and
ends with `DEMORELEASE: PASS`, or with `DEMORELEASE: FAIL` when a source file is missing. It builds nothing and does not
touch the board.

The PDF of a demo brief is built from `demos/<demo name>/<demo name>_brief.md` with one line (needs Chrome or Edge and an internet connection for the page scripts):

```
powershell -NoProfile -ExecutionPolicy Bypass -File demosuild_brief_pdf.ps1 h264_baseline
```

The script uses the page head and foot of `documentation/pdf`, prints with headless Chrome next to the `.md` so the relative image paths resolve, and removes its temporary `render.html`.
The drawings of the briefs are in `diagrams/src/demo-h264.js` (render with `diagrams/tools/render.ps1`).

To add a demo:

1. Create `demos/<demo name>/release.txt` with one line `<board> <build tag>` per board image (`demorelease.bat` and this guide do not change).
2. Write `demos/<demo name>/<board>/README.md` with the steps to run it.
3. Write `demos/<demo name>/<demo name>_brief.md` and build its PDF with the line above.

The demos are bitstreams only. No netlist or source of a paid extension and no image without its time limit goes into
this folder.

## 7. Planned demos

These demonstrations are planned and are not in the folder yet. Each one gets its own folder when it is ready.

| ID | Name | What it shows | Hardware |
|---|---|---|---|
| D1 | Camera to VLC, latency measured | Pcam 5C camera to H.264 to MPEG-TS to VLC, ffplay or OBS on a PC; glass-to-glass latency measured with an LED timer in the camera's view | Nexys Video, Pcam 5C, FMC Pcam Adapter |
| D2 | Narrow-link video | 720p at 300 to 1000 kb/s under rate control; one slice per macroblock row, so a lost datagram damages one stripe; a link emulator on the PC adds loss and delay | Nexys Video |
| D3 | Motion metadata camera | the encoder's motion vectors sent as a per-macroblock activity map next to the video; a PC viewer draws motion boxes on the live picture with no separate vision processor | Nexys Video |
| D4 | Line-rate network tester | the RTL iperf and UDP paths at 944 Mbit/s with no CPU load; a throughput, loss and latency test run from the console | Nexys Video |
| D5 | Ten-minute start | prebuilt image, one script, color bars streaming to VLC | Nexys Video |
| D6 | Hardware firewall and storm control | classifier rules and policers drop a broadcast flood at line rate while the CPU and the video stream keep running | Nexys Video |
| D7 | UDP data-acquisition streamer | a test-pattern data source at several hundred Mbit/s through the RTL UDP socket with no CPU in the path; a Python receiver plots it live | Nexys Video |
| D8 | Web dashboard | an HTTP server on the board with live link, encoder and classifier counters and settings changed from a browser | Nexys Video |
| D9 | Audio and video over IP | test pattern or camera with line-in audio in one MPEG-TS stream | Nexys Video |
| D10 | Stream recorder | an ffmpeg recording on the PC with timestamps, segment files and a one-hour stability log | Nexys Video |
| D11 | Verification on GitHub Actions | every commit encodes the test sequences, and JM, OpenH264 and FFmpeg check every picture | none (simulation) |
| D12 | Second board port | the same RTL built for a second board | the second board |
| D13 | Quality comparison | RTLNet against x264 at equal bit rate: PSNR tables, side-by-side pictures, resource and timing tables | none (host tools) |
