# rtlnet_mdio — PHY management by bit-banged Clause 22 MDIO

| Item | Value |
|---|---|
| Core | `rtlnet_mdio` |
| Document revision | 10-22-2026 |
| Register map revision | `VERSION` = `0x10222026` |
| Language | SystemVerilog-2012 (RTL, bench), C11 (drivers) |
| Clock | `clk` = `cpu_clk` (100 MHz on the Nexys Video) |
| Target PHY | Realtek RTL8211E-VL on the Digilent Nexys Video, RGMII, MDIO address 1 |
| Verification | Active-HDL 11.1 `tb_rtlnet_mdio` (AMD, GENERIC, 50 MHz); host unit test `rtlnet_mdio_host`; mb-gcc target build |

The RTL is a small GPIO register core: MDC, MDIO output data and output enable, the MDIO input through a 3-stage
synchronizer, the PHY reset output and the PHY interrupt input. The C driver is the IEEE 802.3 Clause 22 MDIO
master: it builds every management frame bit by bit through the core's registers. A second C layer knows the
RTL8211E: identity, the RGMII RX-delay setting, auto-negotiation, forced modes and the status decode that the
link monitor copies into the MAC.

## 1. Files

| File | Content |
|---|---|
| `hdl/rtlnet_mdio.sv` | the register core |
| `hdl/rtlnet_mdio.f` | compile order (nests `rtlnet_common.f`) |
| `driver/rtlnet_mdio.h`, `.c` | register map (the single definition) and the Clause 22 master |
| `driver/rtlnet_phy_rtl8211e.h`, `.c` | RTL8211E PHY layer on top of the master |
| `driver/test/test_rtlnet_mdio_host.c` | host unit test: register-block model and timed RTL8211E slave model |
| `driver/test/build_test.ps1`, `driver/test/Makefile` | host build and run, negative control, mb-gcc target build |
| `testbench/tb_rtlnet_mdio.sv`, `.f` | self-checking Active-HDL bench |
| `testbench/rtlnet_tb_mdio_slave.sv` | bench Clause 22 slave model (reusable by the board bench) |
| `testbench/regression.txt` | regression entries, including the `INJECT_FAILURE` negative control |

## 2. Interface (architecture section 15.2)

| Group | Ports | Contract |
|---|---|---|
| clock, reset | `clk`, `resetn` | `cpu_clk`; `resetn` synchronous, active low |
| registers | `s_axi_*` | AXI4-Lite slave, 12-bit byte address, 32-bit data, through `rtlnet_axil_slave` (single outstanding, all OKAY, partial writes ignored) |
| MDIO pins | out `mdc`, `mdio_o`, `mdio_t`; in `mdio_i` | the board top owns the IOBUF (`I` = `mdio_o`, `T` = `mdio_t`, `O` = `mdio_i`); `mdio_t` = 1 releases the line to the board pull-up; `mdc`, `mdio_o`, `mdio_t` are flip-flops, idle `mdc` 0, `mdio_t` 1; `mdio_i` asynchronous |
| PHY control | out `phy_rst_n`; in `phy_int_n` | `phy_rst_n` a flip-flop, low while `resetn` is low and `POR_RESET_MS` after, then `!CTRL.PHY_RESET`; `phy_int_n` (INTB, open drain) asynchronous |
| interrupt | out `irq` | level, flip-flop: PHY interrupt asserted and `CTRL.IRQ_EN` |

| Parameter | Default | Rule |
|---|---|---|
| `CLK_HZ` | 100_000_000 | `clk` frequency; `CLK_HZ / 1000` from 2 to 2^24 - 1 (elaboration `$fatal` otherwise) |
| `POR_RESET_MS` | 20 | PHY reset low time after `resetn` release, 1 to 255 ms (`$fatal` otherwise) |

No technology parameter; the only technology-dependent cells are the two `rtlnet_sync` chains (attributes from
`rtlnet_technology.svh`).

## 3. Register map

Offsets and bits are defined once in `driver/rtlnet_mdio.h`; `rtlnet_mdio.sv` mirrors them as localparams.
Undefined offsets (and misaligned addresses) read 0 and ignore writes.

