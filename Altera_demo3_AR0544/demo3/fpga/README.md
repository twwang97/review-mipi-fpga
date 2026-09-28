# Demo3 FPGA — device, vendor IP and reference RTL

Verilog-2001 reference design for the onsemi Demo3 baseboard FPGA, bringing up every
peripheral on the board.

---

## 0. What this is, and what it is not

**onsemi does not publish the Demo3 FPGA source.** The board ships as a pre-programmed
SPI EPROM image, and DevWare updates it in the field through the FX3's SPI master. Nothing
in this directory is a reproduction of that image.

What this *is*: a clean-room reference implementation written against the architecture
documented in `EVBUM2310/D`, using the block names, bus widths, data rates and I²C addresses
that onsemi states. Where the public documentation runs out — internal PLL structure,
register maps, sensor-specific tables — the design either parameterises the unknown or leaves a
host-loadable table rather than inventing a value. Those points are tagged `[INF]` or `[VERIFY]`
in the source and collected in section 7 below.

Everything compiles and elaborates cleanly under `iverilog -g2001 -Wall`, and the two algorithms
most likely to be subtly wrong (CSI-2 header ECC and payload CRC-16) have self-checking tests.

---

## 1. The FPGA

| Item | Value | Source |
|---|---|---|
| Device | **Altera (now Intel) Arria II GX `EP2AGX45DF25C4N`** | `EVBUM2310/D` |
| Family | Arria II GX — 40 nm, transceiver-equipped mid-range | — |
| Logic | ~45 000 logic elements | device family |
| Package | F25 FBGA, speed grade C4 | ordering code |
| Toolchain | **Quartus II 13.0sp1 or 13.1** | Arria II GX support ends at 13.1; Quartus II 14.0 and all Quartus Prime versions dropped the family |

Two supporting devices the RTL talks to, also named in `EVBUM2310/D`:

| Item | Part |
|---|---|
| USB 3.0 controller | Cypress FX3 `CYUSB3014-BZX` |
| HDMI transmitter | Analog Devices `ADV7526` |
| Frame buffer | DDR3 SDRAM, 64M × 16 (1 Gb) |

**A note on the 768 Mbps/lane MIPI ceiling.** Arria II GX has no hard MIPI D-PHY. The only way
to receive high-speed serial lanes is the LVDS SERDES driven by `ALTLVDS_RX`, and 768 Mbps per
lane sits right in the range that megafunction sustains with DPA enabled on this family. That
makes the documented Demo3 limit look like an I/O-primitive constraint rather than a protocol
one. This is an inference, not an onsemi statement — but it does explain why the ceiling is
where it is, and why no firmware update will lift it.

---

## 2. Vendor IP used

Everything here is an Altera megafunction or Qsys component for Arria II GX. Black-box
declarations with the required parameters live in `ip/demo3_ip_wrappers.v`; regenerate each
one with the Quartus II MegaWizard for your pin and PLL assignment.

