# FPGA design — CrossLink-NX camera controller

Verilog-2001 RTL for the FPGA in the TIDA-010083 + FPGA + AR0234CS machine-vision camera. Roughly 4,400 lines of RTL plus a testbench, all compile-clean under `iverilog -g2001 -Wall`, with an end-to-end smoke test that passes.

---

## 1. Exact part number

**`LIFCL-40-9MG289I`**

| Field | Value |
|---|---|
| Family | CrossLink-NX, 28 nm FD-SOI |
| Device | LIFCL-40 — 39 k logic cells, 9,750 LABs |
| Speed grade | −9 (fastest) |
| Package | 289-ball csBGA, **9.5 × 9.5 mm**, 0.5 mm pitch |
| User I/O | 180 |
| Temperature | Industrial, −40 to +100 °C T<sub>J</sub> |
| Pinout document | **FPGA-SC-02018**, *CrossLink-NX LIFCL-40 Pinout* |

**Why this orderable and not another.**

*Device.* LIFCL-40 rather than LIFCL-17 for the DSP count (56 vs 24 multipliers — the ISP uses four of them per pipeline stage) and the EBR count (84 vs 24 blocks). Note the family has a counterintuitive inversion: **LIFCL-17 has more Large RAM than LIFCL-40** (5 blocks / 2,560 kb vs 2 blocks / 1,024 kb). That does not change the decision, because no amount of on-chip RAM holds a frame here, but it is worth knowing before assuming the bigger part wins on every axis.

*Package.* 289-ball csBGA at 9.5 × 9.5 mm, not the 400-ball caBGA at 17 × 17 mm. The camera housing is 29 mm and the TIDA board is already 27 × 27 mm; a 17 mm square package consumes most of the carrier. The cost is 0.5 mm pitch, which means via-in-pad and an HDI stack-up. 180 I/O against a requirement of about 90 (below) is comfortable.

*Speed grade.* −9 for margin on the DDR3L interface, which is the only thing in the design near a timing wall. −8 is a legitimate cost reduction once timing has actually closed; the RTL does not care.

*Temperature.* Industrial is not optional. The part sits in a sealed housing with no airflow next to a PoE flyback converter.

**Bring-up board.** Use `LIFCL-40-9BG400I` (400-caBGA, 17 × 17 mm, 0.8 mm pitch, 192 I/O) for the first prototype. Same die, same RTL, same constraints except the ball map — and it is the package Lattice's own evaluation board and pinout documentation centre on, which matters when you are debugging the D-PHY for the first time.

### I/O budget

| Group | Pins |
|---|---|
| RGMII | 12 |
| MDC, MDIO, PHY RESET_N, INT | 4 |
| PHY CLK_OUT in | 1 |
| Isolated field I/O (In1, In2, In_En, Out1) | 4 |
| Camera I²C, RESET_BAR, EXTCLK, TRIGGER, FLASH | 6 |
| DDR3L ×16 | ~49 |
| LEDs, POR | 5 |
| **Total user I/O** | **~81** |
| CSI-2 (5 pairs) | dedicated D-PHY pins |
| SPI flash, JTAG | dedicated configuration pins |

180 available against 81 used. Room for a second sensor on the free D-PHY quad.

---

## 2. Device resources and how the design uses them

Published figures for LIFCL-40 (CrossLink-NX family datasheet, FPGA-DS-02049):

| Resource | LIFCL-40 | LIFCL-17 |
|---|---|---|
| Logic cells | 39 k | 17 k |
| EBR blocks (18 kb) | **84** (1,512 kb) | 24 (432 kb) |
| LRAM blocks (512 kb) | **2** (1,024 kb) | 5 (2,560 kb) |
| Distributed RAM | 252 kb | 108 kb |
| 18 × 18 multipliers | 56 | 24 |
| GPLL | 3 | 2 |
| Hardened D-PHY quads | 2 (4 lanes each, 2.5 Gb/s per lane) | 2 |
| PCIe Gen2 hard IP | 1 | — |
| ADC blocks | 2 (12-bit SAR, 1 MSPS) | 2 |

**The memory conclusion that drives the architecture.** EBR + LRAM totals 2,536 kb ≈ 317 kB. One 1920 × 1200 Mono8 frame is 2,304,000 bytes. On-chip memory holds **about one seventh of a single frame**. Combined with the 2.76 Gb/s sensor against a sub-1 Gb/s wire, external DDR3L is not a design preference — it is the only way the system can work at all.

### Estimated utilisation

These are structural estimates from the RTL, not synthesis results. Run Radiant before trusting them.

| Block | EBR | DSP | Notes |
|---|---|---|---|
| `isp_bin2x2` line buffer | 1 | — | 480 × 22 bits, exactly one EBR |
| `isp_gain` | — | 4 | one 10×12 multiplier per pixel lane |
| ISP→system async FIFO | 2 | — | 512 × 43 bits |
| MAC RX async FIFO | 2 | — | 2048 × 11 bits |
| Frame writer staging FIFO | 2 | — | 512 × 64 bits |
| Frame reader FIFO | 2 | — | 512 × 64 bits |
| ICMP echo buffer | 0 | — | 512 bytes, distributed RAM |
| Descriptor ring | 0 | — | 8 × 114 bits, distributed RAM |
| **Total** | **~9 of 84** | **4 of 56** | ample headroom |