| Offset | Name | Access | Reset | Content |
|---:|---|---|---|---|
| 0x000 | `ID` | RO | `0x4D44494F` | `"MDIO"` |
| 0x004 | `VERSION` | RO | `0x10222026` | register map date code |
| 0x008 | `CAPS` | RO | `0x140186A0` (defaults) | [23:0] `CLK_HZ / 1000` (kHz), [31:24] `POR_RESET_MS` |
| 0x00C | `CTRL` | RW | `0x0` | see below |
| 0x010 | `STATUS` | RO | `0x9` during POR | see below |
| 0x014 | `BITBANG` | W / R | — | write: bits [2:0] as `CTRL[2:0]`, `PHY_RESET` and `IRQ_EN` unchanged; read: [0] `MDIO_IN`, other bits 0 |

`CTRL`:

| Bit | Name | Meaning |
|---:|---|---|
| 0 | `MDC` | level of the `mdc` pin |
| 1 | `MDIO_OE` | 1 = drive MDIO (`mdio_t` = 0); 0 = release |
| 2 | `MDIO_OUT` | level driven while `MDIO_OE` = 1 |
| 8 | `PHY_RESET` | 1 holds `phy_rst_n` low (after POR as well) |
| 9 | `IRQ_EN` | gates the PHY interrupt onto `irq` |

One write updates `MDC`, `MDIO_OE` and `MDIO_OUT` together, so firmware changes the pins with one store per MDC
half period. `BITBANG` is the fast path: it writes the pin bits only, so the driver never read-modify-writes
`CTRL` inside a frame and cannot disturb `PHY_RESET` or `IRQ_EN`.

`STATUS`:

| Bit | Name | Meaning |
|---:|---|---|
| 0 | `MDIO_IN` | the MDIO pin, after the 3-stage synchronizer |
| 1 | `PHY_INT` | `phy_int_n` is low (synchronized) |
| 2 | `POR_DONE` | `POR_RESET_MS` have elapsed since `resetn` release |
| 3 | `PHY_RESET_ACTIVE` | `phy_rst_n` is low now (POR or `CTRL.PHY_RESET`) |

## 4. Design

- **POR timer.** A `CLK_HZ / 1000`-cycle prescaler counts milliseconds; after `POR_RESET_MS` of them `por_done`
  sets and stays set until the next reset. `phy_rst_n <= por_done && !CTRL.PHY_RESET`, so the pin is low for
  `CLK_HZ / 1000 * POR_RESET_MS + 1` clocks after `resetn` rises (2 000 001 clocks, 20 ms, with the defaults) and
  low on every clock of a reset after the first (synchronous reset). The firmware still waits the PHY's 30 ms settle
  time before the first MDIO access (`rtlnet_mdio_wait_por`).
- **Pins.** `CTRL`/`BITBANG` writes load the `mdc`, `mdio_o` and `mdio_t` flip-flops directly; the pins change one
  clock after the register strobe. Nothing in the core generates MDC timing: the bus speed is whatever the firmware
  writes.
- **Inputs.** `mdio_i` and `phy_int_n` each pass an `rtlnet_sync` (`STAGES` 3, reset value 1 = the idle level of both
  lines). `STATUS.MDIO_IN` follows the pin 3 clocks after an edge (30 ns at 100 MHz) plus the register read.
- **Interrupt.** `irq <= phy_int && IRQ_EN`: 4 clocks from a `phy_int_n` edge to `irq` (3 synchronizer + 1).
  The PHY releases INTB when firmware reads INSR (register 19).
- **Read mux.** Registered on `reg_rd_en`, answered the next clock, as `rtlnet_axil_slave` expects.

### 4.1 Clocks, resets, crossings

