// -----------------------------------------------------------------------------
// File: rtlnet_technology.svh
// Purpose: the ONE place an RTLNet build chooses its implementation technology.
//   Every technology-mapped RTLNet file (rtlnet_ram_core, the synchronizers,
//   the packet FIFO, the RGMII pin-layer selection) includes this file; no
//   technology parameter is passed down the hierarchy.
// Overview:
//   * At most one RTLNET_TECH_* macro is defined; with none, AMD is selected.
//     Choose another by defining it on the tool command line
//     (+define+RTLNET_TECH_ALTERA, Vivado verilog_define, Quartus
//     VERILOG_MACRO, Synplify define), or change the default branch below.
//       RTLNET_TECH_AMD      AMD/Xilinx 7-series and UltraScale(+) (default)
//       RTLNET_TECH_ALTERA   Intel/Altera (Quartus)
//       RTLNET_TECH_LATTICE  Lattice (Radiant / Diamond, Synplify Pro or LSE)
//       RTLNET_TECH_GENERIC  behavioural models (simulation, ASIC front end)
//   * Derived macros, used by the mapped files:
//       `RTLNET_TARGET       string "AMD" | "ALTERA" | "LATTICE" | "GENERIC"
//       `RTLNET_SYNC_ATTR    attribute instance placed on every synchronizer
//                            register: no merge, no shift-register packing,
//                            placed together
//       `RTLNET_RGMII_IO     RGMII pin-layer module for the family
// Language: SystemVerilog-2012 (preprocessor only).
// Revision: 10-22-2026
//   * 10-22-2026: initial version.
// Clocks: none.
// -----------------------------------------------------------------------------
`ifndef RTLNET_TECHNOLOGY_SVH
`define RTLNET_TECHNOLOGY_SVH

`ifdef RTLNET_TECH_ALTERA
  `define RTLNET_TARGET    "ALTERA"
  `define RTLNET_SYNC_ATTR (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS; -name DONT_MERGE_REGISTER ON; -name PRESERVE_REGISTER ON" *)
  `define RTLNET_RGMII_IO  rtlnet_rgmii_io_altera
`elsif RTLNET_TECH_LATTICE
  `define RTLNET_TARGET    "LATTICE"
  `define RTLNET_SYNC_ATTR (* syn_preserve = 1, syn_srlstyle = "registers" *)
  `define RTLNET_RGMII_IO  rtlnet_rgmii_io_lattice
`elsif RTLNET_TECH_GENERIC
  `define RTLNET_TARGET    "GENERIC"
  `define RTLNET_SYNC_ATTR (* keep = 1 *)
  `define RTLNET_RGMII_IO  rtlnet_rgmii_io_generic
`else
  // AMD: the default, or an explicit RTLNET_TECH_AMD.
  `ifndef RTLNET_TECH_AMD
    `define RTLNET_TECH_AMD
  `endif
  `define RTLNET_TARGET    "AMD"
  `define RTLNET_SYNC_ATTR (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO", DONT_TOUCH = "TRUE" *)
  `define RTLNET_RGMII_IO  rtlnet_rgmii_io_amd7
`endif

`endif // RTLNET_TECHNOLOGY_SVH