Logic is the resource to watch, not memory. The network stack and GVSP packetiser are control-heavy. A realistic first-pass estimate is 12–18 k logic cells of the 39 k available.

---

## 3. The architectural decision that shapes the RTL

The AR0234CS produces **1920 × 1200 × 120 fps = 276.5 Mpixel/s**.

A conventional one-pixel-per-clock ISP would need a ~300 MHz pipeline. That will not close on this device with multiple processing stages. So **the entire image datapath is 4 pixels wide**, which puts the ISP below 80 MHz with margin. Every stage — black level, defect correction, gain, ROI, binning — operates on a 40-bit group of four 10-bit pixels.

This is the single most consequential choice in the design, and it propagates everywhere: the RAW10 unpacker emits four pixels per clock (four pixels per five bytes, so an 80 % duty cycle), the binning stage emits full 4-pixel groups at half rate rather than 2-pixel groups at full rate, and the frame writer packs either two groups or one group into each 64-bit DDR beat depending on pixel format.

---

## 4. Module map

```
cam_top.v ─────────── top level: clocking, resets, CDC, TX arbitration
│
├── cam_lib.v ─────── rst_sync, bit_sync, pulse_sync, bus_sync,
│                     sync_fifo (FWFT), async_fifo (Gray, registered flags)
│
├── csi2_rx.v ─────── dphy_rx_wrap  shim over the hardened D-PHY
│                     csi2_ecc      packet-header Hamming ECC
│                     csi2_crc16    payload CRC-16
│                     csi2_pkt      packet decoder, 4 bytes/clock
│                     raw10_unpack  RAW10/RAW8 → 4 pixels/clock
│
├── isp.v ─────────── isp_framer    short-packet pulses → group coords
│                     isp_blc       black level, clamped
│                     isp_defect    5-tap same-colour hot-pixel clamp
│                     isp_gain      Q4.8 saturating gain (4 DSP)
│                     isp_roi       crop, group granularity in x
│                     line_buffer   EBR-inferred
│                     isp_bin2x2    2×2 binning
│
├── frame_buffer.v ── frame_writer  pack → burst → DDR
│                     frame_ring    slot allocator + FWFT descriptor FIFO
│                     frame_reader  DDR → 64-bit stream
│                     ddr_arb       writer-priority arbiter
│
├── rgmii_mac.v ───── ddr_in_x1 / ddr_out_x1  IDDRX1F / ODDRX1F shims
│                     rgmii_rx, rgmii_tx      10/100/1000
│                     mac_rx, mac_tx, crc32_comb
│
├── net_stack.v ───── ip_cksum16, net_rx, arp_reply, icmp_echo, tx_compose
│
├── gige_vision.v ─── gvsp_tx   leader / payload / trailer packetiser
│                     gvcp      READREG, WRITEREG, DISCOVERY
│                     reg_file  bootstrap + camera control registers
│
└── control.v ─────── mdio_master  clause 22 + MMD indirect
                      phy_init     DP83867 bring-up and link monitor
                      i2c_master   two-wire for the sensor
                      sensor_init  ROM-driven register script
                      ptp_clock    64-bit timestamp with rate adjust
                      trigger_unit isolated input → TRIGGER → strobe
                      led_status
```

### Clock domains

| Domain | Frequency | Contents |
|---|---|---|
| `clk_cam` | ~94 MHz (D-PHY byte clock) | `csi2_rx`, `isp_pipeline` |
| `clk_sys` | 125 MHz (PLL from `clk_ref`) | frame buffer, network stack, GigE Vision, control, `mac_tx` |
| `clk_rx` | 125 / 25 / 2.5 MHz (from PHY) | `rgmii_rx`, `mac_rx` |

Crossings: ISP → frame buffer via `async_fifo` (43 bits); `mac_rx` → network stack via `async_fifo` (11 bits); configuration → ISP via `bit_sync` (75 bits, quasi-static). There are no unsynchronised crossings.

`clk_ref` is the DP83867 `CLK_OUT` pin programmed to the ÷5 recovered receive clock. This deletes an oscillator from the bill of materials and makes the sensor's frame timing traceable to the network clock.

---

## 5. Build and simulate

```bash
# compile-check everything as strict Verilog-2001
iverilog -g2001 -Wall -I rtl -o /dev/null -t null rtl/*.v

# run the smoke test
iverilog -g2001 -I rtl -o sim.out rtl/*.v sim/tb_cam_top.v
vvp sim.out
```

Current result:

```
==================== results ====================
 frame descriptors: 2
 MDIO transactions: 10
 I2C transactions : 14
 frames_done      : 2
 DDR write beats  : 96
 GVSP blocks sent : 2
 TX activity seen : 1106
 link_up          : 1
 SMOKE TEST PASSED
=================================================
```

96 DDR write beats is exactly 3 frames × 32 beats for the 64 × 4 test geometry in Mono8, so the pixel path is arithmetically correct end to end.