| Item | Detail |
|---|---|
| clock | `clk` only; `mdc` is a register output, never a clock inside the FPGA |
| reset | `resetn` synchronous, active low (board top `rtlnet_reset_sync` for `cpu_clk`) |
| crossings | `u_mdio_i_sync` (`mdio_i`), `u_phy_int_sync` (`phy_int_n`): `rtlnet_sync`, found by `scripts/rtlnet_constrain_cdc.tcl` by the `g_bit[*].sync_ff_reg[0]` name |
| pin timing | MDIO changes at most once per half period (hundreds of ns); the board XDC sets false paths on `eth_mdc` and `eth_mdio` (both directions) and on `eth_rst_b`, `eth_int_b`; no nanosecond-level I/O timing exists |

## 5. Clause 22 frame and timing (driver)

Frame (IEEE 802.3 clause 22.2.4.5; RTL8211E datasheet section 7.10.4, Tables 14 and 15), one MDC period per slot,
most significant bit first:

| Slots | Field | Read | Write |
|---|---|---|---|
| 0–31 | preamble, 32 ones | master | master |
| 32–33 | ST `01` | master | master |
| 34–35 | OP `10` read, `01` write | master | master |
| 36–40 | PHYAD | master | master |
| 41–45 | REGAD | master | master |
| 46–47 | TA | released; the PHY drives slot 47 to 0 | master `10` |
| 48–63 | DATA | PHY, master samples | master |
| 64 | idle | MDC low, line released, no edge | same |

The PHY accepts preamble suppression, but the driver always sends 32 ones (portable to any Clause 22 PHY).

Bit timing (one BITBANG store per half period):

| Item | Driver | Datasheet Table 61 |
|---|---|---|
| master-driven bit | store: MDC 0 + new level; wait half; store: MDC 1, level unchanged; wait half | setup t4 >= 10 ns, hold t5 >= 10 ns: the level is stable a whole half period on both sides of the rising edge |
| PHY-driven bit | store: MDC 0, released; wait half; read `BITBANG`; store: MDC 1; wait half | t6 0..300 ns after the rising edge: the sample is about one period after the PHY's launching edge, just before the next rising edge |
| half period | target `RTLNET_MDIO_HALF_TARGET_NS` 250 ns (2 MHz MDC), floor 200 ns | t1, t2 >= 160 ns; t3 >= 400 ns |
| no PHY | TA slot 47 reads 1 (pull-up): `RTLNET_MDIO_ERR_NO_PHY`, value 0xFFFF; the frame is still clocked to the end | |
| frame time | 65 periods, about 33 us at 2 MHz plus the store time | |

The half period is a spin of `half_loops` iterations of a volatile counter, or the platform's `half_delay` hook.
`rtlnet_mdio_init` sets a safe default from `CAPS` (`CLK_HZ / 1000 * 250 ns / 10^6 + 1` loops: at least one clock
per iteration, so at least 250 ns when the CPU runs at the core clock). `rtlnet_mdio_calibrate` replaces it from
the platform timer: it times 64 idle stores (MDC stays low, so the PHY sees no clock) with 0 and with 64 spin
loops, fits store overhead and cost per loop, and picks the smallest loop count that gives 250 ns. The measured
half period includes the AXI store time, so the result is the real pin timing.

## 6. Driver API

### 6.1 `rtlnet_mdio.h` — bus layer

All functions return `RTLNET_MDIO_OK` (0) or a negative named code: `RTLNET_MDIO_ERR_ARG` (-1),
`_CORE_ID` (-2, ID/VERSION mismatch), `_NO_PHY` (-3, TA bit not driven low), `_TIMEOUT` (-4, POR_DONE never set),
`_CALIBRATE` (-5, timer not advancing or loop cost not measurable), `_NO_DELAY` (-6, no `delay_us` hook).

