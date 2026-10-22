# rtlnet_cpu_microblaze — RTLNet CPU core (MicroBlaze) and its firmware

| Item | Value |
|---|---|
| Core | `rtlnet_cpu_microblaze` (folder `microblaze/`) |
| Document revision | 10-22-2026 |
| Language | SystemVerilog-2012 wrapper; Vivado Tcl block design; C11 firmware |
| Technology | AMD 7-series (the one AMD-only block of RTLNet, architecture section 3) |
| Port contract | architecture section 15.6 |
| Verification | board benches with `rtlnet_microblaze_sim_stub` in place of the core (the processor is never simulated); firmware on hardware and in the desktop harness |

The CPU is a core like any other: a vendor-neutral port list around the processor subsystem. The
MicroBlaze block design is created by script on every build; the firmware's BSP is generated from the
build's hardware export by the Vitis tools of the AMD install. Nothing generated and nothing from the
install is committed.

## 1. Files

| File | Content |
|---|---|
| `hdl/rtlnet_cpu_bd.tcl` | `rtlnet_cpu_bd_create <bd_dir>`: creates, validates and saves the block design `rtlnet_cpu`, returns the `.bd` path |
| `hdl/rtlnet_cpu_microblaze.sv` | the core: section 15.6 ports, instance `u_bd` of the generated `rtlnet_cpu_wrapper` |
| `hdl/rtlnet_cpu_microblaze.f` | filelist (the wrapper `.sv`; the build adds the generated wrapper) |
| `driver/rtlnet_cpu_microblaze.h` | software contract: address map, vectors, interrupt numbering (single definition) |
| `rtlnet_microblaze_sim_stub.sv` | simulation stand-in with the same ports (section 7) |
| `firmware/` | the firmware: `build.ps1`, `bsp/rtlnet_bsp.py`, `src/`, `cli/`, `host/`, `test/` (section 10) |

## 2. Interface

| Group | Ports | Contract |
|---|---|---|
| clock, reset | `clk`, `resetn` | cpu_clk 100 MHz from the board MMCM; `resetn` synchronous to `clk`, active low (board `rtlnet_reset_sync`) |
| console | in `uart_rxd`, out `uart_txd` | USB-UART bridge, 115200 8N1; `uart_rxd` is asynchronous, idle high |
| register master | `m_axi_aw*`, `m_axi_w*`, `m_axi_b*`, `m_axi_ar*`, `m_axi_r*` | AXI4-Lite master, 32-bit address and data, full processor addresses (0x44A0_0000..0x44AF_FFFF), into `rtlnet_axil_decoder`; one transaction at a time |
| interrupts | in `irq[7:0]` | level, active high, synchronous to `clk`; INTC inputs 0..7 |
| frames to the network | out `m_axis_eth_tdata[63:0]`, `m_axis_eth_tkeep[7:0]`, `m_axis_eth_tvalid`, `m_axis_eth_tlast`; in `m_axis_eth_tready` | AXI DMA MM2S, RTLNet stream (architecture 4), complete Ethernet frames without FCS; to the protocol wrapper's `s_axis_cpu_eth_*` |
| frames from the network | in `s_axis_eth_tdata[63:0]`, `s_axis_eth_tkeep[7:0]`, `s_axis_eth_tvalid`, `s_axis_eth_tlast`; out `s_axis_eth_tready` | AXI DMA S2MM, frames no protocol leaf claims, from the wrapper's `m_axis_cpu_eth_*` |

`uart_rxd` needs no synchronizer in the wrapper: the UART Lite synchronizes it with its own two-stage
`ASYNC_REG` chain (`UARTLITE_RX_I/INPUT_DOUBLE_REGS3`). A replacement processor must synchronize its
receive pin the same way. AWPROT/ARPROT of the block design stay inside the wrapper (RTLNet slaves do
not use them). The frame streams are in `clk`; the protocol wrapper's CPU FIFOs cross to `proto_clk`.

## 3. Block design `rtlnet_cpu`

