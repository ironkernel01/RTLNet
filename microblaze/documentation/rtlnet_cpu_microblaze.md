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
| `axi_dma_0` | AXI DMA 7.1 | simple (direct register) mode, no scatter-gather, 64-bit memory side and 64-bit streams, realignment engine on MM2S only (transmit buffers at any byte address) and none on S2MM, `c_sg_length_width` 14 (16383-byte transfers), bursts 16 |
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
the register sequence of `rtlnet_classifier_init` and `rtlnet_classifier_config_bcast_storm`, offsets and bits of `cores/rtlnet_classifier/driver/rtlnet_classifier.h`; it returns resp 2'b11 when ID/VERSION do not read back), `uart_send(byte)` on `uart_txd`, a receiver on `uart_rxd` into
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
| lwIP glue | `src/lwip/rtlnet_lwip.c/.h`, `src/lwip/lwipopts.h` | `InitLWIP()`, `sys_now`, main-loop service, status and counters |
| netif | `src/lwip/rtlnet_lwip_netif.c/.h` | the AXI DMA: receive ring, transmit, frame counters |
| applications | `src/lwip/rtlnet_tcp_echo.c/.h`, `src/lwip/rtlnet_tcp_iperf.c/.h` | TCP echo server (port 7); TCP iperf 2 server (port 5001) status and CLI glue; both run at the same time, both on at boot |
| iperf server | `src/lwip/rtlnet_lwiperf.c/.h` | the project copy of lwIP's `lwiperf` with the reverse (-R), tradeoff (-r) and dual (-d) modes (section 9.9) |
| CLI | `cli/menu.c`, `cli/cli_commands.c`, generated `cli/menu_table.c`, `cli/menu_commands.h`, `cli/MenuDocumentation.md` | MenuBuilder hierarchical rules (`cli/MenuBuilder_hierarchical.md`) |
| desktop harness | `host/main.c`, `host/host_platform.c`, `host/host_lwip_stub.c` | scripted `--demo` of the real CLI and network manager against a register model |
| host tests | `test/tcp_echo_client.py`, `test/iperf_header_capture.py`, `test/iperf_board_emulator.py`, `test/lwiperf_loopback/` | TCP echo test from the PC; iperf 2 header capture; the board's iperf behavior in Python against the stock client; desktop loopback test of `rtlnet_lwiperf.c` |

The hand-written start-up, linker script, UART, timer and string files of the first firmware are gone; the
BSP provides those services. `rtlnet_fmt.c` stays as the console formatter (also used by the harness);
its output goes through `plat_console_write` to XUartLite.

### 9.2 Main loop

`main`: `plat_init` (UART, timer, INTC, interrupts on), `cli_start` (banner, menu engine, `netmgr_init`),
then forever: one console character into the line editor, `plat_poll` (heartbeat), `rtlnet_lwip_poll`
(DMA receive service, `sys_check_timeouts`), `netmgr_poll` (every 250 ms: PHY link, DHCP lease, InitLWIP
consistency check). Only the 1 ms timer interrupt runs outside the loop; it increments the tick and
nothing else.

### 9.3 InitPHY()

`InitPHY()` (`src/rtlnet_netmgr.c`, declared next to `InitLWIP()` in `rtlnet_netmgr.h`) is the whole RTL8211E
bring-up in one place, in this order: MDIO driver on the MDIO core; wait for the core's power-on PHY reset,
then 30 ms settle; MDC calibration against the AXI timer; PHY probe (ID 0x001C/0xC915); RGMII RX delay on
(page 0xA4 register 28) with read-back; LEDs (`rtlnet_phy_rtl8211e_leds_default`: LINK steady, ACT blinking,
USER off; LCR 0x0070 / LACR 0x0010 on extended page 0x2C, read back); EEE advertisement off
(`rtlnet_phy_rtl8211e_set_eee_advert(mdio, 0)`, MMD 7.60; EEE makes the RJ45 LEDs blink); the configured
advertisement or forced speed; auto-negotiation restart. It returns `NETMGR_PHY_OK` or the first failing
step (`NETMGR_PHY_NO_MDIO`, `_POR_TIMEOUT`, `_NOT_FOUND`, `_RXDLY_FAIL`, `_LED_FAIL`, `_EEE_FAIL`,
`_AN_FAIL`) and prints one line (`PHY: RTL8211E ID 0x001CC915, RX delay 0xAD77 -> 0xAD77, ...`). The boot
sequence is `InitPHY()` then `InitLWIP()`; CLI `phy reset` pulses the PHY reset pin and calls `InitPHY()` again,
so RX delay, LEDs and EEE are always re-applied. `show phy` prints the LED registers and the EEE
advertisement; `phy mmd read|write` (Clause 45 over Clause 22) and `phy c45 read|write` (native Clause 45
frames, which the RTL8211E does not answer) are privileged debug commands.

### 9.4 InitLWIP()

The protocol wrapper owns the node identity; lwIP must use the same MAC and IPv4 address, because the
hardware leaves answer ARP and ping for that address and lwIP only sees unclaimed frames. `InitLWIP()`
(`src/lwip/rtlnet_lwip.c`) reads the MAC and the effective IP, netmask and gateway through the
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

### 9.5 lwIP netif on the AXI DMA

