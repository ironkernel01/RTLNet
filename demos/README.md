# RTLNet Demos

Revision 11-13-2026

Ready-to-run demonstration images of RTLNet. **Start with [`demos.md`](demos.md)**: it lists what is in this folder,
the board, cables and PC tools needed, and how to run a demo.

| Folder | Board | What it shows | Brief |
|---|---|---|---|
| [`h264_baseline/nexys_video`](h264_baseline/nexys_video/README.md) | Nexys Video | H.264 Constrained Baseline encoder with the deblocking filter, 1080p30 and 720p30, MPEG-TS over UDP to VLC or ffplay | [PDF](h264_baseline/h264_baseline_brief.pdf), [Markdown](h264_baseline/h264_baseline_brief.md) |
| [`h264_high_profile_demo/nexys_video`](h264_high_profile_demo/nexys_video/README.md) | Nexys Video | the same with the High profile extension (CABAC), limited to 30 minutes after each programming | [PDF](h264_high_profile_demo/h264_high_profile_demo_brief.pdf), [Markdown](h264_high_profile_demo/h264_high_profile_demo_brief.md) |

Licenses: `LICENSE.md` in the repository root for RTLNet, [`LICENSE_DEMO.md`](LICENSE_DEMO.md) for the High profile
demonstration package.
