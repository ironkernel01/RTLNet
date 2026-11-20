// Drawing set: product-brief (2 sheets: reference Ethernet board and 10 Gb/s integration) for
// documentation/rtnet_specification.md.
// Build: node diagrams/src/product-brief.js  ->  diagrams/out/product-brief.pptx
// Render: powershell -File diagrams\tools\render.ps1 diagrams\out\product-brief.pptx  ->  out/png/product-brief-1.png
// Fills: white = RTLNet RTL cores, blue = CPU-path accelerators, gray = soft CPU subsystem,
// yellow = outside the FPGA.
const path = require("path");
const { newDeck, helpers, FILL } = require("../lib/engslides");

const pres = newDeck("IronKernel RTLNet");
const { box, container, wire, label, notes, legend, frame } = helpers(pres);
const W = FILL.white, G = FILL.gray, B = FILL.blue, Y = FILL.yellow;

const s = pres.addSlide();
const xe = 0.6, ew = 2.2;                 // external column
const c = [3.5, 6.45, 9.4], w = 2.6, h = 0.95;
const r = [1.0, 2.6, 4.2];
const cmx = (i) => c[i] + w / 2, cmy = (j) => r[j] + h / 2;

container(s, 3.2, 0.5, 9.5, 4.95, "IronKernel RTLNet: one FPGA (Artix-7 XC7A200T on the reference board)");

// Outside the FPGA
box(s, xe, r[0], ew, r[1] + h - r[0], "Ethernet PHY", ["Realtek RTL8211E", "10/100/1000BASE-T"], Y);
box(s, xe, r[2], ew, h, "Service PC", ["USB-UART console", "JTAG program and debug"], Y);

// Line-rate RTL data path
box(s, c[0], r[0], w, h, "Ethernet MAC", ["10/100/1000 Mb/s, RGMII", "FCS, padding, IFG", "8 KiB RX and TX queues"], W);
box(s, c[1], r[0], w, h, "Protocol wrapper", ["64-bit AXI4-Stream", "ingress and egress queues", "leaf fan-out, arbiter"], W);
box(s, c[2], r[0], w, h, "Protocol leaves", ["ARP, ICMP echo, DHCP client", "iperf 2 UDP server", "UDP sockets, 4 ports"], W);
box(s, c[0], r[1], w, h, "MDIO", ["Clause 22 and Clause 45", "PHY reset and interrupt", "RTL8211E driver in C"], W);
box(s, c[2], r[1], w, h, "UDP application", ["UDP echo, or user logic", "on the socket payload streams"], W);

// CPU network path
box(s, c[1], r[1], w, h, "Frame classifier", ["64-bit CPU path at 100 MHz", "L2-L4 filter and policers", "drop-all until configured"], B);
box(s, c[1], r[2], w, h, "Checksum offload", ["IPv4, TCP, UDP checksum insert", "receive check, 8-byte trailer"], B);
box(s, c[0], r[2], w, h, "Soft CPU", ["MicroBlaze 100 MHz, AXI DMA", "lwIP 2.2.0: TCP, TCP iperf", "network manager, CLI"], G);

// PHY <-> MAC (RGMII), PHY <-> MDIO
wire(s, xe + ew, cmy(0), c[0], cmy(0), { start: true });
label(s, xe + ew + 0.05, cmy(0) - 0.25, 0.65, "RGMII");
wire(s, xe + ew, cmy(1), c[0], cmy(1), { start: true });
label(s, xe + ew + 0.05, cmy(1) - 0.25, 0.65, "MDIO");
// MAC <-> wrapper <-> leaves <-> application
wire(s, c[0] + w, cmy(0), c[1], cmy(0), { start: true });
wire(s, c[1] + w, cmy(0), c[2], cmy(0), { start: true });
wire(s, cmx(2), r[0] + h, cmx(2), r[1], { start: true });
// Unclaimed frames: wrapper -> classifier -> offload
wire(s, cmx(1) - 0.4, r[0] + h, cmx(1) - 0.4, r[1]);
label(s, c[1] + 0.1, 2.12, 0.72, "to CPU", 7.5, "right");
wire(s, cmx(1), r[1] + h, cmx(1), r[2]);
// Offload <-> CPU (DMA streams)
wire(s, c[0] + w, cmy(2), c[1], cmy(2), { start: true });
// CPU transmit: offload -> wrapper (right, up, left, up)
wire(s, c[1] + w, cmy(2), 9.22, cmy(2), { end: false });
wire(s, 9.22, cmy(2), 9.22, 2.25, { end: false });
wire(s, 9.22, 2.25, cmx(1) + 0.4, 2.25, { end: false });
wire(s, cmx(1) + 0.4, 2.25, cmx(1) + 0.4, r[0] + h);
label(s, cmx(1) + 0.45, 2.03, 0.8, "from CPU");
// Service PC <-> CPU; CPU registers (dashed)
wire(s, xe + ew, cmy(2), c[0], cmy(2), { start: true });
label(s, xe + ew + 0.05, cmy(2) - 0.25, 0.65, "UART");
wire(s, cmx(0), r[2], cmx(0), r[1] + h, { dash: "dash" });
label(s, cmx(0) + 0.08, 3.78, 0.9, "AXI4-Lite");

