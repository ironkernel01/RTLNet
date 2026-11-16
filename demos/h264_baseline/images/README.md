# H.264 demo images

Revision 11-16-2026

The two `test_pattern_*` pictures belong to the Nexys Video demos. The `zybo_*` pictures belong to the Zybo Z7-20 camera demo (`../zybo_z7_20/h264_baseline_zybo_z7_20_brief.md`), taken from the board loaded with the released files of `../zybo_z7_20/` (image `own9`, firmware `fw19`, 11-16-2026).

| File | Shows |
|---|---|
| `zybo_console.png` | `show version`, `show ip`, `show camera`, `show rx` after the start-up |
| `zybo_stream_720p.png` | `camera mode 720p30`, `stream start`, `rx clear`, then `show camera`, `show stream` and `show rx` during the stream |
| `zybo_stream_1080p.png` | the same at `camera mode 1080p15` |
| `zybo_frame_720p.png` | a picture of the decoded 720p stream, eight seconds into the capture (1280 x 720) |
| `zybo_frame_1080p.png` | a picture of the decoded 1080p stream, eight seconds into the capture (1920 x 1080) |
| `zybo_rx_counters.png` | `rx_test.ps1 -Action counters` over 60 s per mode: `ZYBO_RX_COUNTERS: PASS 22/22` |

The console pictures are renderings of text that `demo_captures.ps1` composes from the board's answers (`cpu/microblaze_v_ethernet/test/render_capture.py`); the IP and MAC addresses in them are replaced by documentation values (192.0.2.x, 00:00:5E:00:53:xx). The frames are the decoded pictures themselves.

## The frames of 11-16-2026 were taken in a dark room

The frames show almost nothing: the room was dark and the camera saw no lit object. Retake them in daylight with a scene in view of the camera (a window, a desk, a colour chart) and rebuild the brief. From the repository root, with the firmware running (`boards/zybo_z7_20/scripts/program_demo.ps1`) and the board on the network of the PC:

```
powershell -NoProfile -ExecutionPolicy Bypass -File boards/zybo_z7_20/scripts/demo_captures.ps1 -Port COM6 -Verdicts
powershell -NoProfile -ExecutionPolicy Bypass -File demos/build_brief_pdf.ps1 h264_baseline zybo_z7_20
```

The first line takes the board lock, starts the stream in both modes, writes the five pictures above into this folder, and with `-Verdicts` also runs `stream_test.ps1` and `rx_test.ps1` and writes `zybo_stream_test.png` and `zybo_rx_counters.png` (about 10 minutes; without `-Verdicts` it takes about 1.5 minutes and leaves `zybo_rx_counters.png` as it is). `-Port` is mandatory: give the console port of the Zybo Z7-20. Look at the two frames before they are committed: they show whatever stands in front of the camera. `zybo_stream_test.png` is not in the brief yet because its two picture steps fail in a dark room (14 of 16 steps pass); add it to the brief when the daylight run gives `ZYBO_STREAM_TEST: PASS 16/16`. The second line builds the PDF of the brief.