| Function | Purpose |
|---|---|
| `rtlnet_mdio_init(ctx, base, phy_addr, delay_us, user)` | bind a context to a core (base address from the platform layer), check ID/VERSION, default half period, bus idle |
| `rtlnet_mdio_calibrate(ctx, now_ticks, ticks_per_us, &half_ns)` | size `half_loops` from the platform timer (AXI Timer at 100 MHz: `ticks_per_us` 100) |
| `rtlnet_mdio_set_half_loops`, `rtlnet_mdio_set_half_delay` | fixed spin count, or a platform hook that waits one half period |
| `rtlnet_mdio_read(ctx, reg, &val)`, `rtlnet_mdio_write(ctx, reg, val)` | Clause 22 frame to the context's PHY |
| `rtlnet_mdio_read_addr`, `rtlnet_mdio_write_addr` | the same to any PHYAD (bus scan, CLI `PHY READ`) |
| `rtlnet_mdio_wait_por(ctx)` | wait `STATUS.POR_DONE` (bounded, 300 x 1 ms), then the 50 ms settle |
| `rtlnet_mdio_phy_reset(ctx)` | `CTRL.PHY_RESET` 20 ms low, then 50 ms settle (datasheet: >= 10 ms, >= 30 ms) |
| `rtlnet_mdio_irq_enable(ctx, on)`, `rtlnet_mdio_phy_int_asserted(ctx)`, `rtlnet_mdio_status(ctx)` | interrupt gate and raw status |
| `rtlnet_mdio_caps_clk_khz`, `rtlnet_mdio_caps_por_ms` | build parameters from `CAPS` |

The context (`rtlnet_mdio_t`) holds the base address, PHY address, `half_loops`, the optional `half_delay` hook,
the required `delay_us` hook and an opaque `user` pointer passed to every hook. The driver keeps no other state;
one context per MDIO bus, used from one firmware context (no locking).

### 6.2 `rtlnet_phy_rtl8211e.h` — PHY layer

Bus errors pass through unchanged; the layer adds `RTLNET_PHY_ERR_ID` (-16), `_VERIFY` (-17), `_TIMEOUT` (-18),
`_ARG` (-19).

| Function | Purpose |
|---|---|
| `rtlnet_phy_rtl8211e_probe(mdio, &id)` | PHYID1/PHYID2 = 0x001C/0xC915, else `ERR_ID` (no PHY: `RTLNET_MDIO_ERR_NO_PHY`) |
| `rtlnet_phy_rtl8211e_enable_rx_delay(mdio, &before, &after)` | page 0xA4 register 28 RX delay with readback (section 7) |
| `rtlnet_phy_rtl8211e_init(mdio)` | probe, then RX delay: the bring-up pair, run after every PHY hardware reset |
| `rtlnet_phy_rtl8211e_soft_reset(mdio)` | BMCR bit 15, poll for self-clear every 1 ms, at most 500 polls |
| `rtlnet_phy_rtl8211e_autoneg_restart(mdio)` | BMCR ANE + Restart_AN (applies the advertisement) |
| `rtlnet_phy_rtl8211e_advertise_set(mdio, mask)`, `_get(mdio, &mask)` | `RTLNET_PHY_ADV_10H/10F/100H/100F` in ANAR bits 8:5, `_1000H/1000F` in GBCR bits 8/9; other ANAR/GBCR bits kept |
| `rtlnet_phy_rtl8211e_force(mdio, speed, full)` | ANE off, BMCR speed bits 13/6 and duplex bit 8; 10 or 100 only |
| `rtlnet_phy_rtl8211e_status(mdio, &st)` | decode into `rtlnet_phy_status_t` |
| `rtlnet_phy_rtl8211e_loopback(mdio, on)` | BMCR bit 14 (PCS loopback) |
| `rtlnet_phy_rtl8211e_dump(mdio, regs[32])` | registers 0..31 of the current page into an array (no printing); read-clear registers are cleared by it |
| `rtlnet_phy_rtl8211e_irq_config(mdio, iner)`, `_irq_ack(mdio, &insr)` | INER select; INSR read (releases INTB) |
| `rtlnet_phy_speed_mbps(code)` | 10 / 100 / 1000, 0 for the reserved code |

`rtlnet_phy_status_t`: `link_up` (PHYSR 17.10, real time), `resolved` (17.11), `speed` (17.15:14,
`RTLNET_PHY_SPEED_10/100/1000/UNKNOWN` = 0/1/2/3), `full_duplex` (17.13), `speed_valid` (link, resolved and a
non-reserved code), `an_enabled` (BMCR 0.12), `an_complete` (BMSR 1.5), `mdi_crossover` (17.6), `partner_adv`
(ANLPAR and GBSR mapped to `RTLNET_PHY_ADV_*`, 0 until AN completes because both registers are not valid before,
Tables 28 and 33) and the raw BMCR, BMSR, PHYSR, ANLPAR and GBSR words.