Receive (polled): four 2 KiB buffers in the AXI BRAM form a ring; one S2MM simple transfer is armed at a
time. On completion the next buffer is armed at once, the length is read from the S2MM length register, the
frame is copied into a pool pbuf with 32-bit reads (`axi_get_words`) and given to `netif->input`. Up to 8 frames per poll. No pbuf: dropped and
counted (`rx_no_pbuf`); an S2MM error status resets the DMA and re-arms (`rx_errors`, `dma_resets`). While
no transfer is armed the wrapper's 16 KiB CPU receive FIFO holds the frames. Transmit: `linkoutput` copies
the pbuf chain into one of two 2 KiB TX buffers with 32-bit writes only (`axi_put_chain`, section 9.10), waits
at most 2 ms for the previous MM2S transfer and starts the next one (`tx_timeouts`, `tx_too_long`, `tx_errors`). No caches exist, so the buffers need no
flush or invalidate. A channel counts as busy only while it runs and is not idle: `XAxiDma_Busy` reports a
halted channel (never started, or after a reset) as busy, which kept the first transmit waiting forever.

### 9.6 lwIP configuration and memory

NO_SYS 1, raw API, IPv4, ARP, ICMP, UDP, TCP; no DHCP, AutoIP, IGMP, DNS, IPv6 in lwIP (the RTL DHCP
leaf owns the address). Sizes for the TCP echo server and the TCP iperf server running together:
`TCP_MSS` 1460, `TCP_SND_BUF` 24 x MSS (35040 B), `TCP_SND_QUEUELEN` 96, `TCP_WND` 8 x MSS (11680 B),
`MEM_SIZE` 64 KiB, `PBUF_POOL_SIZE` 64 x 1536 B, `MEMP_NUM_TCP_SEG` 256, `MEMP_NUM_PBUF` 96,
`MEMP_NUM_TCP_PCB` 12, `MEMP_NUM_TCP_PCB_LISTEN` 4, `LWIP_CHKSUM_ALGORITHM` 3. Everything lwIP allocates
is in the LMB (`.bss`); the AXI BRAM holds only the 12 KiB of DMA buffers. The reasons for each value and the
measurements are in section 9.10; the header comment of `lwipopts.h` carries the memory budget and the drift
rule (the pool must hold `TCP_WND` for every connection that can be open at once, plus margin).

The window is bounded by the protocol wrapper's CPU receive FIFO (`CPU_RX_FIFO_KB` 32 in the board top), not
by lwIP memory: a PC sends a whole window per connection at line rate while the CPU drains slower, so the
sum of the open windows should fit the FIFO. With the 16 KiB FIFO four echo connections of 4 x MSS overflowed
it (24 CPU FIFO drops, retransmission stalls of about 0.4 s). With 8 x MSS two connections fit; the echo test
with four connections plus iperf opens 58 KB and shows a few "CPU FIFO drops" (11 in the four-connection echo
test), which TCP recovers.

### 9.7 CPU path control and the CLI

`rtlnet_cpupath.c` keeps the classifier configuration (the running configuration) and writes it through the
classifier driver (`cores/rtlnet_classifier/driver`, compiled in place; one `rtlnet_classifier_t` context for the
CPU-path instance at 0x44A1_8000, every driver call takes it first): default MODE pass-all, MAC entry 0
destination FF:FF:FF:FF:FF:FF policed by policer 0, policer 0 = 10 frames per 100 ms. The classifier powers up
drop-all. `netmgr_init` calls `cpupath_init()` after `InitPHY()` and the protocol probe and before
`InitLWIP()` and before the MAC receive path is enabled: `rtlnet_classifier_init(&ctx, 0x44A18000)` then, for
the default configuration, `rtlnet_classifier_config_bcast_storm(&ctx, 10, 100)`; it also sets the wrapper's
CPU-path enable. A bitstream without the classifier reads 0 at 0x44A1_8000 and the firmware reports it absent
("classifier not present in this build"; the settings stay in the running configuration).

Mapping of the CLI entries onto the driver (`hw_sync`, run by every setter: `clear_all`, entries, policers,
MODE last):

| CLI | Driver call | Notes |
|---|---|---|
| `classifier mac <0..15> dst\|src <mac> gate\|classify\|police <p>` | `rtlnet_classifier_mac_filter(ctx, i, mac, SIDE_DST/SRC, action)` | MAC table, single-value compare; no mask (the compare mode is per table and entry 0 is the storm entry) |
| `classifier ethertype <0..7> <t> [to <t>] ...` | `rtlnet_classifier_ethertype_filter(ctx, pair, lo, hi, action)` | range pair (entries 2i, 2i+1), hence 8 entries |
| `classifier acl <0..15> tcp\|udp\|any src <ip>/<n> dst <ip>/<n> [sport] [dport] ...` | `rtlnet_classifier_acl_add(ctx, i, proto, src, mask, dst, mask, ports, action)` | tuple table |
| actions | `RTLNET_CLS_ACT_GATE`; `RTLNET_CLS_ACT_CLASSIFY`; `RTLNET_CLS_ACT_CLASSIFY \| RTLNET_CLS_ACT_POLICE(p)` | the table-level CLASSIFY flag is set after the entries are written: classify-only unless one of the table's entries gates |
| `classifier policer <p> <pkts> <ms> [disable]`, `no classifier policer` | `rtlnet_classifier_policer_set` | |
| `classifier mode ...` | `rtlnet_classifier_set_mode` | |
| `storm-control broadcast <pkts> <ms>` | policer 0 + MAC entry 0, whole configuration rewritten | |
| `storm-control broadcast enable\|disable` | `rtlnet_classifier_bcast_storm_enable` | limit and window kept |
| `show classifier`, `show storm-control`, `show counters`, `clear counters` | `get_mode`, `get_status`, `counters`, `policer_get`, `clear_counters` | `show classifier` also prints the hardware MODE/STATUS, CAPS and the delay-line latency |