| Cell | IP | Configuration |
|---|---|---|
| `microblaze_0` | MicroBlaze 11.0 (classic) | 32-bit, little endian (`C_ENDIANNESS` 1), 5-stage pipeline (`C_AREA_OPTIMIZED` 0), no MMU, **no caches**, no FPU, **no branch target cache** (kept off: no measured need, and it is not free in LUTs and timing), barrel shifter, 32-bit hardware multiplier (`C_USE_HW_MUL` 1), hardware divider, pattern compare, MSR instructions, interrupt input (normal mode), debug enabled, D-AXI on, I-AXI off, `C_BASE_VECTORS` 0, bus exceptions off (a DECERR reads as data) |
| `ilmb_v10`, `dlmb_v10` | LMB 3.0 | instruction and data local memory buses |
| `ilmb_bram_if_cntlr`, `dlmb_bram_if_cntlr` | LMB BRAM controller 4.0 | no ECC |
| `lmb_bram` | Block Memory Generator 8.4 | true dual port, BRAM controller mode; **512 KiB = 128 RAMB36** (code, data, stack, heap, lwIP) |
| `mdm_0` | MDM 3.2 | one debug port, JTAG UART on (AXI slave) |
| `axi_uartlite_0` | AXI UART Lite 2.0 | 115200 baud, 8 data bits, no parity (1 stop bit) |
| `axi_timer_0` | AXI Timer 2.0 | two 32-bit counters: counter 0 free running (ticks, delays), counter 1 the 1 ms interrupt |
| `axi_intc_0` | AXI INTC 4.1 | 12 inputs from `irq_concat`; kinds detected from the sources (level; UART edge) |
| `irq_concat` | inline concat 1.0 | `{dma_s2mm, dma_mm2s, uart, timer, irq[7:0]}` |
| `axi_dma_0` | AXI DMA 7.1 | simple (direct register) mode, no scatter-gather, 64-bit memory side and 64-bit streams, no realignment engine, `c_sg_length_width` 14 (16383-byte transfers), bursts 16 |
| `axi_bram_ctrl_0` + `axi_bram` | AXI BRAM controller 4.1 + Block Memory Generator 8.4 | AXI4, 64-bit, single port; **128 KiB = 32 RAMB36**, the DMA frame buffers |
| `axi_periph` | AXI Interconnect 2.1 | 1 slave (M_AXI_DP), 7 masters: UART, timer, INTC, MDM, `M_AXI_RTLNET`, DMA registers, memory path |
| `axi_mem` | AXI Interconnect 2.1 | 3 slaves (memory path from `axi_periph`, DMA MM2S, DMA S2MM), 1 master (AXI BRAM controller); 32 -> 64-bit conversion for the CPU path |
| `rst_cpu` | Processor System Reset 5.0 | `ext_reset_in` = port `resetn` (active low), `mb_debug_sys_rst` from the MDM; `dcm_locked` tied 1 |
| `const_one` | inline constant 1.0 | `dcm_locked` tie |

No clocking wizard: every clock pin is the `clk` port (`FREQ_HZ` 100 MHz). All firmware runs from internal
block RAM; no external memory is used. Block RAM of the core: 160 RAMB36 (LMB 128, AXI BRAM 32) of the
XC7A200T's 365.

## 4. Address map

| Base | Size | Block |
|---|---:|---|
| 0x0000_0000 | 512 KiB | LMB BRAM (ILMB and DLMB): vectors, code, data, heap, stack, lwIP heap and pools |
| 0x4040_0000 | 64 KiB | AXI DMA registers (MM2S 0x00, S2MM 0x30) |
| 0x4060_0000 | 64 KiB | AXI UART Lite (console) |
| 0x4120_0000 | 64 KiB | AXI INTC |
| 0x4140_0000 | 4 KiB | MDM (JTAG UART) |
| 0x41C0_0000 | 64 KiB | AXI Timer |
| 0x44A0_0000 | 1 MiB | `M_AXI_RTLNET` (RTLNet register window, decoded by the board top) |
| 0xC000_0000 | 128 KiB | AXI BRAM: DMA frame buffers (MicroBlaze data side and both DMA channels) |

Interrupt inputs: 0..7 = `irq[7:0]`, 8 = timer, 9 = UART, 10 = DMA MM2S, 11 = DMA S2MM. Vectors (BSP
start-up `crt0`): reset 0x00, user exception 0x08, interrupt 0x10, hardware exception 0x20. The single
definition for software is `driver/rtlnet_cpu_microblaze.h`; the BSP's generated `xparameters.h` carries the
same base addresses. Its `XPAR_FABRIC_*` interrupt numbers count the `irq_concat` *ports* (timer 1, DMA 3/4)
instead of the INTC input bits; the firmware uses the header's numbering, which matches the hardware
(`XPAR_AXI_INTC_0_KIND_OF_INTR` 0x200 = edge on input 9, the UART, confirms it).