## 7. RTL8211E bring-up sequence, and why

| Step | Action | Why |
|---|---|---|
| 1 | `rtlnet_mdio_wait_por` (power-on) or `rtlnet_mdio_phy_reset` (CLI `PHY RESET`) | PHYRSTB must be low >= 10 ms, then 30 ms before the first register access (datasheet section 7.16, Figure 10). The core's POR gives 20 ms; the driver adds 50 ms settle |
| 2 | `rtlnet_mdio_calibrate` | MDC timing independent of the CPU and interconnect speed |
| 3 | probe: PHYID1 0x001C, PHYID2 0xC915 | confirms the PHY and its address (strap 00001) and that MDIO works at all; an exact match also fixes the silicon revision whose register 28 layout is assumed |
| 4 | PAGSEL (reg 31) = 0x0007, EPAGSR (reg 30) = 0x00A4 | extension page access, datasheet section 7.10.5 and Tables 43/44 |
| 5 | read reg 28; write `(r28 \| bit13 \| bit11) & ~bit12`; read back | bit 13 puts the RGMII delays under register control, bit 11 is the RX delay, bit 12 the TX delay (not in the public datasheet; the Linux `rtl8211e_config_init` definitions, verify on hardware). Read-modify-write because bits 10:0 are vendor settings. The Nexys Video straps the PHY with no delay; the MAC's RX capture needs the PHY's 2 ns RXC delay, and the FPGA forwards TXC at 90 degrees, so TX delay stays off. Board value before the write: 0x8575, after: 0xAD75 |
| 6 | PAGSEL = 0 (on every path, also after a failed step) | all later accesses (status poll, CLI) assume page 0 |
| 7 | pass when the readback has bits 13 and 11 set and 12 clear | the readback proves the bits stick, not that the delay works; the working RX path is the real evidence |
| 8 | optional: advertisement, AN restart | the board straps advertise all modes; the CLI can restrict them (`PHY ADVERTISE`, `PHY AUTONEG`, `PHY SPEED`) |

A PHY hardware reset clears every register, including register 28: run `rtlnet_phy_rtl8211e_init` again after
`rtlnet_mdio_phy_reset`. A BMCR soft reset returns BMCR and BMSR to defaults (Table 23); whether it clears register 28
is not documented, so firmware runs `enable_rx_delay` again after a soft reset as well (it is idempotent).

## 8. Keeping the MAC speed in step with PHYSR

The MAC's speed is a register written by firmware (architecture section 7.2), never taken from RGMII in-band
status. PHYSR is the source: documented (Table 38), readable regardless of the RGMII state, and it carries a
"resolved" flag. BMSR link status is latch-low (a past link drop reads 0 once), so it is not used for the link.
The RTLNET speed codes equal PHYSR 17.15:14 and the MAC speed encoding, so the value is copied unchanged.

Link-monitor task (firmware `netmgr.c`), every poll period or on the PHY interrupt:

```c
rtlnet_phy_status_t st;
if (rtlnet_phy_rtl8211e_status(&g_mdio, &st) != RTLNET_PHY_OK) {
    /* bus fault or no PHY: report link down, do not touch the MAC speed */
} else if (st.speed_valid) {
    if (!g_link_up || st.speed != g_mac_speed) {
        mac_set_speed(st.speed);          /* rtlnet_eth_mac driver: 0 10M, 1 100M, 2 1000M */
        mac_set_link(1);
        g_mac_speed = st.speed;
    }
    g_link_up = 1;
} else if (g_link_up) {
    mac_set_link(0);                      /* keep the last speed; the MAC qualifies RXC itself */
    g_link_up = 0;
}
```

