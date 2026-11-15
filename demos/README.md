# RTLNet Demos

Revision 11-14-2026

Ready-to-run demonstration images of RTLNet. **Start with [`demos.md`](demos.md)**: it lists what is in this folder,
the board, cables and PC tools needed, and how to run a demo.

Every folder in `demos` is one demo:

| File | Content |
|---|---|
| `<demo name>/<demo name>_brief.pdf` and `.md` | the brief: what the demo shows, results, limits, license |
| `<demo name>/<board>/README.md` | the steps to run the demo on that board |
| `<demo name>/<board>/rtlnet_<board>.bit` | the bitstream, firmware included |

Exactly what is in a demo folder `demos/<demo name>/`:

| Path | Content |
|---|---|
| `<demo name>_brief.pdf`, `<demo name>_brief.md` | the brief |
| `images/` | the pictures the brief uses |
| `release.txt` | the board images `demorelease.bat` copies for this demo (`<board> <build tag>` per line) |
| `<board>/README.md` | the steps to run the demo |
| `<board>/rtlnet_<board>.bit` | the bitstream, firmware included |
| `<board>/build_info.txt` | source revision, timing and utilization of that image |

`demorelease.bat` copies the bitstream and `build_info.txt` from `boards/<board>/build/<build tag>/` (the folder that
`boards/<board>/scripts/build.ps1 -Tag <build tag> -Image` writes) into `<board>/`. A `release.txt` line may carry a
third column, the bitstream file name; without it the name is `rtlnet_<board>.bit`. List the folders of `demos` to see
which demos there are; the README and the brief of each demo say what the demo shows and under which license it is.

The Ethernet demo (`ethernet/`) is the network stack alone, with no video: 10/100/1000 Mb/s Ethernet with ARP, ping, DHCP,
UDP echo and UDP iperf 2 in FPGA fabric, lwIP TCP and a protection profile on a 100 MHz MicroBlaze V without DDR3. Its image is
`rtlnet_nexys_video_eth.bit` (built by `boards/nexys_video/scripts/build_ethernet.ps1 -Tag eth_rel`; the name differs from the
video demos), it has no time limit and no netlist. Its brief (`ethernet/nexys_video/ethernet_nexys_video_brief.pdf`) has the measured results at 10, 100
and 1000 Mb/s and the flood test.

License: `LICENSE.md` in the repository root for RTLNet. A demo that is under other terms names its license file in its
README and brief.