| # | Vendor IP | Library / tool | Where it is used | Key parameters |
|---|---|---|---|---|
| 1 | **ALTPLL** | `altera_mf` | `demo3_clk_rst.v` | 50 MHz ref → c0 150 MHz core, c1 100 MHz control, c2 200 MHz DDR3 ref, c3 74.25 MHz pixel |
| 2 | **ALTLVDS_RX** | `altera_mf` | `demo3_top.v`, feeds MIPI / HiSPi / CCP | `number_of_channels=4`, `deserialization_factor=8`, `enable_dpa_mode="ON"`, `data_rate="768.0 Mbps"`, `rx_channel_data_align` exposed for bit-slip |
| 3 | **DDR3 SDRAM Controller with UniPHY** | External Memory Interface, Qsys | `frame_buffer_ctrl.v` | 64M × 16, Avalon-MM slave, 128-bit local data, burst ≤ 16 |
| 4 | **DCFIFO** | `altera_mf` | `rx_arbiter.v`, `frame_buffer_ctrl.v`, HDMI crossing | 72-bit / 128-bit, `rdsync_delaypipe=wrsync_delaypipe=4`, overflow + underflow checking on |
| 5 | **ALTSYNCRAM** | `altera_mf` | `i2c_seq.v` script RAM, `dpcm_decode.v` table | simple dual-port, single clock, `read_during_write_mode="DONT_CARE"` |
| 6 | **ALTDDIO_OUT** | `altera_mf` | `hdmi_out.v` and `fx3_slave_fifo.v` clock forwarding | forwards `HDMI_CLK` and `FX3_PCLK` out of real output registers rather than routed clocks |
| 7 | **ALTDDIO_IN** | `altera_mf` | optional DDR capture on the parallel bus | declared, instantiate if your headboard runs DDR parallel |
| 8 | **ALTCLKCTRL** | `altera_mf` | global clock buffering for `MCLK` and the recovered link clocks | instantiate if the fitter does not infer a global network |
| 9 | **ALTASMI_PARALLEL / ALTREMOTE_UPDATE** | `altera_mf` | optional FPGA-side access to the config EPROM | **not instantiated** — FX3 owns that SPI bus by default; `spi_master.v` can take it over |
| 10 | **ALTGX transceivers** | Arria II GX hard IP | **not used** | The GX channels are available but FX3's GPIF II is a 32-bit LVCMOS parallel bus, so nothing needs them. Worth remembering if you ever want a SerDes ingress path. |
| 11 | **Nios II** | Qsys | **not used** | FX3 is the control processor; the register plane is driven over GPIF II. Add a Nios II only if you want the board to run standalone. |
| 12 | `LPM_COUNTER`, `LPM_MULT` | `lpm` | inferred by synthesis | not explicitly instantiated |

---

## 3. Module hierarchy

```
demo3_top
├── demo3_clk_rst ............ ALTPLL ×1, reset tree, MCLK divider
│
├── INGRESS ────────────────────────────────────────────────────
│   ├── altlvds_rx_wrap ...... ALTLVDS_RX, 4ch, J=8, shared MH_* pins
│   ├── mipi_dphy_rx ......... LP-state decode, burst framing, lane merge
│   │   └── mipi_lane_align .. 0xB8 sync hunt + bit-slip, per lane
│   ├── csi2_decoder ......... header ECC, short/long split, CRC-16
│   ├── hispi_word_asm ....... 8-bit stream → 10/12/14-bit HiSPi words
│   ├── hispi_rx ............. programmable sync codes, SOF/SOL/EOL/EOF
│   ├── ccp_rx ............... SMIA CCP2, single lane
│   ├── parallel_rx .......... 10/12-bit, FV/LV/PIXCLK
│   └── raw_unpack ........... RAW8/10/12/14 → 16-bit pixel containers
│
├── rx_arbiter ............... source select + DCFIFO CDC into 150 MHz
├── dpcm_decode .............. DPCM 10→8, host-loaded table
├── formatter ................ 8 pixels → one 128-bit DDR3 beat
│
├── frame_buffer_ctrl ........ Avalon-MM master, triple buffer, capture mode
│   └── ddr3_uniphy .......... DDR3 SDRAM Controller with UniPHY
│
├── EGRESS ─────────────────────────────────────────────────────
│   ├── fx3_slave_fifo ....... GPIF II slave FIFO master, 3 threads
│   ├── video_timing_gen ..... 720p60 / 1080p60 / register-defined
│   └── hdmi_out ............. 36-bit bus to ADV7526 + clock forward
│
├── CONTROL ────────────────────────────────────────────────────
│   ├── i2c_master ........... 100 k / 400 k / 1 M, stretch + arbitration
│   ├── i2c_seq .............. scripted init from ALTSYNCRAM
│   ├── spi_master ........... config EPROM / headboard SPI
│   ├── head_ctrl ............ HEAD_RESET_L, SP[5:0], power switch, MCLK
│   ├── event_ctrl ........... interrupt aggregation
│   └── reg_file ............. control/status plane
│
└── util ..................... cdc_sync, pulse_sync, rst_sync, evt_counter
```