Rules: change the MAC speed only on `speed_valid` (link, resolved, non-reserved code); hold the last speed while
the link is down; with no PHY every read fails with `RTLNET_MDIO_ERR_NO_PHY`, so an all-ones bus never reads as
"link up at 1000". With the interrupt in use: `irq_config(LINK_CHANGE | AN_COMPLETE)`, `rtlnet_mdio_irq_enable`, and
in the handler `irq_ack` then the status poll above.

## 9. Verification

### 9.1 Active-HDL bench `tb_rtlnet_mdio`

| Case | Proves |
|---|---|
| 1 reset state | `mdc` 0, line released, `phy_rst_n` 0, `irq` 0 |
| 2 header | ID, VERSION, CAPS (POR ms and kHz) |
| 3 POR | `phy_rst_n` low `CLK_HZ/1000*POR_RESET_MS` to +2 clocks after `resetn`; never high during reset; STATUS before/after |
| 4 CTRL | all 8 MDC/OE/OUT combinations at the pins and in readback; `PHY_RESET` drives the pin and STATUS; `BITBANG` keeps `PHY_RESET`/`IRQ_EN` and ignores bits above 2; partial write, writes to ID/VERSION/CAPS/STATUS/undefined offsets ignored; undefined and misaligned offsets read 0 |
| 5 MDIO input | 20 asynchronous edges: exactly 3 clocks to the synchronizer output; STATUS bit 0 and BITBANG bit 0 follow |
| 6 interrupt | PHY_INT synchronizer 3 clocks; `irq` stays low with IRQ_EN 0; `irq` 4 clocks after `phy_int_n` edges; IRQ_EN gates it |
| 7 Clause 22 | frames hand-driven through `BITBANG` against `rtlnet_tb_mdio_slave` (PHY output 100 ns after the rising edge): PHYID1, PHYID2, write + read back of ANAR and reg 31, absent PHY 5 (TA bit high, 0xFFFF), slave frame counters; no contention; MDIO never changes while MDC is high or on the rising edge |
| 8 warm reset | CTRL cleared, POR runs again with the same length |

Recorded 10-22-2026 (`scripts/rtlnet_regression.ps1 -Match rtlnet_mdio`):

| Run | Result |
|---|---|
| default (AMD, 100 MHz, POR 1 ms) | PASS, 1386 checks |
| `generic` (`RTLNET_TECH_GENERIC`) | PASS, 1386 checks |
| `altclk` (`TB_ALT_CLOCK`: 50 MHz, POR 2 ms) | PASS, 1386 checks |
| `neg` (`+INJECT_FAILURE`) | TEST FAIL as required (1387 checks, 1 fail) |

Perturbations (run once, restored): synchronizer `STAGES` 2 gave 27 failures (latency checks); slave output delay
700 ns (later than the sample point) gave wrong frame data in every read.

### 9.2 Host unit test `rtlnet_mdio_host`