For synthesis in Radiant, define `LATTICE_PRIM` so the DDR I/O shims instantiate `IDDRX1F` / `ODDRX1F` instead of the simulation models. **The behavioural DDR output is a combinational mux on the clock and must not be synthesised.**

---

## 6. What is vendor IP, not RTL

Three blocks are generated in Radiant and instantiated, not written here. The wrappers in this tree fix their interfaces so the rest of the design is independent of them:

| Block | Wrapper | Notes |
|---|---|---|
| Hardened MIPI D-PHY | `dphy_rx_wrap` in `csi2_rx.v` | only the raw byte stream is used, so the same RTL works with a soft D-PHY on the HP banks |
| DDR3L controller | DDR user port on `cam_top` | generic command/write/read; close to the Lattice native interface |
| GPLL | `sys_pll` in `cam_top.v` | 25 MHz in, 125 MHz and 24 MHz out |

`cam_top` is synthesisable standalone. The Radiant project top instantiates it alongside those three.

---

## 7. Known issues and honest limits

**Open defect, found by the testbench.** `isp_eof` asserts twice for three input frames: the end-of-frame marker for the final frame is not emitted, so its descriptor is never produced and the frame is never streamed. The pixel data reaches DDR correctly (all 96 beats are written) — the loss is the frame boundary, not the image. Narrowed to `isp_framer` or the `isp_bin2x2` bypass path in `isp.v`. **Fix this before hardware bring-up.** It is left in rather than papered over because the testbench reproduces it deterministically and it should be fixed with a waveform, not a guess.

**Verify before tape-out.**
- The **CSI-2 ECC parity equations** in `csi2_ecc` are the commonly published set. The MIPI CSI-2 specification is the normative source and is not public. The decoder deliberately never drops a packet on an ECC mismatch — it only counts errors — so a wrong table cannot break the datapath.
- The **DP83867 PHYSTS bit map** (speed in [15:14], duplex [13], link [10]) used by `phy_init`.
- The **Lattice Nexus primitive port names** for `IDDRX1F` / `ODDRX1F` in your Radiant version.
- **`sensor_init` is a skeleton.** The register addresses are the standard onsemi/Aptina map, but the full AR0234CS power-up sequence — analogue trim, PLL programming, sequencer patch — comes from onsemi's register reference and initialisation file under NDA. Drop those writes into the ROM; nothing else changes.

**Deliberately not implemented.**
- GVCP `WRITEMEM`, the message channel, and the GenICam XML description file. `READREG` and `WRITEREG` are complete and are what actually operate the camera.
- `DISCOVERY_ACK` returns a structurally valid but abbreviated identity block, not the full 248-byte payload.
- The UDP checksum is transmitted as zero. IPv4 permits this and GigE Vision allows it. The IPv4 header checksum is always computed.
- ICMP echo is bounded at 512 payload bytes; longer pings are dropped.
- Full 3 × 3 defect correction and demosaic need two line buffers. `line_buffer` is sized for it; the current `isp_defect` is a 5-tap horizontal clamp that needs no line storage.

**Bugs found and fixed during bring-up**, recorded because they are the kind that survive code review and die in simulation:

1. **Combinational loop in `async_fifo`.** Computing `full`/`empty` from the *next* Gray pointer while the pointer increment depends on the flag closes a loop. Everything resolved to X. Fixed by registering both flags — the standard Cummings formulation.
2. **`sync_fifo` was registered-read.** A consumer that must inspect the head before taking it (the frame reader, the descriptor ring) read X on first access. Converted to first-word-fall-through.
3. **`tx_compose` had no handshake.** It re-latched `p_data` on every cycle the MAC was not ready, transmitting the same byte repeatedly and desynchronising the source. Rewritten with proper valid/ready.
4. **`gvsp_tx` duplicated every byte** by loading the output register from the pre-shift value on the same cycle as the accept. Rewritten with a single output byte register and a one-deep 64-bit prefetch so the byte stream does not bubble every eighth byte.

---

## 8. Register map

GVCP bootstrap registers are at their standard addresses. Camera controls live at `0x0001_0000`:

| Offset | Register | Access |
|---|---|---|
| `0x00` | CTRL — stream enable, BLC, DPC, Mono10, soft trigger | R/W |
| `0x04` | STATUS — PHY status, sensor ready | R |
| `0x08` / `0x0C` | Width / Height | R/W |
| `0x10` / `0x14` | Offset X / Offset Y | R/W |
| `0x18` | Binning enable, ROI enable | R/W |
| `0x1C` | Digital gain, Q4.8 (`0x100` = unity) | R/W |
| `0x20` | Black level | R/W |
| `0x24` | Trigger mode — 0 free-run, 1 DI1, 2 DI2, 3 software | R/W |
| `0x28` / `0x2C` | Trigger delay / Strobe duration, in clocks | R/W |
| `0x30` / `0x34` | Timestamp low / high | R |
| `0x38` | Frames done, frames dropped | R |
| `0x3C` | Error count | R |
| `0x40` | PHY status | R |
