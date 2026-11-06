// Drawing set: product-brief (1 sheet: RTLNet in the FPGA and what it connects to) for
// documentation/rtlnet_product_brief.md.
// Build: node diagrams/src/product-brief.js  ->  diagrams/out/product-brief.pptx + out/svg/product-brief-1.svg
// Render: powershell -File diagrams\tools\render_svg.ps1 product-brief   (or render.ps1 on the .pptx)
// Fills: white = RTLNet RTL cores, blue = CPU-path accelerators, gray = soft CPU subsystem,
// yellow = outside the FPGA.
const path = require("path");
const { newDeck, helpers, writeSvg, FILL } = require("../lib/engslides");

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
box(s, c[1], r[0], w, h, "Protocol wrapper", ["destination MAC filter", "ingress and egress queues", "leaf fan-out, arbiter"], W);
box(s, c[2], r[0], w, h, "Protocol leaves", ["ARP, ICMP echo, DHCP client", "iperf 2 UDP server", "UDP sockets, 4 ports"], W);
box(s, c[0], r[1], w, h, "MDIO", ["Clause 22 and Clause 45", "PHY reset and interrupt", "RTL8211E driver in C"], W);
box(s, c[2], r[1], w, h, "UDP application", ["UDP echo, or user logic", "on the socket payload streams"], W);

// CPU network path
box(s, c[1], r[1], w, h, "Frame classifier", ["L2-L4 filter, policers", "broadcast storm limiter", "drop-all until configured"], B);
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

writeSvg(pres, path.join(__dirname, "..", "out", "svg"), "product-brief").forEach((f) => console.log("wrote", f));
pres.writeFile({ fileName: path.join(__dirname, "..", "out", "product-brief.pptx") }).then((f) => console.log("wrote", f));