Names other flows depend on: the MMI written by `write_mem_info` names the processor
`u_cpu/u_bd/rtlnet_cpu_i/microblaze_0` (board instance `u_cpu`), the path `updatemem -proc` takes; the
MMI lists two address spaces (LMB 0..524287 with 128 RAMB36 lanes, AXI BRAM 0xC000_0000..0xC001_FFFF);
the firmware places nothing loadable in the AXI BRAM, so updatemem fills the LMB only.

## 5. Hardware export and BSP

`boards/nexys_video/scripts/build_bitstream.tcl` writes `build/rtlnet_nexys_video.xsa`
(`write_hw_platform -fixed -include_bit`) after the bitstream. `microblaze/firmware/build.ps1` turns it
into a standalone BSP with the Vitis 2025.2 Python API, `vitis -s bsp/rtlnet_bsp.py <xsa> build/ws`:

1. `client.create_platform_component(name="p", hw_design=<xsa>, os="standalone", cpu="microblaze_0",
   domain_name="d")` (the Vitis server runs `sdtgen` and `lopper`; `Vivado/bin` must be on `PATH`, the
   Vitis `bin` of this install has no `sdtgen`);
2. `domain.set_config("os", "standalone_stdin"/"standalone_stdout", "axi_uartlite_0")`;
3. `platform.build()`.

Output (ignored folder `microblaze/firmware/build/ws/p/microblaze_0/d/bsp`): `include/` (xparameters.h,
driver headers), `lib/libxil.a` (drivers), `lib/libxilstandalone.a`, `lib/libxiltimer.a`, `Xilinx.spec`
(start files `crt0`, `crti`, `crtbegin`, `crtinit`), `cflags.yaml`. Versions used from
`C:\Xilinx\2025.2\Vitis\data\embeddedsw`: standalone v9.4, axidma v9.20, uartlite v3.12, tmrctr v4.14,
intc v3.21, bram v4.13, xiltimer v2.3. The drivers use the system-device-tree API (`-DSDT`, base
addresses instead of device IDs).

**lwIP is not a BSP library here.** The install's `lwip220` library refuses a hardware design without a
vendor Ethernet MAC (`emaclite`, `axiethernet` or `emacps`): its validation stops with "lwip220 requires at
least one ethernet hardware instance to be present" and its CMakeLists with "This library requires an
Ethernet MAC IP instance in the hardware". RTLNet reaches the wire through its own MAC and protocol wrapper,
so `build.ps1` compiles the lwIP 2.2.0 core of the same install
(`ThirdParty/sw_services/lwip220_v1_3/src/lwip-2.2.0/src`: core, core/ipv4, netif/ethernet.c) in place,
with `firmware/src/lwip/lwipopts.h` and the install's `contrib/ports/xilinx/include/arch` headers. Nothing is
copied.

Windows path limit: the BSP build fails on object paths above about 250 characters, so the workspace,
platform and domain names are one letter each; `build.ps1` stops with a clear message when a checkout is
too deep.

## 6. Firmware toolchain contract

`mb-gcc` 13.3 (`C:\Xilinx\2025.2\gnu\microblaze\nt\bin`), processor flags taken from the BSP's
`cflags.yaml` (`-mxl-barrel-shift -mlittle-endian -mxl-pattern-compare -mno-xl-soft-mul -mcpu=v11.0`) plus
`-mno-xl-soft-div -DSDT`; `-specs=Xilinx.spec`; the linker script `build/lscript.ld` is generated from the
install's template `Vitis/data/embeddedsw/scripts/linker_files/lscript_mb.ld.in` (vectors at 0x0/0x8/0x10/0x20,
code and data in the LMB region from 0x50, 8 KiB stack, 2 KiB heap) plus the NOLOAD section `.axi_bram`
in the AXI BRAM region. Libraries: `-lxil -lxilstandalone -lxiltimer -lgcc -lc` in one group.

## 7. Simulation stand-in

