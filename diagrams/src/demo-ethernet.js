// Drawing set: demo-ethernet (2 sheets: the Ethernet demo set-up and data path) for
//   demos/ethernet/ethernet_brief.md               (sheet 1: Nexys Video, 10/100/1000 Mb/s RGMII)
//   demos/ethernet/ethernet_arty_a7_100_brief.md   (sheet 2: Arty A7-100T, 10/100 Mb/s MII)
// The sheets differ in the board, the PHY interface and the memory sizes.
// Build: node diagrams/src/demo-ethernet.js  ->  diagrams/out/demo-ethernet.pptx
// Render: powershell -File diagrams\tools\render.ps1 diagrams\out\demo-ethernet.pptx  ->  out/png/demo-ethernet-1.png, -2.png
// Fills: white = RTLNet RTL core, gray = soft CPU firmware, yellow = outside the FPGA.
const path = require("path");
const { newDeck, helpers, FILL } = require("../lib/engslides");

const pres = newDeck("IronKernel RTLNet Ethernet demo");
const { box, container, wire, label, notes, legend, frame } = helpers(pres);
const W = FILL.white, G = FILL.gray, Y = FILL.yellow;

const cx = [0.8, 3.4, 6.0, 8.6], w = 1.85;          // FPGA columns
const mx = cx.map((x) => x + w / 2);
const r0 = 1.0, h0 = 0.9, r1 = 2.35, h1 = 0.85, r2 = 3.7, h2 = 0.95;
const y0 = r0 + h0 / 2, y1 = r1 + h1 / 2, y2 = r2 + h2 / 2;
const xe = 11.4, ew = 1.35;                          // outside the FPGA
const wide = cx[1] + w - cx[0];

const BOARDS = [
  {
    fpga: "Artix-7 XC7A200T on the Nexys Video",
    mac: ["10/100/1000 Mb/s, RGMII", "FCS, padding, IFG"],
    phyIf: "RGMII",
    phy: ["Realtek RTL8211E", "10/100/1000 Mb/s", "full duplex", "RJ45 connector"],
    classifier: ["always on, pass-all mode", "policers: ARP, ICMP, UDP, broadcast"],
    buffer: ["dual-port frame buffer, 128 KiB", "frames sent in place, no copy"],
    cpu: ["MicroBlaze V, 100 MHz, 512 KiB block RAM, no DDR3, no caches",
          "lwIP 2.2.0: TCP echo port 7, TCP iperf 2 server port 5001",
          "console, PHY driver chosen from the MDIO ID"],
    link: "Ethernet, 10/100/1000 Mb/s",
    note: "One 100 MHz system clock runs the MAC client side, the protocol blocks and the CPU; only the RGMII clocks and the 200 MHz delay-control clock are separate.",
  },
  {
    fpga: "Artix-7 XC7A100T on the Arty A7-100T",
    mac: ["10/100 Mb/s, MII", "FCS, padding, IFG"],
    phyIf: "MII",
    phy: ["TI DP83848J", "10/100 Mb/s", "full duplex", "RJ45 connector"],
    classifier: ["always on, distributed RAM", "policers: ARP, ICMP, UDP, broadcast"],
    buffer: ["dual-port frame buffer, 64 KiB", "DMA writes and reads frames here"],
    cpu: ["MicroBlaze V, 100 MHz, 256 KiB block RAM, no DDR3, no caches",
          "lwIP 2.2.0: TCP echo port 7, TCP iperf 2 server port 5001",
          "console, PHY driver chosen from the MDIO ID"],
    link: "Ethernet, 10/100 Mb/s",
    note: "One 100 MHz system clock runs the MAC client side, the protocol blocks and the CPU; the FPGA also supplies the 25 MHz reference clock of the PHY, and the MII clocks come from the PHY.",
  },
];