3 642 lines of Verilog-2001 across 24 RTL files.

---

## 4. Peripheral coverage

| Peripheral | Enabled by | Notes |
|---|---|---|
| MIPI D-PHY, 1/2/4 lane | `R_RX_SEL=0`, `R_RX_CTRL` | ECC-checked headers, CRC-checked payloads, VC/DT filter |
| HiSPi, 4 lane | `R_RX_SEL=1` | sync codes loaded via `R_HISPI_SYNC0/1` |
| CCP2, 1 lane | `R_RX_SEL=2` | 8/10/12-bit raw |
| Parallel 10/12-bit | `R_RX_SEL=3` | FV/LV polarity configurable |
| DPCM 10→8 | `R_RX_CTRL[8]` | table loaded via `R_DPCM_ADDR`/`R_DPCM_DATA` |
| DDR3 frame buffer | `R_FB_CTRL` | triple-buffered or frame-capture |
| FX3 / USB 3.0 | `R_FX3_CTRL` | video thread + register command/response threads |
| ADV7526 HDMI | `R_VTG_CTRL`, `R_HDMI_CTRL` | 720p60, 1080p60, or custom timing |
| I²C master | `R_I2C_CTRL`, `R_I2C_CMD` | auto-routes to board or headboard bus by device address |
| I²C init sequencer | `R_I2C_SEQ_*` | replays a host-loaded script — how ADV7526 and the clock generator get programmed |
| SPI master | `R_SPI_CTRL` | EPROM or headboard SPI |
| Headboard power switch | `R_HEAD_CTRL[3]` | software-gated, matching DevWare's observed flow |
| `HEAD_RESET_L` | `R_HEAD_CTRL[1]`, `R_HEAD_RST_LEN` | defaults to 36 000 000 core clocks = 240 ms at 150 MHz, matching the headboard supervisor |
| `MCLK` generator | `R_HEAD_CTRL[2]`, `R_HEAD_MCLK_DIV` | optional; most headboards use their own crystal |
| SP[5:0] | `R_HEAD_SP_OUT/OE/IN` | bidirectional; edge counters on SP1/SP2 count FLASH and SHUTTER pulses back from the sensor |
| Interrupts | `R_IRQ_*` | 16 sources, latched, write-1-to-clear |

### Bringing up an AR0544 headboard

The SP mapping from the AR0544 headboard schematic drops straight into `head_ctrl`:

| SP | Sensor pin | Direction |
|---|---|---|
| SP0 | `TEST` | out |
| SP1 | `GPIO0` (FLASH) | in — counted |
| SP2 | `GPIO1` (SHUTTER) | in — counted |
| SP3 | `GPI2` (trigger / SADDR) | out |
| SP4 | `GPI3` (daisy chain / trigger) | out |
| SP5 | `XSHUTDOWN` override | out |

Typical sequence: `R_HEAD_CTRL[3]=1` (headboard power) → wait → `R_I2C_SEQ_*` to program the
clock generator → `R_HEAD_CTRL[1]=1` (240 ms reset pulse) → `R_I2C_SEQ_*` for the sensor preset
→ `R_RX_SEL=0`, `R_RX_CTRL` lanes=2 bitdepth=10 → `R_FB_CTRL[0]=1` → `R_FX3_CTRL[0]=1`.

---

## 5. Verification

```
$ make lint
lint: demo3_top elaborated          # iverilog -g2001 -Wall, no warnings

$ make tb
ECC: 4800 single-bit injections, all detected
ECC: all 24 single-bit syndromes are distinct
CRC: check value = 0x6f91 (CRC-16/MCRF4XX expects 0x6F91)
CRC: 8 single-bit payload injections, all detected
RESULT: all algorithm self-checks PASSED
```