`driver/test/test_rtlnet_mdio_host.c` runs both drivers unmodified (`RTLNET_HOST_TEST` routes register access to the
model and the spin loop to the model's clock) in virtual time: 60 ns per register access, 8 ns per spin loop, a
100 MHz timer. The register-block model mirrors the RTL; the RTL8211E slave is clocked by the MDC edges the driver
writes and drives TA/data 300 ns (worst-case t6) after the rising edge. Every frame is checked against: MDC period
>= 400 ns, high and low >= 160 ns, no MDIO change while MDC is high or on the rising edge, no read sample before t6,
no line contention, exactly 32 preamble ones, an idle slot after every frame, no access while the PHY is in reset
or in its 30 ms settle window, reset low >= 10 ms.

| Group | Checks |
|---|---|
| core | argument errors, wrong core ID, default half period from CAPS, CAPS fields, POR wait length and its timeout bound |
| calibration | two-point result (24 loops, about 255 ns half), no MDC edge during calibration, stopped timer rejected, failed calibration keeps the old value |
| frames | ID reads, write/read back, frame length, preamble count, frame counters, argument errors, another address (no PHY, 0xFFFF), half-delay hook path |
| model controls | half period 0 is flagged (period, high, low, early sample); 5 ms reset pulse and an access in the settle window are flagged |
| faults | no PHY (read, probe, status, init all report `ERR_NO_PHY`); wrong ID (`ERR_ID`, register 28 untouched); register 28 not sticking (`ERR_VERIFY`, page 0 restored); BMCR reset stuck (`ERR_TIMEOUT` after exactly 500 polls) |
| RX delay | 0x8575 to 0xAD75, bit 12 cleared and bits 10:0 kept from 0x1234 (0x2A34), PAGSEL back to 0 |
| hardware reset | 20 ms low, 50 ms settle, register 28 back to default, init again |
| auto-negotiation | default advertisement, 10/100 router (100 full), 10-only advertisement, gigabit partner (1000 full, GBSR partner bit), no common mode (no link), ANAR pause/selector bits kept |
| forced, loopback, dump | forced 100 full and 10 half, 1000 rejected, back to AN, loopback bit, dump contents, dump without PHY |
| link and interrupt | unplug: link down, INTB asserted, INSR link-change bit, INTB released after the read; plug back: 1000 full; IRQ_EN set and cleared |

Recorded 10-22-2026: `build_test.ps1` and `mingw32-make run neg target` (host gcc 16.2.0, `-std=c11 -Wall -Wextra
-Werror -pedantic`): **PASS, 210 checks**; `--inject-failure` reports TEST FAIL. Nine driver mutations, each built
against the unchanged test, all fail: idle slot removed, sample after the rising edge, 31-bit preamble, data
changed on the rising edge, wrong RX-delay bit, PAGSEL not restored, 5 ms reset, TA bit ignored, 10 ms settle.

### 9.3 Target build

`mb-gcc -mlittle-endian -mcpu=v11.0 -std=c11 -Wall -Wextra -Werror -O2 -c` on `rtlnet_mdio.c` and
`rtlnet_phy_rtl8211e.c` (Vivado 2025.2 MicroBlaze gcc): both compile with no diagnostics (`make target`,
`build_test.ps1`).

## 10. Synthesis

Out of context, Vivado 2025.2, xc7a200tsbg484-1, defaults (`scripts/rtlnet_vivado.ps1` +
`scripts/rtlnet_synth_check.tcl`), 10-22-2026:

| Item | Result |
|---|---|
| verdict | `rtlnet_synth_check: PASS rtlnet_mdio`, 0 critical warnings |
| Slice LUTs | 57 (0.04 %) |
| Slice registers | 97 (0.04 %), all flip-flops |
| Block RAM, DSP, F7 muxes | 0 |
| warnings | `Synth 8-3917` (`s_axi_bresp`/`s_axi_rresp` constant 0: all responses OKAY by design), `Synth 8-6014` (`s_axi_wready_reg` in `rtlnet_axil_slave` merged with its equivalent `awready` flop) |

## 11. Limitations and open items

- GBCR bit 8 (1000BASE-T half duplex in IEEE 802.3 clause 40) is listed as reserved in the RTL8211E datasheet
  (Table 32); `RTLNET_PHY_ADV_1000H` is written but the PHY may ignore it.
- Forced mode: datasheet Table 23 note 2 says a speed/duplex/ANE write takes effect only with a software reset,
  Restart_AN or a power-down exit. The driver writes BMCR as IEEE 802.3 specifies; confirm on hardware, and add a
  soft reset to `force` if the PHY ignores the plain write.
- Register 28 bit meanings come from the Linux driver, not the datasheet; the readback proves only that the bits
  stick.
- The MDC timing and calibration are proven against the host model and by arithmetic, not yet on the MicroBlaze;
  measure MDC on the board (ILA or scope) at bring-up.
- The C driver has not run against the RTL in simulation; the board bench (BFM plus PHY model) is the place for that.
  The Active-HDL bench proves the same frame sequence hand-driven through the registers.
- 1000 Mb/s is modelled and decoded but not hardware-tested (architecture section 1, 10/100 router).

## 12. Revision history

| Revision | Change |
|---|---|
| 10-22-2026 | Initial version: GPIO register core, Clause 22 master, RTL8211E layer, bench, host test |