A configuration rewrite leaves the filter in drop-all for about 100 us (`clear_all`); frames in that window are
lost (TCP retransmits).

CLI additions (83 commands in all, MenuBuilder hierarchical rules, `cli/MenuDocumentation.md`):
`show tcp`, `show cpu-path`, `show storm-control`, `show classifier`, `show iperf` in two sections ("UDP (RTL
core)" from the iperf leaf, "TCP (firmware, lwIP)" from the rtlnet_lwiperf reports: the last two tests with
direction (pc->board, reverse -R, tradeoff -r, dual -d), result, peer, bytes, duration, kbit/s, plus the test counts
per way and the refused connections); privileged `phy reset`, `phy mmd read|write`, `phy c45 read|write`; config `tcp echo enable|disable`,
`tcp echo port <n>`, `iperf tcp enable|disable`, `iperf tcp port <n>`, `classifier mode|policer|mac|ethertype|acl|defaults`, `no classifier
mac|ethertype|acl|policer <n>`; config-if `storm-control broadcast <packets> <ms>`, `storm-control broadcast
enable|disable`, `no storm-control broadcast`. `show running-config` prints the storm-control, TCP echo and
classifier lines; `show counters` and `clear counters` include the DMA, classifier and TCP echo counters.
The engine limits grew for the ACL syntax (14 tokens, 14 parameters, 160-character lines, 88 table entries).

### 9.8 Size

Build of record (section 9.10 tuning): text 162356 B, data 2104 B, bss 238280 B, heap 2 KiB, stack 8 KiB;
the image ends at 381 KiB of the 512 KiB LMB (131 KiB free). Before the tuning: text 161412 B, bss 151412 B
(rtlnet_lwiperf with -R, -r, -d and the classifier driver; install lwiperf without the classifier driver,
commit a9e043e6: text 153724 B, 308 KiB; without lwiperf, commit 874f3966: 271 KiB). The CLI and drivers are
compiled `-Os`, the frame path (netif, lwIP glue, TCP echo, lwIP) `-O2`. With the 256 KiB LMB the image did
not link (`.bss` overflow), which is why the LMB is 512 KiB.

### 9.9 TCP iperf server (rtlnet_lwiperf)

**The fork.** lwIP 2.2.0's `src/apps/lwiperf/lwiperf.c` and `lwip/apps/lwiperf.h` from the AMD install are
copied to `src/lwip/rtlnet_lwiperf.c/.h` (the one exception to "nothing is copied from the install", asked for
by the project owner). The original BSD licence block stays byte-for-byte at the top of both files, directly
followed by a "Modified for RTLNet (10-22-2026)" note listing the changes; every change carries the grep tag
`RTLNET-MOD`. `build.ps1` compiles the copy (strict `-Wall -Wextra -Werror -pedantic`) and no longer compiles
the install's `apps/lwiperf/lwiperf.c`. Public symbols are `rtlnet_lwiperf_*` / `RTLNET_LWIPERF_*`, so nothing
collides with the install's header.

**Why.** The install's lwiperf receives PC -> board tests only (and has a client of its own that no PC
tool talks to). The stock iperf 2.2.2 client also measures board -> PC with `-R` (reverse), `-r` (tradeoff)
and `-d` (dual); those need a server that reads the 2.2 test header and sends. The copy also repairs defects
of the original that the CPU path exposed: a header check every 128 KiB that aborted a running test when a
segment boundary fell on the mark; a NULL dereference in the report after a connection error; `lwiperf_abort`
freeing the state without closing the pcbs (the listener kept a dangling argument after `iperf tcp disable`
or a port change); a bind that failed with ERR_USE for two minutes after a test (TIME_WAIT) and left the
server off; a byte-limited test that ended at once; leaks on the start failure paths.

**Client test header, captured.** `test/iperf_header_capture.py` listens on TCP and prints the first bytes of
`iperf.exe -c 127.0.0.1 -p 5101 ...` (iperf 2.2.2, 29 September 2026). All fields are big-endian.

| Offset | Field | plain (`-t 2`) | `-R` | `-r` | `-d` |
|---|---|---|---|---|---|
| 0 | flags | `40010080` | `44010080` | `C0010080` | `C0010081` |
| 4 | numThreads (`-P`) | 1 | 1 | 1 | 1 |
| 8 | mPort | 5101 (the `-p` port; with `-L <n>` the port the client listens on) | 5101 | 5101 | 5101 |
| 12 | mBufLen (`-l`) | 0 | 0 | 0 | 0 |
| 16 | mWinBand | 0 | 0 | 0 | 0 |
| 20 | mAmount | `FFFFFF38` (-200, 2.00 s in 10 ms units); `-n 1M` gives `00100000` | same | same | same |
| 24..31 | reserved | 0 | 0 | 0 | 0 |
| 32 | upperflags (16 bit) | 0 | `0400` (REVERSE) | 0 | 0 |
| 36..43 | version words | `0002 0002 0002 0003` | same | same | same |
| 44..63 | reserved | 0 | 0 | 0 | 0 |

Flag bits: `80000000` header version 1 (set by `-r` and `-d`: "answer test"); `40000000` extended header;
`04000000` VERSION2 (set by `-R`); `00010000` header length present, the low byte `80` holding twice the
length (64 bytes); `00000001` RUN_NOW (`-d`: the connect-back starts at once). The header is 64 bytes in
every mode. After it, a plain test continues with the data pattern `0123456789...` in the same write; a `-R`
client sends the 64 bytes and nothing else, then waits for the data. `-P 2` opens two connections with
numThreads 2, each with its own header. Dumps (first 64 bytes, plain / `-R`):