The CRC check deserves a word. CSI-2 specifies init `0xFFFF`, LSB-first, polynomial
x¹⁶+x¹²+x⁵+1 — which is exactly the catalogue entry **CRC-16/MCRF4XX**, whose published check
value over the ASCII string `123456789` is `0x6F91`. Testing against that gives an independent
reference rather than a remembered worked example. The ECC test is stronger than it looks: if
any parity equation were wrong, single-bit syndromes would almost certainly collide, and the
test proves all 24 are distinct.

What is **not** verified: nothing here has been run against real captured sensor traffic, and
there is no gate-level or timing-closure result. Treat this as a design that elaborates and
whose algorithms are sound, not as silicon-proven RTL.

---

## 6. Design decisions worth knowing

**One LVDS instance, not three.** `MH_DATA[3:0]` and `MH_CLK` are a single physical pin group on
P5, so MIPI, HiSPi and CCP cannot each have their own `ALTLVDS_RX` instance. The design fixes
J=8 for MIPI's byte stream and regroups into HiSPi's 10/12/14-bit words in fabric
(`hispi_word_asm.v`). The alternative is dynamic reconfiguration of the megafunction, which is
slower to switch and much harder to close timing on.

**16-bit pixel containers, not bit-packed.** The formatter spends 16 bits of DDR3 on every
pixel regardless of bit depth. For RAW10 that is 1.6× the minimum. It is affordable: the frame
buffer accepts 400 Mpixel/s and a 5 MP / 60 fps sensor produces about 302 Mpixel/s. Switch to
packed mode if you need the headroom back.

**No hard-coded vendor register values.** The ADV7526 init sequence lives in Analog Devices'
programming guide, the clock generator's in its own data sheet, and the AR0544's register
preset is NDA-only. Rather than guess, `i2c_seq.v` replays a script the host loads at runtime.
This is also how DevWare works — the presets live on the PC, not in the FPGA.

**The DPCM table is loaded, not baked in.** Same reasoning: the AR0544's DPCM 10→8 predictor
and quantisation table are in the full data sheet. `dpcm_decode.v` implements the structure
(simple predictor, two colour planes, clamped) and takes the table from the host.

---

## 7. Everything that needs confirming before a real build

| # | Item | Why |
|---|---|---|
| 1 | Board reference oscillator frequency into the FPGA | `demo3_clk_rst.v` assumes 50 MHz; regenerate ALTPLL if different |
| 2 | Actual pin assignments for every port in `demo3_top` | No `.qsf` is provided — the board's pinout is not public |
| 3 | `ALTLVDS_RX` exact parameterisation and whether DPA or soft-CDR mode is right for your data rate | Drives the achievable lane rate |
| 4 | HiSPi sync codes for your sensor | Left as registers on purpose |
| 5 | AR0544 DPCM predictor and table | NDA data sheet |
| 6 | ADV7526 register init sequence | ADI programming guide |
| 7 | Clock generator (I²C `0xD2`) part number and register map | Not named in `EVBUM2310/D` |
| 8 | FX3 GPIF II state machine on the firmware side must match the thread map in `fx3_slave_fifo.v` | The FPGA and FX3 halves have to agree |
| 9 | CSI-2 ECC and CRC against your copy of the spec | Tested for self-consistency, not against the normative text |
| 10 | DDR3 timing parameters for the fitted memory device | UniPHY needs the real part's speed bin |
| 11 | Whether the on-board I²C and headboard I²C are physically one bus or two | `demo3_top` assumes two and routes by device address |
| 12 | Timing closure at 150 MHz core and at the LVDS rate | No fit has been run |

---

## 8. Files

```
demo3_fpga/
├── README_FPGA_IP.md          this document
├── Makefile                   lint + testbench
├── rtl/       24 files        Verilog-2001 source
├── ip/        1 file          vendor IP black-box declarations
├── constraints/demo3.sdc      TimeQuest constraints
└── tb/        1 file          ECC and CRC self-checks
```
