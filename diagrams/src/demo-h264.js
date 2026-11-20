// Drawing set: demo-h264 (2 sheets: the H.264 demo set-up and data path on the Nexys Video) for
//   documentation/rtnet_specification.md (Baseline and High Profile reference sections)
// The sheets differ only in the encoder block.
// Build: node diagrams/src/demo-h264.js  ->  diagrams/out/demo-h264.pptx
// Render: powershell -File diagrams\tools\render.ps1 diagrams\out\demo-h264.pptx  ->  out/png/demo-h264-1.png, -2.png
// Fills: white = FPGA logic, gray = soft CPU firmware, blue = encoder with the High profile extension,
// yellow = outside the FPGA.
const path = require("path");
const { newDeck, helpers, FILL } = require("../lib/engslides");

const pres = newDeck("IronKernel RTLNet H.264 demo");
const { box, container, wire, label, notes, legend, frame } = helpers(pres);
const W = FILL.white, G = FILL.gray, B = FILL.blue, Y = FILL.yellow;

const cx = [0.8, 3.4, 6.0, 8.6], w = 1.85;          // FPGA columns
const mx = cx.map((x) => x + w / 2);
const r0 = 1.0, h0 = 0.9, r1 = 2.35, h1 = 0.85, r2 = 3.7, h2 = 0.95;
const y0 = r0 + h0 / 2, y1 = r1 + h1 / 2, y2 = r2 + h2 / 2;
const xe = 11.4, ew = 1.35;                          // outside the FPGA
const encW = cx[3] + w - cx[2];

function sheet(high) {
  const s = pres.addSlide();
  container(s, 0.5, 0.5, 10.25, 4.45, "Artix-7 XC7A200T on the Nexys Video");

  // Video side: pattern generator -> write DMA -> DDR3 arbiter <-> encoder engines
  box(s, cx[0], r0, w, h0, "IronCapture pattern source", ["bars, scroll, box, noise", "1080p30 or 720p30"], W);
  box(s, cx[1], r0, w, h0, "Video write DMA", ["2D write bursts into", "the frame buffer"], W);
  if (high) {
    box(s, cx[2], r0, encW, h0, "IronH264 with High Profile extension",
      ["CABAC extension, 30 minutes per configuration, then Constrained Baseline",
       "I and P pictures, whole-sample motion search +-16, in-loop deblocking filter",
       "1080p30 or 720p30, two engines, one band each"], B);
  } else {
    box(s, cx[2], r0, encW, h0, "IronH264 Constrained Baseline",
      ["CAVLC entropy coding, no time limit",
       "I and P pictures, whole-sample motion search +-16, in-loop deblocking filter",
       "1080p30 or 720p30, two engines, one band each"], W);
  }
  box(s, cx[0], r1, cx[2] + w - cx[0], h1, "DDR3 arbiter and MIG controller",
    ["4 masters: MicroBlaze V cache, video DMA, 2 encoder engines", "burst-only access, one 90 MHz clock"], W);

  // Network side: firmware -> CPU path -> protocol wrapper -> MAC
  box(s, cx[0], r2, w, h2, "MicroBlaze V firmware", ["MPEG-TS multiplexer", "lwIP 2.2.0 UDP/IPv4", "rate control, console"], G);
  box(s, cx[1], r2, w, h2, "CPU network path", ["AXI DMA", "IP and UDP checksum offload"], W);
  box(s, cx[2], r2, w, h2, "Protocol wrapper", ["ARP, ICMP, DHCP in logic", "CPU frames and replies merge"], W);
  box(s, cx[3], r2, w, h2, "Ethernet MAC", ["10/100/1000 Mb/s, RGMII", "FCS, padding, IFG"], W);

  // Outside the FPGA
  box(s, xe, r1, ew, h1, "DDR3 SDRAM", ["512 MiB", "frame buffer", "stream ring"], Y);
  box(s, xe, r2, ew, h2, "Ethernet PHY", ["Realtek RTL8211E", "RJ45 connector"], Y);
  box(s, cx[0], 5.45, xe + ew - cx[0], 0.7, "PC (Windows)",
    ["VLC or ffplay on udp://@:5004", "serial terminal, 115200 baud, 8N1", "Vivado programming script"], Y);

  // Video connectors
  wire(s, cx[0] + w, y0, cx[1], y0);
  label(s, cx[0] + w + 0.03, y0 - 0.2, 0.7, "AXI4-Stream");
  wire(s, mx[1], r0 + h0, mx[1], r1);
  label(s, mx[1] + 0.1, 2.0, 1.4, "frame buffer write");
  wire(s, mx[2], r0 + h0, mx[2], r1, { start: true });
  label(s, mx[2] + 0.1, 2.0, 2.6, "frame buffer read, stream ring write");
  wire(s, cx[2] + w, y1, xe, y1, { start: true });
  label(s, 8.6, y1 - 0.2, 1.2, "DDR3 bus");
  // Firmware reads the stream ring through the arbiter
  wire(s, mx[0], r1 + h1, mx[0], r2, { start: true });
  label(s, mx[0] + 0.1, 3.35, 1.6, "stream ring, caches");
  // Network chain
  for (let i = 0; i < 3; i++) wire(s, cx[i] + w, y2, cx[i + 1], y2, { start: true });
  label(s, cx[0] + w + 0.03, y2 - 0.2, 0.7, "AXI DMA");
  label(s, cx[1] + w + 0.03, y2 - 0.2, 0.7, "AXI4-Stream");
  label(s, cx[2] + w + 0.03, y2 - 0.2, 0.7, "AXI4-Stream");
  wire(s, cx[3] + w, y2, xe, y2, { start: true });
  label(s, 10.78, y2 - 0.2, 0.55, "RGMII");
  // PC links
  wire(s, mx[0], 5.45, mx[0], r2 + h2, { start: true });
  label(s, mx[0] + 0.1, 5.05, 1.5, "USB-UART console");
  wire(s, mx[2], 5.45, mx[2], 4.95, { dash: "dash", start: false });
  label(s, mx[2] + 0.1, 5.05, 2.6, "USB-JTAG: bitstream with firmware");
  wire(s, xe + ew / 2, 5.45, xe + ew / 2, r2 + h2, { start: true });
  label(s, 9.7, 5.05, 2.3, "Ethernet, MPEG-TS over UDP", 7.5, "right");

  notes(s, 0.6, 6.25, 12.1, 0.5, [
    "The pattern generator stands in for the camera input; the demo has no camera. The encoder writes the H.264 stream into a ring in DDR3 and the MicroBlaze V firmware reads it back.",
    "The firmware packs the stream into MPEG-TS packets and sends them as UDP datagrams to the PC; the RTL answers ARP, ping and DHCP without the CPU.",
  ]);
  legend(s, 0.6, 6.85, high
    ? [["FPGA logic", W], ["MicroBlaze V firmware", G], ["Encoder with High profile extension", B], ["Outside the FPGA", Y]]
    : [["FPGA logic", W], ["MicroBlaze V firmware", G], ["Outside the FPGA", Y]], 3.2);
  frame(s);
}

sheet(false);
sheet(true);

pres.writeFile({ fileName: path.join(__dirname, "..", "out", "demo-h264.pptx") }).then((f) => console.log("wrote", f));