```
40 01 00 80 00 00 00 01 00 00 13 ed 00 00 00 00  00 00 00 00 ff ff ff 38 00 00 00 00 00 00 00 00
00 00 00 00 00 02 00 02 00 02 00 03 00 00 00 00  00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
44 01 00 80 00 00 00 01 00 00 13 ed 00 00 00 00  00 00 00 00 ff ff ff 38 00 00 00 00 00 00 00 00
04 00 00 00 00 02 00 02 00 02 00 03 00 00 00 00  00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
```

The parser takes the header length from flags (24 bytes when the extended-length bits are absent), reads it
across segments, and decides: VERSION2 and upperflags REVERSE -> reverse; otherwise a receive test, with
the connect-back when the answer-test flag is set (`RUN_NOW` clear: tradeoff, set: dual).

**Modes** (`show iperf`, "TCP (firmware, lwIP)"):

| Client | Server behavior | Report |
|---|---|---|
| `iperf -c <ip> -t N` | receives to the client's FIN | pc->board, bytes = payload without the header |
| `-R` | sends the pattern on the same connection for mAmount (negative: 10 ms units; positive: bytes), then FIN | board->pc reverse (-R), bytes = acknowledged payload |
| `-r` | receives; after the client's FIN connects to the client's address and mPort, writes a 24-byte header (flags 0, numThreads 1, mPort, mAmount) and the pattern for mAmount, FIN | pc->board, then board->pc tradeoff (-r) |
| `-d` | connects back at once, while receiving | board->pc dual (-d), pc->board |

Transmit rules: data comes from one static 1600-byte pattern buffer (no copy, no allocation); a segment is
queued only when `tcp_sndbuf()` holds it, so a full buffer waits for the next acknowledgement (sent
callback) or the 1 s poll; each callback writes at most 16 segments; the test ends when the requested
time or bytes are queued and every byte is acknowledged. One test at a time per mode: receive, reverse and
connect-back each have one slot; a second connection of a busy mode is refused after its header and counted
in "refused". An idle test ends after 10 s. A `-P` greater than 1 therefore runs the first stream only.

**Windows Firewall.** `-r` and `-d` need the PC to accept the board's connection to the client's listen port
(5001 by default, or `-L`): the first run of `iperf.exe` raises the Windows prompt; a blocked connect-back
shows as "aborted" or no second report.

**Hardware results before the tuning** (image with the CPU-path classifier, firmware at the commit of this section, PC wired NIC
192.169.1.178 to the board at 192.169.1.199, `iperf.exe` 2.2.2, `-t 10`, two runs each; the PC line is the
client summary, the board line is `show iperf` after the run):

| Mode | PC side | Board side (`show iperf`) |
|---|---|---|
| plain (pc->board) | 68.5, 68.4 Mbit/s | pc->board 85983232 B in 10038 ms, 68526 kbit/s; 85852160 B in 10037 ms, 68428 kbit/s |
| `-R` | 29.3, 29.3 Mbit/s (`[ *1]`, 10.00 s, 34.9 MBytes) | board->pc reverse 36584680 B in 10000 ms, 29267 kbit/s (both runs) |
| `-r` | forward 68.6, 68.6 Mbit/s; connect-back 27.3, 27.1 Mbit/s | pc->board 85983232 B, 68553 kbit/s; board->pc tradeoff 34442860 B in 10092 ms, 27303 kbit/s (second run 34253060 B, 27144 kbit/s) |
| `-d` | forward 31.4, 31.5 Mbit/s; connect-back 15.6, 15.6 Mbit/s (sum 46.8) | pc->board 39452672 B, 31436 kbit/s; board->pc dual 19685180 B in 10099 ms, 15593 kbit/s (second run 19647220 B, 15565 kbit/s) |

The connect-back to the PC's port 5001 was not blocked by Windows Firewall; nothing was changed. `-R` is
reported as measured, 29.3 Mbit/s against 68.5 Mbit/s PC -> board. Both runs carry exactly the same byte
count (36584680): a CPU-bound rate, not a window limit (section 9.10 analyses and removes it; the table above
is the state before the tuning). A second test of the same
mode is refused (the "refused" counter); after the whole run `show iperf` reads tests 35, refused 0.