notes(s, 0.6, 5.6, 12.1, 1.0, [
  "All RTL is SystemVerilog-2012. Vendor-specific cells live only in the RAM, shift-register, synchronizer and RGMII pin files; one include file selects AMD, Altera, Lattice or a generic model.",
  "Every data path is a 64-bit AXI4-Stream; every core has an AXI4-Lite register slave (ID, VERSION, CAPS). The CPU reaches all core registers over AXI4-Lite; one dashed connector stands for that bus.",
  "Frames that no RTL leaf claims go to the CPU. ARP, ping, DHCP and UDP iperf are answered in logic and never reach the CPU.",
]);
legend(s, 0.6, 6.8, [["RTLNet RTL core", W], ["CPU-path accelerator", B], ["Soft CPU subsystem", G], ["Outside the FPGA", Y]], 2.6);
frame(s);

// The second sheet shows main ingress in a 10 Gb/s system, separate from the board image.
const g = pres.addSlide();
container(g, 0.55, 0.62, 12.2, 5.75, "10 Gb/s system integration");
box(g, 0.95, 1.45, 2.75, 1.20, "10 Gb/s MAC + PCS/PHY",
    ["Board-selected interface", "Ethernet frames, FCS stripped"], Y);
box(g, 5.0, 1.45, 3.15, 1.20, "RTLNet classifier",
    ["64 bits at 156.25 MHz", "1 beat/clock, legal frames", "Pass, filter or police"], B);
box(g, 9.45, 1.45, 2.85, 1.20, "Forward / steer",
    ["Admitted frames at line rate", "Ready output required"], W);
wire(g, 3.7, 2.05, 5.0, 2.05);
wire(g, 8.15, 2.05, 9.45, 2.05);
label(g, 3.72, 1.76, 1.25, "10 Gb/s RX", 9, "center");
label(g, 8.17, 1.76, 1.25, "10 Gb/s", 9, "center");
box(g, 8.95, 3.52, 3.3, 1.15, "Service queues",
    ["Selected packets and replies", "Optional clock-domain crossing"], W);
box(g, 4.85, 3.52, 3.40, 1.15, "RTLNet protocol services",
    ["ARP, ICMP, DHCP, UDP sockets", "64-bit RX and TX streams"], W);
wire(g, 10.70, 2.65, 10.70, 3.52, { start: true });
wire(g, 8.25, 4.10, 8.95, 4.10, { start: true });
box(g, 0.95, 3.52, 2.95, 1.15, "Application / firmware",
    ["UDP payload or CPU service", "Rate set by the application"], G);
wire(g, 3.90, 4.10, 4.85, 4.10, { start: true });
notes(g, 1.00, 5.00, 11.10, 1.05, [
    "Classifier capacity: 64 bits x 156.25 MHz = 10.00 Gb/s. Standalone Artix-7 timing: +1.515 ns setup and +0.059 ns hold.",
    "Minimum-frame traffic: 14.88 million frames/s on the wire. The classifier handles one 60-byte client frame per eight beats, or 19.53 million frames/s.",
    "Size service queues for the selected traffic. Their processing rate is independent of the classifier's line-rate forwarding contract.",
]);
frame(g);

pres.writeFile({ fileName: path.join(__dirname, "..", "out", "product-brief.pptx") }).then((f) => console.log("wrote", f));
