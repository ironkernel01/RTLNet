// Drawing set: demo-h264-zybo (1 sheet: the Zybo Z7-20 real-camera H.264 demo set-up and data path) for
//   demos/h264_baseline/zybo_z7_20/h264_baseline_zybo_z7_20_brief.md
// Build: node diagrams/src/demo-h264-zybo.js  ->  diagrams/out/demo-h264-zybo.pptx
// Render: powershell -File diagrams\tools\render.ps1 diagrams\out\demo-h264-zybo.pptx  ->  out/png/demo-h264-zybo-1.png
// Fills: white = RTLNet RTL core or hard block of the Zynq PS (the PS blocks sit in their own container), gray = ARM firmware,
// yellow = outside the Zynq.
const path = require("path");
const { newDeck, helpers, FILL } = require("../lib/engslides");

const pres = newDeck("IronKernel RTLNet Zybo Z7-20 camera H.264 demo");
const { box, container, wire, label, notes, legend, frame } = helpers(pres);
const W = FILL.white, G = FILL.gray, Y = FILL.yellow;

const s = pres.addSlide();

// Containers: the Zynq, its programmable logic and its processing system
container(s, 2.5, 0.5, 8.7, 5.35, "Zynq-7000 XC7Z020 on the Zybo Z7-20");
container(s, 2.6, 0.85, 4.85, 4.75, "Programmable logic: RTLNet cores");
container(s, 7.95, 0.85, 3.15, 4.75, "Processing system: hard blocks and firmware");

// Outside: camera on the left
box(s, 0.5, 1.15, 1.45, 4.4, "Pcam 5C camera module",
  ["OV5640 sensor", "2 MIPI data lanes", "and a clock lane", "RAW10", "720p30 at 280 Mb/s", "1080p30 at 420 Mb/s", "per lane"], Y);

// Programmable logic
const lx = 2.7, lw = 1.9, mx = 5.35, mw = 2.0;
box(s, lx, 1.15, lw, 1.6, "MIPI CSI-2 receiver",
  ["rtlnet_csi2_rx", "D-PHY front end, 2 lanes", "packet layer, ECC, CRC-16", "black level, white balance,", "green equalisation, clamp,", "gamma, YUV422 output"], W);
box(s, lx, 3.05, lw, 1.5, "Clocks",
  ["PS FCLK0 100 MHz to MMCM", "90 MHz: video path, HP0, HP2", "50 MHz: GP0, AXI4-Lite", "200 MHz: D-PHY delay", "reference"], W);
box(s, mx, 1.15, mw, 0.6, "Camera admission", ["720p30: every frame", "1080p15: every second frame"], W);
box(s, mx, 2.05, mw, 0.7, "Capture writer", ["rtlnet_vdma_s2mm", "64-bit AXI3 write bursts", "into the capture slots"], W);
box(s, mx, 3.05, mw, 0.45, "Frame buffer", ["rtlnet_framebuf, 3 slots"], W);
box(s, mx, 3.8, mw, 0.75, "H.264 Baseline encoder", ["rtlnet_h264_top, 1 engine", "deblocking filter on", "64-bit AXI3 reads and writes"], W);
box(s, lx, 4.7, mx + mw - lx, 0.3, "AXI4-Lite register windows, 5 x 4 KiB", [], W);

// Processing system
const px = 8.05, pw = 1.3, dx = 9.75, dw = 1.25;
box(s, px, 1.15, 2.95, 0.7, "ARM Cortex-A9 core 0, bare-metal firmware",
  ["sensor and receiver set-up, MPEG-TS multiplexer", "lwIP 2.2.0 UDP, console CLI"], G);
box(s, px, 2.05, pw, 0.7, "HP2 port", ["64-bit AXI3", "capture writes"], W);
box(s, px, 3.8, pw, 0.75, "HP0 port", ["64-bit AXI3", "encoder reads", "and writes"], W);
box(s, dx, 2.05, dw, 2.5, "DDR3 controller", ["capture slots,", "reference pictures,", "compressed ring,", "ARM program"], W);
box(s, px, 4.7, pw, 0.3, "GP0 master port", [], W);
box(s, px, 5.1, 0.7, 0.4, "I2C0", [], W);
box(s, 8.85, 5.1, 0.7, 0.4, "UART1", [], W);
box(s, dx, 5.1, dw, 0.4, "GEM0 MAC, RGMII", [], W);