**Tests without the board.**
`build.ps1 -NoFirmware -LwipTest` builds the lwIP core from the install, `rtlnet_lwiperf.c` and a scripted
iperf client into one host process (lwIP's 127.0.0.1 interface) and sends the captured headers: plain with
64-byte and 24-byte headers (exact byte counts), `-R` timed, byte-limited and with the header in five
pieces, `-r` and `-d` connect-back (header fields, pattern, counts equal on both sides), busy refusal of a
second receive and a second reverse test, abort of a running test, restart of the server on the same port,
and the lwIP heap back at its start value; ends with `LWIPERF_LOOPBACK: PASS checks=69`. `test/iperf_board_emulator.py` implements the
same behavior in Python and the stock client runs against it: all four modes print the client summaries
(`-R` 891 Mbit/s, `-r` and `-d` both directions) on the PC loopback, which confirms the connect-back header
and the close the client accepts.

### 9.10 TCP throughput tuning (10-22-2026)

**Starting point** (section 9.9 table): PC -> board 68.5 Mbit/s, `-R` 29.3 Mbit/s with an identical byte
count in every run, `-d` 31.4 + 15.6 Mbit/s, against about 94 Mbit/s of TCP goodput on 100 Mb/s Ethernet.

**Finding.** The limit was the CPU, not the window. Raising `TCP_SND_BUF` from 4 to 8 and to 24 x MSS left `-R`
at 29.3 and 28.8 Mbit/s, although lwIP then had 8 and 24 segments queued. A timer profile of the netif
(`RTLNET_NETIF_PROFILE 1`, below) showed the CPU 100 % busy during every test and the cost of one 1514-byte
frame:

| Step | Before | After |
|---|---|---|
| TX: pbuf chain copied into the AXI BRAM TX buffer | 306.8 us (byte writes) | 73.7 us (word writes; 60 us is the cost of the 379 AXI writes alone) |
| RX: frame copied from the AXI BRAM into a pool pbuf | 70.7 us | 67.8 us (17 cycles per 32-bit read) |
| RX: lwIP input of one data frame (checksum, TCP, one ACK per two frames) | 101.3 us (`LWIP_CHKSUM_ALGORITHM` 2) | 68.3 us (algorithm 3) |

The CPU reaches the AXI BRAM over M_AXI_DP; one access takes about 16 cycles whatever its width. The pieces of a
TX pbuf chain start at odd offsets (a 54-byte header, then a payload at any alignment), and the library
`memcpy` wrote them byte by byte: 20 cycles per byte, 307 us per frame, 77 % of the time per `-R` segment. The
board therefore sent 2500 segments per second whatever the send buffer, always the same byte count.
`axi_put_chain` packs bytes into words in registers and writes aligned words only. The windows then mattered
(next table), and the 32-bit checksum took 33 us out of every received frame.

**Method.** Firmware built with `build.ps1` (`-Werror` clean, host `--demo` PASS, `-LwipTest` PASS), merged
and programmed into the reused classifier image (`boards/nexys_video/build`, XSA, `merge_elf.ps1`,
`program.ps1`); `iperf.exe -c 192.169.1.199 -t 10 -f k`, PC wired NIC 192.169.1.178, two runs per mode, one
setting changed per row; `clear counters` before each run and `show cpu-path` / `show tcp` after. Mbit/s as the
PC client reports them; `-d` is PC -> board + board -> PC and the iperf sum.

| # | Configuration (changes from the row above unless noted) | plain, PC -> board | `-R`, board -> PC | `-d` (sum) | Notes |
|---|---|---|---|---|---|
| 0 | `TCP_SND_BUF` 4 x MSS, `TCP_WND` 4 x MSS, `MEM_SIZE` 32 KiB, pool 32, `MEMP_NUM_TCP_SEG` 64, `MEMP_NUM_PBUF` 16, byte-copy netif, `LWIP_CHKSUM_ALGORITHM` 2 | 68.0, 68.3 | 29.3, 29.3 | 31.5 + 15.6 (47.1), 31.2 + 15.7 (46.9) | starting point; `-R` 36584680 B both runs |
| 1 | `TCP_SND_BUF` 8 x MSS, `MEMP_NUM_PBUF` 64, `MEMP_NUM_TCP_SEG` 128 | 68.4, 68.3 | 29.3, 29.3 | 15.2 + 22.3 (37.5), 15.2 + 22.4 (37.6) | send buffer does not matter |
| 2 | `TCP_SND_BUF` 24 x MSS, `MEMP_NUM_PBUF` 96, `MEMP_NUM_TCP_SEG` 256 | 66.0, 66.0 | 28.8, 28.8 | not measured | build with the profile timers (about 3 % of RX throughput); the queue reached 24 segments |
| 3 | netif TX copy by 32-bit writes; send buffer, window, memory as row 0; profile timers off | 71.8, 71.8 | 61.2, 59.6 | 45.5 + 22.5 (67.7), 45.3 + 22.6 (67.7) | `-R` doubles; PC -> board gains from the cheaper ACK frames |
| 4 | `TCP_SND_BUF` 8 x MSS (memory as row 1) | 71.5, 71.5 | 63.0, 63.0 | 26.2 + 38.8 (65.0), 26.2 + 38.8 (65.0) | |
| 5 | `TCP_SND_BUF` 16 x MSS, `MEMP_NUM_TCP_SEG` 192 | 71.5, 71.7 | 62.8, 62.8 | 14.3 + 48.8 (63.0), 13.7 + 50.5 (63.9) | |
| 6 | `TCP_SND_BUF` 8 x MSS, `TCP_WND` 8 x MSS, pool 64 | 77.2, 77.2 | 63.0, 63.0 | 39.8 + 29.5 (69.1), 39.8 + 29.5 (69.1) | the window helps PC -> board |
| 7 | `TCP_WND` 16 x MSS, pool 112 (LMB image 441 KiB) | 77.2, 77.3 | 63.0, 62.9 | 53.0 + 19.7 (72.3), 53.0 + 19.7 (72.3) | 2714 / 2666 CPU FIFO drops in `-d`; rejected |
| 8 | `TCP_SND_BUF` 24 x MSS, `TCP_WND` 8 x MSS, pool 64, `MEMP_NUM_PBUF` 96, `MEMP_NUM_TCP_SEG` 256 | 77.1, 77.2 | 62.6, 62.6 | 17.6 + 47.5 (65.0), 17.6 + 47.3 (64.8) | 1821 / 1828 FIFO drops in `-d`; CPU-bound |
| 9 | row 6 with `LWIP_CHKSUM_ALGORITHM` 3 | 85.5, 85.5 | 68.3, 68.2 | 43.6 + 32.3 (75.6), 43.6 + 32.3 (75.6) | the checksum is the largest software cost |
| 10 | row 9 with `MEM_SIZE` 64 KiB, unrolled TX and RX copies, `TCP_WND` 4 x MSS | 80.6, 80.6 | 56.0, 55.3 | 29.2 + 50.9 (80.1), 29.3 + 51.1 (80.4) | the PC acknowledges every eighth segment |
| 11 | `TCP_WND` 6 x MSS, pool 48 | 87.7, 87.5 | 55.5, 55.8 | 38.7 + 44.8 (83.4), 38.8 + 45.1 (83.8) | same ACK pattern as row 10 |
| 12 | `TCP_WND` 8 x MSS, `TCP_SND_BUF` 16 x MSS, `MEMP_NUM_TCP_SEG` 192, pool 64 | 87.5, 87.8 | 74.8, 74.5 | 29.6 + 53.8 (83.2), 29.6 + 54.0 (83.5) | |
| **13** | **`TCP_SND_BUF` 24 x MSS, `MEMP_NUM_TCP_SEG` 256, `MEMP_NUM_PBUF` 96 (chosen)** | **87.6, 87.8** | **82.7, 82.7** | **21.3 + 60.4 (81.7), 21.3 + 60.4 (81.7)** | segments max 24, pool max 1 of 64, FIFO drops 0 |
| 14 | `TCP_SND_BUF` 32 x MSS, `MEMP_NUM_TCP_SEG` 320 | 87.8, 87.8 | 82.7, 82.7 | 16.9 + 64.8 (81.6), 16.9 + 64.8 (81.6) | no gain over row 13: CPU-bound |
| - | row 9 (profile build, one run) with `ETH_PAD_SIZE` 2 (IP header word aligned), `PBUF_LINK_HLEN` 14 + 2 | 76.2 | 73.8 | 74.6 | against 83.7 / 74.3 / 78.6 for the same build without the pad: the lwIP input does not get cheaper (68.2 us), the RX copy gets dearer (81.6 us); reverted |

Rows 3 to 9 use the TX word copy without unrolling; rows 10 to 14 the unrolled copies. Rows 0 to 2 are the
state before the netif change; rows 3 and later keep it. Rows 1 and 2 are the measurements that disproved the
window hypothesis. The other rows are two consecutive runs; the pad row is one run.

*Not changed, and why.* Netif buffer counts (`RTLNET_NETIF_RX_BUFS` 4, `RTLNET_NETIF_TX_BUFS` 2): the counters show
no RX overrun (`rx_no_pbuf` 0, DMA errors 0, CPU FIFO drops 0 in single-flow runs) and no TX stall (the wait
for the previous MM2S transfer averages 1.3 to 3.1 us per frame, no `tx_timeouts`). Only one S2MM simple
transfer is armed at a time, so a deeper RX ring buffers nothing. `TCP_OVERSIZE`, `TCP_QUEUE_OOSEQ`,
`LWIP_TCP_SACK_OUT`: the reverse test writes from a static buffer (nothing to oversize), the single-flow runs show
no retransmission (`show tcp`: TCP drop 0, err 0), so there is nothing for them to improve.

**Why 24 x MSS and an 8 x MSS window.** Once the copy cost fell, the PC's acknowledgement rate decided `-R`: it
acknowledges between every second and every eighth segment (the board receives about 27000 to 29000 ACKs per
test in rows 6 and 9, 6000 in rows 10 and 11, 8000 in row 12, 11800 in row 13), apparently following the window
the board advertises and the pacing of the frames. With sparse ACKs the send buffer has to cover several
acknowledgement intervals: 8, 16, 24, 32 x MSS give 68, 75, 83, 83 Mbit/s (window 8 x MSS, 32-bit checksum).
24 is the smallest value at the CPU limit. An 8 x MSS window gives both directions (87.6 and 82.7 Mbit/s);
4 and 6 x MSS lose 27 Mbit/s of `-R` with an 8 x MSS send buffer; 16 x MSS gains nothing and overflows the
32 KiB wrapper FIFO. `TCP_SND_QUEUELEN` keeps lwIP's formula (4 x send buffer / MSS = 96): the iperf reverse
test queues two pbufs per segment (a ROM pbuf for the static pattern, a RAM pbuf for the headers), so
`MEMP_NUM_TCP_SEG` 256 covers the queue of one reverse connection (96) with the echo and a second iperf
connection, and `MEMP_NUM_PBUF` 96 covers the 24 ROM pbufs plus ARP and fragments. `MEM_SIZE` 64 KiB: the echo
server copies the data it echoes (`TCP_WRITE_FLAG_COPY`); four connections of 8 x MSS used 37 KB of the heap
(max 37272 B), which would not fit the old 32 KiB.

**Memory (final build).**

| Memory | Use |
|---|---|
| LMB, 512 KiB | text and read-only data 158.5 KiB, data 2.1 KiB, bss 232.7 KiB (lwIP heap 64 KiB, pool 97 KiB, MEMP 9 KiB, CLI and firmware 62 KiB), heap 2 KiB, stack 8 KiB: ends at 381 KiB, 131 KiB free |
| lwIP heap | 64 KiB; maximum used 37272 B (four echo connections), 3276 B in the iperf runs |
| pbuf pool | 64 x 1552 B = 97 KiB; maximum used 3 (echo) |
| AXI BRAM, 128 KiB | 12 KiB: 4 RX + 2 TX buffers of 2 KiB; 116 KiB free |

**Profile.** `RTLNET_NETIF_PROFILE` (`rtlnet_lwip_netif.h`, default 0) adds timers around the copies, the lwIP
input and the DMA wait; they cost about 3 % of the RX throughput, so the speed rows above use the build without
them. With it set to 1, `clear counters`, a test and `show cpu-path` print the wall and busy time, the poll
budget hits and the per-frame costs. Row 9 plus the unrolled copies, profile build, 1514-byte frames:

| Test | CPU busy | RX frame: copy / lwIP input | TX frame: copy / DMA wait / DMA start |
|---|---|---|---|
| plain (PC -> board, 83.7 Mbit/s with the timers) | 9.97 s of a 10 s test | 67.8 / 68.3 us | ACK frame: 5.3 / 3.1 / 3.7 us |
| `-R` (74.3 Mbit/s with the timers, 8 x MSS send buffer) | 9.97 s | ACK frame: 6.2 / 304.5 us (two data segments sent inside) | 73.7 / 3.1 / 3.7 us |

**What limits the rate now** (input for checksum offload and zero-copy):

- CPU saturation, not window, DMA or link. A received data frame costs 136 us (68 us of AXI reads, 68 us of
  lwIP) = 7.3k frames/s = 87 Mbit/s: the PC -> board rate. A sent segment costs about 140 us (74 us of AXI
  writes, about 65 us of lwIP and the share of the ACKs) = 83 Mbit/s: the `-R` rate. Line rate needs 123 us per frame.
- The AXI BRAM copies are half of each frame. The CPU gets one 32-bit access per 16 cycles over M_AXI_DP; there
  is no burst and no overlap, so the copy has no further software gain (60 us per frame is the write floor,
  about 60 to 65 us the read floor). Only not touching the payload helps: zero-copy RX (a pbuf that references
  the AXI buffer, with the RX checksum verified in hardware, would leave the CPU the 54 header bytes = 14 reads)
  and zero-copy TX (a header in the AXI BRAM plus a scatter-gather descriptor to a payload that already sits in
  the AXI BRAM; the present simple-mode DMA cannot gather).
- The software checksum is the largest part of the lwIP time: moving from 16-bit to 32-bit reads saved 33 us per
  received frame; the remainder is estimated at 25 to 30 us per 1460 bytes in each direction. Checksum offload
  removes that in both directions, but only pays fully together with zero-copy, because the CPU still reads or
  writes every payload byte while it copies.
- The rest of lwIP (TCP input and output, ACK generation, header handling) is about 35 to 40 us per frame;
  header alignment (`ETH_PAD_SIZE` 2) did not reduce it.
- DMA and FIFO: no stall. The MM2S wait is 1.3 to 3.1 us per frame; there are no CPU FIFO drops in the single-flow
  runs. Drops appear only when several connections together open more than the 32 KiB FIFO (rows 7 and 8; four
  echo connections plus iperf), which costs a TCP retransmission, never a failure of a test.
- `-d` shares one CPU between the two directions: the sum stays at 82 Mbit/s whatever the split, and the TX
  stream, which sends without waiting, takes most of the CPU and leaves the receive side 21 Mbit/s.
- Sensitivity to the PC: the PC's ACK rate (every second to every eighth segment) moves `-R` by more than 25 Mbit/s
  between rows 9 and 10 without any change in the board's CPU cost; a PC with another stack or NIC setting may
  need a different send buffer.

**Tests with the final configuration** (board 192.169.1.199, classifier image): `tcp_echo_client.py`, 4 connections,
PASS; `tcp_test.ps1` `TCP_TEST: PASS 8/8` (echo 7.2 Mbit/s, PC -> board 87.8, `-R` 82.7, `-r` 79.6, `-d` 60.7 Mbit/s
board -> PC; together: echo PASS, TCP 68.6 Mbit/s, UDP 20.9 Mbit/s 0/17820 lost); plain TCP iperf together with RTL
UDP iperf `-u -b 20M`, two runs: TCP 70.8 and 70.8 Mbit/s, UDP 20.9 Mbit/s 0/17833 and 0/17834 lost (51.6 Mbit/s TCP
before the tuning); `cli_test.ps1` `CLI_TEST: PASS 27/27`; `net_test.ps1 -Nic Ethernet -Speed 100`
`NET_TEST: PASS 25/25` (UDP 94.0 and 94.4 Mbit/s, 0 lost). Broadcast flood (`bcast_flood.py --rate 400 --seconds 10`,
ping once a second, `tcp_echo_client.py --conns 2` in a loop): storm limiter seen 3999, passed 1010, dropped 2989
(the limit of 10 per 100 ms holds), ping 14/14, 20 of 20 echo runs PASS (17 at 26.7 to 27.1 Mbit/s, three at 5.6 to
10.0 Mbit/s after a CPU FIFO drop), CPU FIFO drops 2. A harder flood (`--rate 2000 --seconds 12`) with a
four-connection echo test, a ping and an iperf stream at the same time: passed 1210 of 23752 (limit holds), ping
12/12, echo PASS, iperf 78.7 Mbit/s, CPU FIFO drops 374. `tcp_test.ps1` gates only on a throughput above zero for
each mode, so its thresholds need no change.

## 10. Build and test commands

```
powershell -NoProfile -ExecutionPolicy Bypass -File boards/nexys_video/scripts/build.ps1 [-Network] [-Program] [-Test]
powershell -NoProfile -ExecutionPolicy Bypass -File microblaze/firmware/build.ps1 [-Xsa <xsa>] [-Bsp] [-Demo]
powershell -NoProfile -ExecutionPolicy Bypass -File microblaze/firmware/build.ps1 -NoFirmware -LwipTest
python microblaze/firmware/test/iperf_header_capture.py --port 5101 --run "plain=-t 2" --run "R=-t 2 -R"
python microblaze/firmware/test/iperf_board_emulator.py --port 5001 --run "R=-t 3 -R" --run "r=-t 3 -r -L 5301"
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
| Desktop harness | TEST PASS 292 checks; negative control TEST FAIL |
| Desktop harness with the classifier register model (`host_platform.c`) | TEST PASS 292 checks: boot call and generic rewrite leave identical registers, every classifier command written through the driver, counters read back |
| Board bench `tb_rtlnet_nexys_video_top` with the simulation stand-in | TEST PASS 74 checks |

| Network build (commit a9e043e6) with the CPU path to the protocol wrapper | WNS +0.221 ns, WHS +0.018 ns; CDC fifo 9 / gray 6 as expected |
| Network board bench (simulation stand-in DMA tasks) | TEST PASS 85 checks at 10/100/1000 Mb/s: claimed frames stay out of the CPU queue, an unclaimed datagram reaches the CPU byte-exact, a CPU frame leaves on the PHY, wrapper CPU counters agree; a perturbed check fails |
| Hardware TCP echo | `tcp_echo_client.py` PASS, 4 concurrent connections, 1 B .. 64 KiB |
| Hardware TCP iperf (install lwiperf) | 68.4 Mbit/s PC -> board alone; 51.6 Mbit/s together with TCP echo (PASS) and RTL UDP iperf 20.9 Mbit/s (0 lost) |
| `rtlnet_lwiperf` desktop loopback test | `LWIPERF_LOOPBACK: PASS checks=69` (plain, -R, -r, -d, busy, abort, restart, heap) |
| Stock iperf 2.2.2 client against the Python board emulator | plain, -R, -r, -d complete with both directions in the summary |
| Hardware iperf with `rtlnet_lwiperf` (classifier image, wired NIC to the DHCP address 192.169.1.199, `-t 10`, two runs each) | PC -> board 68.5 / 68.4 Mbit/s; `-R` 29.3 / 29.3 Mbit/s; `-r` 68.6 then 27.3 / 27.1 Mbit/s; `-d` 31.4 / 31.5 Mbit/s with 15.6 / 15.6 Mbit/s; the board's `show iperf` agrees with the client (section 9.9) |
| Hardware iperf after the throughput tuning (section 9.10; send buffer 24 x MSS, window 8 x MSS, word-wise netif copies, 32-bit checksum) | PC -> board 87.6 / 87.8 Mbit/s; `-R` 82.7 / 82.7 Mbit/s; `-d` 21.3 + 60.4 Mbit/s (sum 81.7); TCP with RTL UDP iperf together 70.8 Mbit/s; `TCP_TEST: PASS 8/8`, `CLI_TEST: PASS 27/27`, `NET_TEST: PASS 25/25`, storm limiter holds under the flood |
| Hardware `tcp_test.ps1` / `tcp_echo_client.py` / `cli_test.ps1` (before the tuning) | `TCP_TEST: PASS 8/8`; `TCP_ECHO_TEST: PASS conns=4 messages=152`; `CLI_TEST: PASS 27/27`; lwIP heap used 124 B after 35 tests (no leak) |

Details: `boards/nexys_video/documentation/rtlnet_nexys_video.md` sections 6.3 and 6.4.

## 12. Limitations and open points

- The DMA interrupts are wired to the INTC but unused; the netif polls (no interrupt latency or nesting
  questions, and the main loop runs continuously).
- A MAC-table entry cannot carry a mask (the table's compare mode is single-value, shared with the storm
  entry), so the CLI has no `mask` option; the table-level CLASSIFY flag follows the entries of the table
  (a table with one `gate` entry gates, its `police` entries then also take part in the match).
- Reconfiguring the classifier from the CLI drops the CPU-bound frames for about 100 us.
- A soft restart (`reload`) jumps to the reset vector: the BSP start-up clears `.bss` but does not reload
  `.data`, so no firmware state relies on a `.data` initial value.
- The MDM's BSCAN clocks are constrained by the vendor IP itself; the build waives TIMING-9 only while
  `report_cdc` shows no Critical/Warning finding.

## 13. Revision history

| Revision | Change |
|---|---|
| 10-22-2026 | Initial version: block design script, wrapper, driver header, bus-functional model |
| 10-22-2026 | Moved to `microblaze/`; LMB 512 KiB; AXI DMA and 128 KiB AXI BRAM with the frame streams; simulation stand-in renamed `rtlnet_microblaze_sim_stub`; BSP generated from the XSA; firmware on the BSP with lwIP, InitLWIP, DMA netif, TCP echo, CPU path CLI |
| 10-22-2026 | lwIP glue and applications moved to `src/lwip/`; iperf server forked as `rtlnet_lwiperf` with -R, -r and -d; captured iperf 2.2.2 test header; desktop loopback test |
| 10-22-2026 | Classifier driver integrated: `rtlnet_cpupath.c` on the real driver API (context, `RTLNET_CLS_ACT_*`), boot call `rtlnet_classifier_config_bcast_storm(10, 100)`, MAC mask removed and EtherType entries 0..7 (range pairs) in the CLI, harness register model of the classifier; the sim stub classifier task follows the driver register map |
| 10-22-2026 | TCP throughput tuning: netif TX/RX copies as 32-bit AXI accesses, optional CPU profile (`RTLNET_NETIF_PROFILE`), `TCP_SND_BUF` 24 x MSS, `TCP_WND` 8 x MSS, 32-bit lwIP checksum, memory resized (section 9.10) |
