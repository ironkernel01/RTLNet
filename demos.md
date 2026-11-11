# RTLNet Demonstration Plan

Revision 11-10-2026

This plan lists the RTLNet demonstrations for the public release and ironkernel.com. Each demonstration shows one part
of the stack to the buyers who need it. Each one ships as a folder in the repository, a short video and a page on
ironkernel.com that links to the matching license tier in `licensing.md`.

## 1. Demonstrations

| ID | Name | What it shows | Who it reaches | Hardware | Depends on | Effort |
|---|---|---|---|---|---|---|
| D1 | Camera to VLC, latency measured | Pcam 5C to H.264 to MPEG-TS to VLC, ffplay or OBS on a PC; glass-to-glass latency measured with an LED timer in the camera's view | drones, robotics, industrial cameras | Nexys Video, Pcam 5C, FMC Pcam Adapter | Phase 3 (camera); a bars version runs today | 2 h after Phase 3 |
| D2 | Narrow-link video | 720p at 300 to 1000 kb/s under rate control; one slice per macroblock row, so a lost datagram damages one stripe; a link emulator on the PC adds loss and delay | drones, telemetry radio links, remote inspection | Nexys Video (camera optional) | Phase 2d (rate control) | 4 to 6 h |
| D3 | Motion metadata camera | the encoder's motion vectors and SAD values sent as a per-macroblock activity map next to the video; a PC viewer draws motion boxes on the live picture with no separate vision processor | security, machine vision, traffic counting | Nexys Video (camera optional) | Phase 2c (motion search) | 6 to 10 h |
| D4 | Line-rate network tester | the RTL iperf and UDP paths at 944 Mbit/s with no CPU load; an RFC 2544-style throughput, loss and latency test run from the CLI | test and measurement, network labs | Nexys Video | none | 6 to 10 h |
| D5 | Ten-minute start | prebuilt image, one script, color bars streaming to VLC; recorded as the first video on the website | every visitor | Nexys Video | none | 3 to 4 h |
| D6 | Hardware firewall and storm control | classifier ACLs and policers drop a broadcast flood at line rate while the CPU and the video stream keep running; CLI counters show each drop | industrial Ethernet, critical infrastructure | Nexys Video | none | 4 to 6 h |
| D7 | UDP data-acquisition streamer | a test-pattern ADC source at several hundred Mbit/s through the RTL UDP socket with no CPU in the path; a Python receiver plots it live | instruments, scientific data acquisition, SDR front ends | Nexys Video | none | 6 to 8 h |
| D8 | Web dashboard | an lwIP HTTP server on the board with live link, encoder and classifier counters and settings changed from a browser | networked device builders | Nexys Video | none | 6 to 10 h |
| D9 | Audio and video over IP | color bars or camera with line-in audio in one MPEG-TS stream, lip sync held for one hour | AV over IP, conferencing, broadcast contribution | Nexys Video (camera optional) | Phase 2f (audio) | 2 to 3 h after Phase 2f |
| D10 | Stream recorder | an ffmpeg recording on the PC with timestamps, segment files and a one-hour stability log | security recording, flight data recording | Nexys Video | Phase 2d | 2 to 3 h |
| D11 | Verification on GitHub Actions | every commit encodes the test sequences, 4K in simulation included, and JM, OpenH264 and FFmpeg check every picture byte for byte; the result shows as a badge on the repository | engineers judging the IP | none (simulation) | release repository | 4 to 6 h |
| D12 | Second board port | the same RTL built for a second board: an Arty A7 for the Ethernet stack, or an Artix UltraScale+ board for the full video path | buyers checking portability | the second board | none | 8 to 16 h per board |
| D13 | Quality comparison | RTLNet against x264 at equal bit rate: PSNR tables, side-by-side pictures, and resource and timing tables | buyers comparing encoders | none (host tools) | Phase 2e (deblocking, 4x4 intra, sub-pixel motion) | 4 to 6 h |

## 2. Order

| Step | Demonstrations | When | Reason |
|---|---|---|---|
| 1 | D5, and D1 with color bars | now | the board streams bars today; the first video needs no new RTL |
| 2 | D3 | after Phase 2c | motion vectors exist once the search lands; few public FPGA projects show a camera with motion detection and no extra processor |
| 3 | D2, D10 | after Phase 2d | rate control makes the narrow-link and recording cases possible |
| 4 | D11, D13, D4 | at release | they back the quality and verification claims and reach the test-and-measurement buyers |
| 5 | D1 with the camera, D9 | after Phases 3 and 2f | live camera and audio |
| 6 | D6, D7, D8, D12 | after release | they widen the reach into networking, data acquisition and other boards |

## 3. Deliverables per demonstration

| Item | Content |
|---|---|
| `demos/<id>_<name>/README.md` | what the demonstration shows, the hardware list with part numbers, the steps from a clean PC to a running demo, and the expected output |
| `demos/<id>_<name>/` scripts | one PowerShell or Python script that builds or loads the image, configures the board over the CLI and starts the PC side; tools found through `scripts/rtlnet_tools.ps1` |
| Pass check | a script result line, `DEMO_<ID>: PASS` or `FAIL`, so each demonstration also runs as a regression |
| Video | 1 to 3 minutes, recorded on the board, with the measured numbers on screen |
| Web page | the video, the measured results, the hardware list, a link to the folder on GitHub and a link to the matching license tier in `licensing.md` |

## 4. Measured results each demonstration publishes

| ID | Numbers on the page |
|---|---|
| D1 | glass-to-glass latency in ms, resolution and frame rate, bit rate |
| D2 | bit rate, PSNR, the share of pictures intact at 1 %, 5 % and 10 % datagram loss |
| D3 | detection rate on a scripted moving object, extra CPU load, extra bit rate of the metadata |
| D4 | throughput in Mbit/s and frame loss per frame size, latency per frame size |
| D5 | minutes from download to picture on a clean PC |
| D6 | flood rate, drops counted, video pictures dropped (target 0), CPU load during the flood |
| D7 | sustained rate in Mbit/s, datagrams lost over one hour |
| D8 | page load time, CPU load with the page open |
| D9 | audio-to-video offset over one hour |
| D10 | hours recorded, pictures dropped, file segments written |
| D11 | configurations run per commit, pictures checked, run time |
| D12 | LUT, flip-flop, block RAM and timing results on the second board |
| D13 | bit rate at equal PSNR against x264 per test sequence, LUT and block RAM per engine |