// Outside: memory, PHY, PC
box(s, 11.4, 2.05, 1.35, 2.5, "DDR3 memory", ["on the board"], Y);
box(s, 11.4, 4.75, 1.35, 1.1, "Ethernet PHY", ["Realtek RTL8211F", "10/100/1000 Mb/s", "RJ45 connector"], Y);
box(s, 0.5, 6.1, 12.25, 0.55, "PC (Windows)",
  ["VLC or ffplay on UDP port 5004, serial terminal 115200 baud 8N1, Vivado programming script", "stream_test.ps1 and rx_test.ps1 host tests"], Y);

// Camera link and video path
wire(s, 1.95, 1.45, lx, 1.45, { start: false });
label(s, 1.97, 1.25, 0.72, "MIPI CSI-2");
label(s, 1.97, 1.47, 0.72, "2 lanes");
wire(s, lx + lw, 1.45, mx, 1.45, { start: false });
label(s, lx + lw + 0.03, 1.25, 0.8, "AXI4-Stream");
label(s, lx + lw + 0.03, 1.47, 0.8, "YUV422");
wire(s, mx + mw / 2, 1.75, mx + mw / 2, 2.05, { start: false });
label(s, mx + mw / 2 + 0.1, 1.77, 1.2, "AXI4-Stream");
wire(s, mx + mw / 2, 2.75, mx + mw / 2, 3.05, { start: true, end: true, dash: "dash" });
label(s, mx + mw / 2 + 0.1, 2.77, 1.2, "slot handoff");
wire(s, mx + mw / 2, 3.5, mx + mw / 2, 3.8, { start: true, end: true, dash: "dash" });
label(s, mx + mw / 2 + 0.1, 3.52, 1.2, "slot ownership");

// Memory ports
wire(s, mx + mw, 2.4, px, 2.4, { start: false });
label(s, mx + mw + 0.03, 2.2, 0.7, "AXI3, 64-bit");
wire(s, mx + mw, 4.175, px, 4.175, { start: true });
label(s, mx + mw + 0.03, 3.975, 0.7, "AXI3, 64-bit");
wire(s, px + pw, 2.4, dx, 2.4, { start: false });
wire(s, px + pw, 4.175, dx, 4.175, { start: true });
wire(s, dx + dw, 3.3, 11.4, 3.3, { start: true });

// Register path and firmware
wire(s, mx + mw, 4.85, px, 4.85, { start: true });
label(s, mx + mw + 0.03, 4.65, 0.7, "AXI4-Lite");
wire(s, 9.55, 1.85, 9.55, 4.85, { start: true, end: false });
wire(s, 9.55, 4.85, px + pw, 4.85, { start: false, end: true });

// I2C to the sensor through EMIO (a lane under the logic blocks), UART and Ethernet
wire(s, 1.95, 5.3, 8.05, 5.3, { start: true });
label(s, 3.0, 5.1, 3.5, "I2C: sensor control through EMIO");
wire(s, 9.2, 5.5, 9.2, 6.1, { start: true });
label(s, 9.3, 5.9, 1.2, "USB-UART console");
wire(s, dx + dw, 5.3, 11.4, 5.3, { start: true });
wire(s, 12.075, 5.85, 12.075, 6.1, { start: true });
label(s, 10.1, 5.9, 1.9, "Ethernet, UDP and DHCP", 7.5, "right");
wire(s, 5.0, 6.1, 5.0, 5.85, { dash: "dash", start: false });
label(s, 5.1, 5.9, 3.0, "USB-JTAG: bitstream and firmware");

notes(s, 0.6, 6.7, 12.1, 0.3, [
  "The RTL receives the camera picture, converts it and writes it to DDR3; the encoder reads it back through its own port. The ARM core multiplexes the H.264 stream into MPEG-TS and sends it over UDP.",
]);
legend(s, 0.6, 7.03, [["RTLNet RTL core or PS hard block", W], ["ARM firmware", G], ["Outside the Zynq", Y]], 3.2);
frame(s);

pres.writeFile({ fileName: path.join(__dirname, "..", "out", "demo-h264-zybo.pptx") }).then((f) => console.log("wrote", f));