`rtlnet_microblaze_sim_stub.sv` (module `rtlnet_microblaze_sim_stub`, same ports) replaces the core when a
bench defines `RTLNET_MICROBLAZE_SIM_STUB`; the board top then instances it as `u_cpu`. The processor itself
is never simulated. Tasks (called hierarchically, `dut.u_cpu.<task>`): `wait_reset_release`,
`axil_write(addr, data, strb, resp)`, `axil_read(addr, data, resp)` (timeouts return resp 2'b10 and count
`axil_timeouts`), `axil_set_bits` / `axil_clear_bits` (read-modify-write), `cls_config_bcast_storm(base,
limit, window, resp)` (the classifier register sequence of the driver's broadcast storm configuration,
offsets from the classifier specification), `uart_send(byte)` on `uart_txd`, a receiver on `uart_rxd` into
`uart_rx_q` (`uart_get`, `uart_rx_errors`), `wait_irq(mask, timeout, ok)`, and the DMA stand-in:
`eth_send(frame)` on `m_axis_eth_*`, a sink on `s_axis_eth_*` into `eth_rx_q` (`eth_get`, `eth_rx_ready`
back-pressure control, `eth_tx_frames`, `eth_rx_frames`, `eth_rx_keep_errors`).

## 8. Replacing the processor (Nios V, another RISC-V)

The board top instances `u_cpu` with exactly the section 15.6 ports. A replacement is a new folder with
`hdl/rtlnet_cpu_<name>.sv` of the same module ports wrapping the vendor system:

1. Platform Designer (or the vendor's equivalent) system with the processor, on-chip RAM, a UART, a timer,
   an interrupt controller, a DMA between memory and the two frame streams, and an AXI4-Lite master
   covering 0x44A0_0000 + 1 MiB at the same processor address.
2. Clock and reset from the ports (no PLL inside); the receive pin synchronized inside.
3. The board top selects the module by name; the decoder, the system registers and every core below the
   decoder are unchanged.
4. Software: a `driver/rtlnet_cpu_<name>.h` with the same macro names, the platform API
   (`plat_console_write`, `plat_uptime_ms`, ...) and the netif's DMA calls on that vendor's drivers. The
   CLI, the network manager, lwIP and every RTLNet core driver compile unchanged.

## 9. Firmware

### 9.1 Layers and files

| Layer | Files | Owns |
|---|---|---|
| BSP (generated) | `build/ws/.../bsp` | start-up (`crt0`, `crtinit`), vectors, interrupt dispatch, XUartLite, XTmrCtr, XIntc, XAxiDma, `xil_printf` |
| platform | `src/rtlnet_platform.c/.h` | console on XUartLite (receive ring, bounded transmit wait), time on XTmrCtr (counter 0 free running, counter 1 1 ms interrupt through XIntc), LEDs and heartbeat, soft restart |
| board | `src/rtlnet_board.c/.h`, `src/rtlnet_nexys_video_sysregs.h` | system registers, core-header probing |
| RTLNet drivers | `cores/<core>/driver/*.c`, compiled in place | each core's registers |
| network manager | `src/rtlnet_netmgr.c/.h` | PHY bring-up, link monitor, DHCP auto-start, addresses, CPU path bring-up, InitLWIP calls |
| CPU path control | `src/rtlnet_cpupath.c/.h` | CPU-path classifier configuration (broadcast storm default, filter tables, policers), wrapper CPU-path counters |
| lwIP glue | `src/rtlnet_lwip.c/.h`, `src/lwip/lwipopts.h` | `InitLWIP()`, `sys_now`, main-loop service, status and counters |
| netif | `src/rtlnet_lwip_netif.c/.h` | the AXI DMA: receive ring, transmit, frame counters |
| applications | `src/rtlnet_tcp_echo.c/.h` | TCP echo server, port 7 |
| CLI | `cli/menu.c`, `cli/cli_commands.c`, generated `cli/menu_table.c`, `cli/menu_commands.h`, `cli/MenuDocumentation.md` | MenuBuilder hierarchical rules (`cli/MenuBuilder_hierarchical.md`) |
| desktop harness | `host/main.c`, `host/host_platform.c`, `host/host_lwip_stub.c` | scripted `--demo` of the real CLI and network manager against a register model |
| host test | `test/tcp_echo_client.py` | TCP echo test from the PC |

The hand-written start-up, linker script, UART, timer and string files of the first firmware are gone; the
BSP provides those services. `rtlnet_fmt.c` stays as the console formatter (also used by the harness);
its output goes through `plat_console_write` to XUartLite.

### 9.2 Main loop

`main`: `plat_init` (UART, timer, INTC, interrupts on), `cli_start` (banner, menu engine, `netmgr_init`),
then forever: one console character into the line editor, `plat_poll` (heartbeat), `rtlnet_lwip_poll`
(DMA receive service, `sys_check_timeouts`), `netmgr_poll` (every 250 ms: PHY link, DHCP lease, InitLWIP
consistency check). Only the 1 ms timer interrupt runs outside the loop; it increments the tick and
nothing else.

### 9.3 InitLWIP()

The protocol wrapper owns the node identity; lwIP must use the same MAC and IPv4 address, because the
hardware leaves answer ARP and ping for that address and lwIP only sees unclaimed frames. `InitLWIP()`
(`src/rtlnet_lwip.c`) reads the MAC and the effective IP, netmask and gateway through the
`rtlnet_eth_protocol` driver and:

| Call | Action | Result |
|---|---|---|
| protocol core absent (CPU-only bitstream) | nothing; lwIP stays off | `RTLNET_LWIP_NO_PROTOCOL` |
| AXI DMA absent | nothing | `RTLNET_LWIP_NO_DMA` |
| first call | `lwip_init()`, `netif_add` (DMA netif, RTL values, `ethernet_input`), default, up, link state as last reported; the TCP echo server opens its listen PCB | `RTLNET_LWIP_STARTED` |
| later call, MAC differs | `etharp_cleanup_netif`, new `netif->hwaddr` | `RTLNET_LWIP_RECONFIGURED` |
| later call, IP / mask / gateway differ | `netif_set_addr`, `etharp_cleanup_netif` | `RTLNET_LWIP_RECONFIGURED` |
| later call, everything matches | nothing | `RTLNET_LWIP_UNCHANGED` |

Callers (`rtlnet_netmgr.c`): boot after the protocol core is probed and the classifier configured; link up;
DHCP bound, lost or bound to a new address; `netmgr_apply_addresses` (CLI `ip address`, `ip netmask`,
`ip default-gateway`, `mac-address`, `no ip ...`); and every 250 ms as a consistency check (a no-op while
the values agree). `show tcp` prints the netif identity, the RTL identity it follows and the call history.

### 9.4 lwIP netif on the AXI DMA

Receive (polled): four 2 KiB buffers in the AXI BRAM form a ring; one S2MM simple transfer is armed at a
time. On completion the next buffer is armed at once, the length is read from the S2MM length register, the
frame is copied into a pool pbuf and given to `netif->input`. Up to 8 frames per poll. No pbuf: dropped and
counted (`rx_no_pbuf`); an S2MM error status resets the DMA and re-arms (`rx_errors`, `dma_resets`). While
no transfer is armed the wrapper's 16 KiB CPU receive FIFO holds the frames. Transmit: `linkoutput` copies
the pbuf chain into one of two 2 KiB TX buffers, waits at most 2 ms for the previous MM2S transfer and
starts the next one (`tx_timeouts`, `tx_too_long`, `tx_errors`). No caches exist, so the buffers need no
flush or invalidate.

### 9.5 lwIP configuration and memory

NO_SYS 1, raw API, IPv4, ARP, ICMP, UDP, TCP; no DHCP, AutoIP, IGMP, DNS, IPv6 in lwIP (the RTL DHCP
leaf owns the address). Sizes for the TCP echo server and the TCP iperf server running together:
`MEM_SIZE` 24 KiB, `PBUF_POOL_SIZE` 24 x 1536 B, `MEMP_NUM_TCP_PCB` 12, `MEMP_NUM_TCP_PCB_LISTEN` 4,
`MEMP_NUM_TCP_SEG` 48, `TCP_MSS` 1460, `TCP_WND` and `TCP_SND_BUF` 4 x MSS (5840 B). Everything lwIP
allocates is in the LMB (`.bss`); the AXI BRAM holds only the 12 KiB of DMA buffers.

### 9.6 CPU path control and the CLI

`rtlnet_cpupath.c` keeps the classifier configuration (the running configuration) and writes it through the
classifier driver: default MODE pass-all, MAC entry 0 destination FF:FF:FF:FF:FF:FF policed by policer 0,
policer 0 = 10 frames per 100 ms. The classifier powers up drop-all; `netmgr_init` configures it before the
first InitLWIP. The classifier driver and the wrapper's CPU-path register functions are written in parallel
with this firmware: until they are in the tree the configuration is kept, `show` commands report "driver
not in this firmware build", and a bitstream without the classifier reports it absent.

CLI additions (75 commands in all, MenuBuilder hierarchical rules, `cli/MenuDocumentation.md`):
`show tcp`, `show cpu-path`, `show storm-control`, `show classifier`; config `tcp echo enable|disable`,
`tcp echo port <n>`, `classifier mode|policer|mac|ethertype|acl|defaults`, `no classifier
mac|ethertype|acl|policer <n>`; config-if `storm-control broadcast <packets> <ms>`, `storm-control broadcast
enable|disable`, `no storm-control broadcast`. `show running-config` prints the storm-control, TCP echo and
classifier lines; `show counters` and `clear counters` include the DMA, classifier and TCP echo counters.
The engine limits grew for the ACL syntax (14 tokens, 14 parameters, 160-character lines, 88 table entries).

### 9.7 Size

Build of record (commit 874f3966): text 139304 B, data 2104 B, bss 127732 B, heap 2 KiB, stack 8 KiB,
271 KiB of the 512 KiB LMB. The CLI and drivers are compiled `-Os`, the frame path (netif, lwIP glue,
TCP echo, lwIP) `-O2`. With the 256 KiB LMB the image did not link (`.bss` overflow), which is why the LMB
is 512 KiB.

## 10. Build and test commands

```
powershell -NoProfile -ExecutionPolicy Bypass -File boards/nexys_video/scripts/build.ps1 [-Network] [-Program] [-Test]
powershell -NoProfile -ExecutionPolicy Bypass -File microblaze/firmware/build.ps1 [-Xsa <xsa>] [-Bsp] [-Demo]
python microblaze/firmware/test/tcp_echo_client.py <board ip> [--conns 4] [--rounds 1]
```

`tcp_echo_client.py`: N concurrent connections, payloads 1 byte to 64 KiB including the boundaries
around the MSS (1459/1460/1461), the window (5839/5840/5841) and powers of two, interleaved send/receive
(no deadlock on payloads larger than the window), byte-exact compare with the first differing offset, per
size latency (min/mean/max) and total throughput; one anchored line `TCP_ECHO_TEST: PASS ...` or
`TCP_ECHO_TEST: FAIL <reason>`. Checked on the PC against a local echo server (PASS, 4 connections x 2
rounds, 304 messages, 2.36 MB) and against a server that corrupts one byte (FAIL naming the offset) and a
closed port (FAIL, connection refused).

## 11. Verification and results

| Check | Result (10-22-2026) |
|---|---|
| Block design creation, validation, wrapper (Vivado 2025.2) | no errors, 0 critical warnings |
| CPU-only board build (commit 874f3966), post-route | WNS +0.701 ns, WHS +0.014 ns, 0 failing endpoints; 5294 LUTs, 5564 FFs, 162 BRAM tiles |
| XSA -> BSP (Vitis Python API) | `RTLNET_BSP: PASS` |
| Hardware: CLI over the USB-UART on the BSP-based firmware | `cli_test.ps1` PASS 27/27; `reload` works; 1 ms interrupt tick equals the hardware uptime |
| Desktop harness | TEST PASS 248 checks; negative control TEST FAIL |
| Board bench `tb_rtlnet_nexys_video_top` with the simulation stand-in | TEST PASS 74 checks |

Details: `boards/nexys_video/documentation/rtlnet_nexys_video.md` section 6.3.

## 12. Limitations and open points

- The DMA interrupts are wired to the INTC but unused; the netif polls (no interrupt latency or nesting
  questions, and the main loop runs continuously).
- The classifier driver and the wrapper CPU-path register functions are bound by their specified names;
  the integration adapts the calls if the final signatures differ.
- A soft restart (`reload`) jumps to the reset vector: the BSP start-up clears `.bss` but does not reload
  `.data`, so no firmware state relies on a `.data` initial value.
- The MDM's BSCAN clocks are constrained by the vendor IP itself; the build waives TIMING-9 only while
  `report_cdc` shows no Critical/Warning finding.

## 13. Revision history

| Revision | Change |
|---|---|
| 10-22-2026 | Initial version: block design script, wrapper, driver header, bus-functional model |
| 10-22-2026 | Moved to `microblaze/`; LMB 512 KiB; AXI DMA and 128 KiB AXI BRAM with the frame streams; simulation stand-in renamed `rtlnet_microblaze_sim_stub`; BSP generated from the XSA; firmware on the BSP with lwIP, InitLWIP, DMA netif, TCP echo, CPU path CLI |