function sheet(b) {
  const s = pres.addSlide();
  container(s, 0.5, 0.5, 10.25, 4.45, b.fpga);

  // Hardware data path: protocols <-> wrapper <-> MAC <-> PHY
  box(s, cx[0], r0, wide, h0, "Hardware protocols",
    ["ARP, ICMP echo (ping), DHCP client", "UDP echo, UDP iperf 2 server", "answered in logic, the CPU is not involved"], W);
  box(s, cx[2], r0, w, h0, "Protocol wrapper", ["ingress filter", "CPU frames and replies merge"], W);
  box(s, cx[3], r0, w, h0, "Ethernet MAC", b.mac, W);

  // CPU path: classifier -> checksum offload -> DMA and frame buffer
  box(s, cx[2], r1, w, h1, "Classifier", b.classifier, W);
  box(s, cx[1], r1, w, h1, "TCP offload", ["checksums: TX in place, RX verify", "ACK coalescing"], W);
  box(s, cx[0], r1, w, h1, "AXI DMA", b.buffer, W);

  // CPU and control
  box(s, cx[0], r2, wide, h2, "MicroBlaze V firmware", b.cpu, G);
  box(s, cx[2], r2, cx[3] + w - cx[2], h2, "Registers and MDIO master",
    ["AXI4-Lite: status and counters of every core, policer limits",
     "MDIO: PHY ID, link status, speed 10|100|auto"], W);

  // Outside the FPGA
  box(s, xe, r0, ew, r2 + h2 - r0, "Ethernet PHY", b.phy, Y);
  box(s, cx[0], 5.45, xe + ew - cx[0], 0.7, "PC (Windows)",
    ["ping, iperf 2, the test scripts run_all.ps1 and flood_test.ps1", "serial terminal, 115200 baud, 8N1", "Vivado programming script"], Y);

  // Hardware path connectors
  wire(s, cx[1] + w, y0, cx[2], y0, { start: true });
  label(s, cx[1] + w + 0.03, y0 - 0.2, 0.7, "AXI4-Stream");
  wire(s, cx[2] + w, y0, cx[3], y0, { start: true });
  label(s, cx[2] + w + 0.03, y0 - 0.2, 0.7, "AXI4-Stream");
  wire(s, cx[3] + w, y0, xe, y0, { start: true });
  label(s, 10.78, y0 - 0.2, 0.55, b.phyIf);

  // CPU path connectors
  wire(s, mx[2], r0 + h0, mx[2], r1, { start: true });
  label(s, mx[2] + 0.1, 2.0, 2.4, "frames the hardware does not answer");
  wire(s, cx[1] + w, y1, cx[2], y1, { start: true });
  label(s, cx[1] + w + 0.03, y1 - 0.2, 0.7, "AXI4-Stream");
  wire(s, cx[0] + w, y1, cx[1], y1, { start: true });
  label(s, cx[0] + w + 0.03, y1 - 0.2, 0.7, "AXI4-Stream");
  wire(s, mx[0], r1 + h1, mx[0], r2, { start: true });
  label(s, mx[0] + 0.1, 3.35, 2.4, "frame buffer on the data-side LMB");

  // Control connectors
  wire(s, cx[1] + w, y2, cx[2], y2, { start: true });
  label(s, cx[1] + w + 0.03, y2 - 0.2, 0.7, "AXI4-Lite");
  wire(s, cx[3] + w, y2, xe, y2, { start: true });
  label(s, 10.78, y2 - 0.2, 0.55, "MDIO");

  // PC links
  wire(s, mx[0], 5.45, mx[0], r2 + h2, { start: true });
  label(s, mx[0] + 0.1, 5.05, 1.5, "USB-UART console");
  wire(s, mx[2], 5.45, mx[2], 4.95, { dash: "dash", start: false });
  label(s, mx[2] + 0.1, 5.05, 2.6, "USB-JTAG: bitstream with firmware");
  wire(s, xe + ew / 2, 5.45, xe + ew / 2, r2 + h2, { start: true });
  label(s, 9.7, 5.05, 2.3, b.link, 7.5, "right");

  notes(s, 0.6, 6.25, 12.1, 0.5, [
    "The hardware answers ARP, ping, DHCP, UDP echo and UDP iperf 2 with no CPU in the data path; only frames it does not answer (TCP, for example) pass the classifier and reach lwIP.",
    b.note,
  ]);
  legend(s, 0.6, 6.85, [["RTLNet RTL core", W], ["MicroBlaze V firmware", G], ["Outside the FPGA", Y]], 3.2);
  frame(s);
}

BOARDS.forEach(sheet);

pres.writeFile({ fileName: path.join(__dirname, "..", "out", "demo-ethernet.pptx") }).then((f) => console.log("wrote", f));
