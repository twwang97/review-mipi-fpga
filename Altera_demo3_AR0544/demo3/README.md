# Demo3 Baseboard — onsemi AGB1N0CS-GEVK

Engineering notes on the Demo3 image-sensor evaluation baseboard, organised by functional group.
Demo3 is the host-side half of onsemi's sensor evaluation ecosystem: a sensor headboard plugs into
it, and it turns whatever that sensor emits into USB 3.0 frames for DevWare on a PC, or into HDMI
for a monitor.

---

## 0. Scope, sources and how to read this

| Source | What it gives |
|---|---|
| `EVBUM2310/D` rev. 1 (July 2020) — Demo3 user's manual | Block diagrams, receiver specs, frame buffer numbers, full 52-pin table, silicon part numbers |
| `EVBUM2904/D` (AR1223 D-PHY headboard) | Headboard-side view of the same connector |
| `AR0544_CSP47_Demo3Head` schematic rev 1.0 | Concrete example of how a headboard uses each pin |
| DevSuite quick-start guide | Host-side setup, USB port requirements |
| `EVBUM2313/D` (AGB3N0CS-GEVK) | Demo3-headboard-to-Demo2X adapter |

Confidence tags used throughout:

- **[DS]** — stated in onsemi documentation
- **[SCH]** — read off a headboard schematic
- **[INF]** — inferred from the architecture; verify before relying on it

Section 15 collects every **[INF]**.

---

## 1. What the board is

| Attribute | Value |
|---|---|
| Part number | `AGB1N0CS-GEVK` |
| FPGA | Altera Arria II GX `EP2AGX45DF25C4N` |
| USB controller | Cypress FX3 `CYUSB3014-BZX`, USB 3.0 |
| HDMI transmitter | Analog Devices `ADV7526` |
| Frame buffer | DDR3 SDRAM, 64M × 16 = 1 Gb |
| Sensor interfaces | MIPI D-PHY up to 4 lanes, HiSPi up to 4 lanes, CCP 1 lane, parallel 10/12-bit |
| Control | I²C |
| Headboard connector | 52-pin, `P5` |
| Host connector | USB 3.0 Type-B, `J2` |
| Video out | HDMI, `J3` |
| Power source | 5 V from the USB 3.0 bus — no separate supply |

All **[DS]**.

The board is deliberately generic. It knows nothing about any particular sensor; DevWare on the PC
holds the register presets and drives everything over I²C. That is why the same baseboard works with
a 1 MP global-shutter part and a 20 MP rolling-shutter part.

---

## 2. Functional grouping

Six groups. The first three are the datapath in order; the last three cut across it.

| Group | Contains | Why grouped |
|---|---|---|
| **A · Ingress** | MIPI, HiSPi, CCP and parallel receivers, each with its own output FIFO | All four do the same job — deserialise and cross into the FPGA core clock domain |
| **B · Buffering & formatting** | Formatter, DDR3 memory controller, DDR3 SDRAM, frame buffer controller, video format generator | Rate matching between an unstoppable sensor and a bursty USB host |
| **C · Egress** | FX3 interface (32-bit GPIF II), Cypress FX3, USB 3.0; ADV7526, HDMI | Two independent consumers of the same buffered frames |
| **D · Control plane** | I²C master, SPI EPROM + FX3 SPI master, system EEPROM | Configuration: of the sensor, of the FPGA, and of the board's own peripherals |
| **E · Clocking** | Clock generator (I²C 0xD2), 150 MHz FPGA core clock, MCLK out, recovered link clocks | One tree, several sources |
| **F · Power** | 5 V USB input, power distribution, headboard power switch, six headboard rails | Everything downstream depends on one 5 V bus |

---

## 3. Top-level block diagram

```
                                 ┌─────────────┐
       ┌─────────────────────────│  USB 3.0    │◀═══════ USB 3.0 Type-B cable ══▶ HOST PC
       │      5 V bus power      │ connector J2│                                  (DevWare /
       │                         └──────┬──────┘                                   DevSuite)
       ▼                                │ SuperSpeed data
 ┌─────────────┐                        │
 │   POWER     │                 ┌──────▼─────────────────┐
 │DISTRIBUTION │                 │  Cypress FX3           │
 │  (group F)  │                 │  CYUSB3014-BZX         │
 └──┬───────┬──┘                 │  ┌──────────────────┐  │
    │       │                    │  │ 32-bit GPIF II   │  │      ┌──────────┐
    │       │  board rails       │  │ ≤ 5 Gb/s         │  │      │   SPI    │
    │       └────────────────┐   │  ├──────────────────┤  │      │  EPROM   │
    │                        │   │  │ SPI master ──────┼──┼─────▶│ (FPGA    │
    │  ┌──────────────────┐  │   │  ├──────────────────┤  │      │  config) │
    │  │ HEADBOARD POWER  │  │   │  │ I²C master       │  │      └────┬─────┘
    │  │     SWITCH       │  │   │  └──────────────────┘  │           │
    │  └────────┬─────────┘  │   └──────┬───────────┬─────┘           │ config
    │           │            │          │ 32-bit    │ I²C             │ image
    │           │            ▼          ▼           │                 ▼
    │           │      ┌──────────────────────────────────────────────────────┐
    │           │      │  FPGA — Altera Arria II GX  EP2AGX45DF25C4N          │
    │           │      │  (groups A, B, D, E — expanded in section 4)         │
    │           │      └───┬──────────────────┬─────────────────────┬─────────┘
    │           │          │ 128-bit          │ 36-bit              │ I²C
    │           │          ▼                  ▼                     │
    │           │   ┌─────────────┐    ┌──────────────┐             │
    │           │   │ DDR3 SDRAM  │    │  ADV7526     │             │
    │           │   │  64M × 16   │    │  HDMI TX     │──▶ HDMI J3 ─┼──▶ monitor
    │           │   │  1 Gb frame │    │  (I²C 0x72)  │             │
    │           │   │   buffer    │    └──────────────┘             │
    │           │   └─────────────┘                                 │
    │           │                                                   │
    │           ▼                        ▲                          ▼
    │   ┌───────────────────────────────────────────────────────────────────┐
    └──▶│      HEADBOARD CONNECTOR  P5  —  52 pins                          │
        │  power ·  I²C ·  MCLK ·  reset ·  SP[5:0] ·  MIPI/HiSPi ·  parallel│
        └────────────────────────────────┬──────────────────────────────────┘
                                         │
                                    ═════╪═════  mates with J1 on the headboard
                                         ▼
                              sensor headboard (e.g. AR0544)
```

---

## 4. FPGA internal block diagram

```
 ┌──────────────────────── EP2AGX45DF25C4N ──────────────────────────────────────┐
 │                                                                               │
 │  GROUP A · INGRESS                        GROUP B · BUFFERING & FORMATTING    │
 │  ┌──────────────────────────┐                                                 │
 │  │ VIDEO RECEIVERS          │             ┌───────────┐                       │
 │  │  ┌────────────────────┐  │             │ Formatter │                       │
 │  │  │ MIPI    4 lanes    │  │   ┌────┐    └─────┬─────┘                       │
 │  │  │ ≤768 Mbps/lane     │──┼──▶│FIFO│──────────┤                             │
 │  │  ├────────────────────┤  │   └────┘          │                             │
 │  │  │ HiSPi   4 lanes    │  │   ┌────┐          ▼                             │
 │  │  │ 1 Gbps/lane        │──┼──▶│FIFO│    ┌──────────────────┐     128        │
 │  │  ├────────────────────┤  │   └────┘    │ DDR3 memory      │◀═══════▶ DDR3  │
 │  │  │ CCP     1 lane     │  │   ┌────┐    │ controller       │     128  SDRAM │
 │  │  │ ≥640 Mbps          │──┼──▶│FIFO│───▶│ 150 MHz          │                │
 │  │  ├────────────────────┤  │   └────┘    │ 750 MP/s peak    │                │
 │  │  │ Parallel 10/12-bit │  │   ┌────┐    └────────┬─────────┘                │
 │  │  │ ≥125 MHz pixel rate│──┼──▶│FIFO│             │                          │
 │  │  └────────────────────┘  │   └────┘             ▼                          │
 │  └──────────────────────────┘                ┌──────────────┐                 │
 │        each FIFO crosses from the            │ Frame buffer │                 │
 │        receiver clock into the               │ controller   │                 │
 │        150 MHz FPGA core clock  [DS]         │ triple-buffer│                 │
 │                                              └──────┬───────┘                 │
 │                                                     │                         │
 │                                    ┌────────────────┴─────────────┐           │
 │                                    ▼                              ▼           │
 │                          ┌──────────────────┐         ┌────────────────────┐  │
 │  GROUP D · CONTROL       │ Video format     │         │  FX3 interface     │  │
 │  ┌────────────────┐      │ generator        │         │  32-bit            │  │
 │  │ I²C interface  │      │ 720p60 / 1080p60 │         └─────────┬──────────┘  │
 │  └───────┬────────┘      └────────┬─────────┘  36               │ 32          │
 │          │                        │                             │             │
 │  ┌───────┴────────┐               ▼                             ▼             │
 │  │ SPI config     │          to ADV7526                      to FX3           │
 │  │ loader         │◀── external SPI EPROM                                     │
 │  └────────────────┘                                                           │
 └───────────────────────────────────────────────────────────────────────────────┘
```

Bus widths on the original diagram: 128-bit both ways to the DDR3 controller, 36-bit to HDMI,
32-bit to FX3, 16-bit to the SDRAM device **[DS]**.

---

## 5. Group A — ingress receivers and their limits

| Receiver | Lanes | Rate | Standard | Notes |
|---|---|---|---|---|
| **MIPI** | 4 data | **≤ 768 Mbps/lane** | D-PHY v1.00.00 | Uses both single-ended and differential signalling per the spec |
| **HiSPi** | 4 data + 1 DDR clock | 1 Gbps/lane | HiSPi v1.50.00 | Unidirectional differential; Streaming-S, Streaming-SP, Packetized SP |
| **CCP** | 1 | ≥ 640 Mbps | SMIA CCP2 1.0 | 8, 10 or 12-bit raw |
| **Parallel** | 10 or 12 bits | ≥ 125 MHz pixel rate | — | Switches between driven and high-Z asynchronously, under pin or register control |

All **[DS]**.

**The MIPI receiver is the weakest link on this board.** 768 Mbps per lane is well below what modern
sensors transmit — the AR0544 alone is rated at 1.72 Gbps per lane. This is not a defect; Demo3
predates those parts. But it means *the baseboard, not the sensor, usually sets your frame rate.*
Section 13 works the numbers.

Each receiver has its own output FIFO whose only job is to move data from the recovered link clock
into the 150 MHz core clock **[DS]**. That is the one clock-domain crossing you care about when
debugging tearing or dropped lines.

---

## 6. Group B — the frame buffer

The 1 Gb DDR3, built from a single 64M × 16 device, sits between an unstoppable sensor and a bursty
consumer **[DS]**:

| Property | Value |
|---|---|
| Capacity | 1 Gb — about 3 frames of a 20 MP sensor |
| Buffering scheme | Triple-buffered, to minimise frame loss |
| Controller clock | 150 MHz FPGA core clock |
| Peak available bandwidth | 750 Mpixel/s |
| **Peak input bandwidth** | **400 Mpixel/s** |
| **Peak output bandwidth** | **200 Mpixel/s** |

Two principal operating modes **[DS]**:

1. **Self-timed** — the buffer runs free and feeds FX3 as data arrives. This is normal streaming.
2. **Direct-to-FX3 at HDMI rates** — the buffer is paced to a 720p60 or 1080p60 output.

It can also be configured as a **frame-capture device**: fill the entire buffer, *then* send it to
FX3. That is the mode you want for burst capture or for any experiment where USB backpressure would
otherwise corrupt timing.

Note the asymmetry: **input 400 MP/s, output 200 MP/s.** The buffer can absorb twice as fast as it
can drain. That is what makes burst capture work, and it is also a ceiling you can hit — see
section 13.

---

## 7. Group C — egress

### FX3 / USB 3.0

The Cypress FX3 presents a 32-bit data interface to the FPGA's differential I/O, with a maximum
interface rate of 5 Gb/s **[DS]**. The GPIF II bus is 32 bits wide with 14 configurable control
pins **[DS]**.

Host-side requirement from the quick-start guide: **connect to a USB 3.0 port.** Some USB 2
implementations are not backward-compatible with Demo3 and cause data loss or poor streaming; DevWare
will warn you **[DS]**. Also worth knowing: some graphics cards and drivers will not display images
much above roughly 8 MP, which is a display limitation, not a capture one **[DS]**.

### HDMI

`ADV7526`, HDMI 1.4 with 12-bit deep colour, accepting RGB or YCbCr, fed with 34-bit data, at I²C
address `0x72` **[DS]**. This path lets you get a live preview with no PC at all — useful for
demos and for isolating "is it the sensor or is it the USB stack?" during debug.

---

## 8. Group D + the 52-pin headboard connector (P5)

### 8.1 I²C map

| Device | Address |
|---|---|
| HDMI transmitter (ADV7526) | `0x72` |
| Clock generator | `0xD2` |
| System EEPROM | `0xA0`, software-configurable up to `0xAX` |
| Sensor / headboard | via `HEAD_SCL` / `HEAD_SDA`, address set on the headboard |

Bus speeds: 100 kHz, 400 kHz, 1 MHz **[DS]**. Operational mode control is done in software over
I²C from the controller — there are very few hardware straps on this board.

### 8.2 The connector, grouped by function

Regrouped from `EVBUM2310/D` Table 1. Directions below are given **from the headboard's point of
view**, which is the self-consistent convention (see section 14).

**Serial image data — 10 pins**

| Pin | Name | Dir | Function |
|---|---|---|---|
| 49 / 51 | `MH_DATA0_P` / `MH_DATA0_N` | Out | MIPI or HiSPi data lane 0 |
| 1 / 3 | `MH_DATA1_P` / `MH_DATA1_N` | Out | Data lane 1 |
| 2 / 4 | `MH_DATA2_P` / `MH_DATA2_N` | Out | Data lane 2 |
| 6 / 8 | `MH_DATA3_P` / `MH_DATA3_N` | Out | Data lane 3 |
| 52 / 50 | `MH_CLK_P` / `MH_CLK_N` | Out | Link clock lane |

A 2-lane sensor like the AR0544 leaves pins 2, 4, 6 and 8 unused.

**Parallel image data — 16 pins**

| Pins | Name | Dir | Function |
|---|---|---|---|
| 10, 9, 12, 11, 14, 13, 16, 17 | `S_DATA0` … `S_DATA7` | I/O | Parallel data, low byte |
| 18 – 25 | `S_DATA8` … `S_DATA15` | I/O | Parallel data, high byte |

**Parallel framing — 3 pins**

| Pin | Name | Dir | Function |
|---|---|---|---|
| 29 | `S_LINE_VALID` | Out | Line valid |
| 35 | `S_FRAME_VALID` | Out | Frame valid |
| 36 | `S_PIXCLK` | Out | Pixel clock |

**Clocks — 3 pins**

| Pin | Name | Dir | Function |
|---|---|---|---|
| 44 | `MCLK` | In | Master clock from Demo3 to the sensor |
| 45 | `HEAD_DCLK` | In | Differential clock signal |
| 5 | `S_RESERVED1` | Out | Documented as reserved; **used as the frame-buffer clock by real headboards** |

**Control and configuration — 11 pins**

| Pin | Name | Dir | Function | Typical headboard use **[SCH]** |
|---|---|---|---|---|
| 31 | `HEAD_RESET_L` | In | Reset to the headboard sensor | → supervisor `MR` → `XSHUTDOWN` |
| 43 | `HEAD_SCL` | In | I²C clock | → sensor `SCL` |
| 37 | `HEAD_SDA` | I/O | I²C data | → sensor `SDA` |
| 27 | `S_SP0` | In | General control 0, +3.3 V | → `TEST` |
| 28 | `S_SP1` | In | General control 1 | → `GPIO0` (FLASH) |
| 33 | `S_SP2` | In | General control 2 | → `GPIO1` (SHUTTER) |
| 30 | `S_SP3` | In | General control 3 | → `GPI2` (trigger / SADDR) |
| 32 | `S_SP4` | In | General control 4 | → `GPI3` (daisy chain / trigger) |
| 26 | `S_SP5` | In | General control 5 | → `XSHUTDOWN` override |
| 7 | `HEAD_MOSI` | I/O | SPI master-out | Rarely used by sensor headboards |
| 41 | `HEAD_MISO` | I/O | SPI master-in | " |
| 34 | `HEAD_SSN` | In | SPI slave select | " |
| 40 | `S_RESERVED0` | In | General reserved 0 | " |

**Power — 7 pins**

| Pin | Name | Voltage | Function |
|---|---|---|---|
| 39 | `+5V0_HEAD` | 5.0 V | LEDs, flash drivers |
| 47 | `+3V3_HEAD` | 3.3 V | Headboard peripherals: gates, EEPROM, supervisor |
| 38 | `+2V8_VAA_HEAD` | 2.8 V | Sensor analog and pixel supplies |
| 48 | `+2V8_VDDIO_HEAD` | 2.8 V | Optional 2.8 V sensor I/O |
| 42 | `+1V8_HEAD` | 1.8 V | Sensor 1.8 V analog + I/O |
| 46 | `+1V2_HEAD` | 1.2 V | Core rail, or the input to a headboard LDO |
| 15 | `VDDIO_SENSE` | — | Reference input: lets Demo3 learn the headboard's I/O level |

`VDDIO_SENSE` is the neat bit of this connector. Rather than strapping the baseboard, the headboard
*tells* Demo3 what logic level it is running at, and Demo3 sets its own I/O accordingly. That is
what lets one baseboard drive both 1.8 V and 2.8 V headboards safely.

---

## 9. Clock tree

```
 ┌──────────────────────────── DEMO3 ───────────────────────────────────────────┐
 │                                                                              │
 │  on-board reference  ──▶ ┌───────────────────┐                               │
 │  [INF]                   │  Clock generator  │── programmed over I²C (0xD2)  │
 │                          └─────────┬─────────┘                               │
 │                                    │                                         │
 │                                    ├────────────▶ MCLK ──▶ P5 pin 44 ────────┼──▶ headboard
 │                                    │                                         │      (optional;
 │                                    │                                         │       most boards
 │                                    ▼                                         │       use their
 │                          ┌───────────────────┐                               │       own XO)
 │                          │  FPGA PLLs  [INF] │                               │
 │                          └─────────┬─────────┘                               │
 │                                    │                                         │
 │            ┌───────────────────────┼──────────────────┬──────────────┐       │
 │            ▼                       ▼                  ▼              ▼       │
 │   ┌────────────────┐   ┌───────────────────┐  ┌─────────────┐ ┌───────────┐  │
 │   │ FPGA core      │   │ DDR3 interface    │  │ HDMI pixel  │ │ FX3 GPIF  │  │
 │   │ 150 MHz  [DS]  │   │ clock      [INF]  │  │ clock [INF] │ │ clock[INF]│  │
 │   └───────┬────────┘   └───────────────────┘  └─────────────┘ └───────────┘  │
 │           │                                                                  │
 │           │  ◀── every receiver FIFO crosses INTO this domain  [DS]          │
 │           │                                                                  │
 │  ┌────────┴────────────────────────────────────────────────────────┐         │
 │  │ RECOVERED / RECEIVED CLOCK DOMAINS (one per active interface)   │         │
 │  │                                                                 │         │
 │  │  MH_CLK_P/N  (pins 52/50) ──▶ MIPI D-PHY clock lane             │◀────────┼── from
 │  │  MH_CLK_P/N               ──▶ HiSPi DDR clock lane              │         │   sensor
 │  │  S_PIXCLK    (pin 36)     ──▶ parallel pixel clock              │         │
 │  │  HEAD_DCLK   (pin 45)     ──▶ differential clock in             │         │
 │  │  S_RESERVED1 (pin 5)      ──▶ frame-buffer clock from headboard │         │
 │  └─────────────────────────────────────────────────────────────────┘         │
 │                                                                              │
 │  ┌──────────────────────────────┐                                            │
 │  │ FX3 internal PLL  → USB 3.0  │  SuperSpeed 5 Gb/s serial clock recovered  │
 │  │ reference crystal     [INF]  │  by the host link, independent of the      │
 │  └──────────────────────────────┘  video clocks                              │
 └──────────────────────────────────────────────────────────────────────────────┘
```

**Two things are worth internalising:**

1. **The sensor clock and the board clock are usually different sources.** Demo3 *can* drive `MCLK`
   to the headboard, but most headboards default to their own crystal (the AR0544 board ships with a
   20 MHz oscillator selected by `P20 1-3`). So the sensor's pixel clock is asynchronous to Demo3's
   150 MHz core. The receiver FIFOs are what make that safe.

2. **`HEAD_DCLK` and pin 5 go the other way.** Pin 44 (`MCLK`) is Demo3 → headboard. Pin 45
   (`HEAD_DCLK`) and pin 5 are headboard → Demo3. Mixing these up is a classic bring-up mistake,
   made worse because pin 5 is named `S_RESERVED1` in the baseboard manual.

---

## 10. Reset / boot sequencer

Demo3 has no single "reset" — it has a boot chain, and the sensor's reset is the last link in it.

```
  ① USB 3.0 cable plugged in
     │
     │  5 V appears on J2
     ▼
  ② Board rails come up through power distribution (group F)
     │
     ▼
  ③ FPGA configures itself from the external SPI EPROM                       [DS]
     │      ┌──────────────────────────────────────────────────────────┐
     │      │ If the EPROM image is wrong or missing, nothing further   │
     │      │ works. FX3 can rewrite it through its SPI master — that   │
     │      │ is how DevWare updates Demo3 firmware in the field. [DS]  │
     │      └──────────────────────────────────────────────────────────┘
     ▼
  ④ FX3 boots and enumerates on USB 3.0
     │
     ▼
  ⑤ Host DevWare opens the device, checks firmware, downloads if needed      [DS]
     │
     ▼
  ⑥ DevWare enables the HEADBOARD POWER SWITCH                               [INF]
     │      headboard rails (+5V0 +3V3 +2V8_VAA +2V8_VDDIO +1V8 +1V2) come up
     │      VDDIO_SENSE tells Demo3 which I/O level to use
     ▼
  ⑦ DevWare configures the clock generator over I²C (0xD2)                   [DS]
     │      MCLK starts, if the headboard is configured to use it
     ▼
  ⑧ DevWare asserts HEAD_RESET_L (pin 31)
     │      → headboard supervisor → XSHUTDOWN low for 240 ms          [SCH]
     ▼
  ⑨ Reset released; DevWare writes the sensor's register preset over I²C
     │
     ▼
  ⑩ Streaming enabled — MIPI lanes leave LP-11, FS/FE packets begin,
     receiver FIFOs fill, frame buffer starts triple-buffering,
     FX3 DMA moves frames to the host
```

Timing view of the last three steps:

```
  headboard rails   ▁▁▁▁╱▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔

  MCLK / sensor XO  ▁▁▁▁▁▁▁▁▁▁╱▔╲▁╱▔╲▁╱▔╲▁╱▔╲▁╱▔╲▁╱▔╲▁╱▔╲▁╱▔╲▁╱▔╲▁╱▔╲▁╱▔╲▁╱▔╲▁

  HEAD_RESET_L      ▔▔▔▔▔▔▔▔▔▔▔▔▔▔╲▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁╱▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔

  XSHUTDOWN         ▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔╲▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁╱▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔
  (on headboard)                      ◀──── 240 ms ────────▶

  I²C to sensor     ──────────── idle ───────────────────────────┤▶ preset writes

  MIPI lanes        ─────────────── LP-11 ───────────────────────────────┤▶ stream
```

**Reset entry points you can use manually:** `SW1` on the headboard gives a clean 240 ms sensor
reset without touching Demo3. Unplugging USB resets the entire chain including the FPGA.

---

## 11. Power sequencer

### 11.1 Rail tree

```
   USB 3.0 bus, 5 V
   ────────┬──────────
           │  USB 3.0 supplies up to 900 mA at 5 V = 4.5 W for the whole stack
           ▼  (USB spec, not an onsemi number)
   ┌────────────────────────┐
   │  POWER DISTRIBUTION    │
   └───┬────────────────┬───┘
       │                │
       │ board rails    │ headboard rails
       ▼                ▼
 ┌──────────────┐  ┌──────────────────────┐
 │ FPGA core +  │  │ HEADBOARD POWER      │   gated + sequenced, so a headboard can be
 │ I/O   [INF]  │  │      SWITCH          │   hot-swapped with the USB cable attached
 │ FX3   [INF]  │  └──────────┬───────────┘
 │ DDR3  [INF]  │             │
 │ ADV7526[INF] │             ├──▶ pin 39  +5V0_HEAD        5.0 V
 └──────────────┘             ├──▶ pin 47  +3V3_HEAD        3.3 V
                              ├──▶ pin 38  +2V8_VAA_HEAD    2.8 V
                              ├──▶ pin 48  +2V8_VDDIO_HEAD  2.8 V
                              ├──▶ pin 42  +1V8_HEAD        1.8 V
                              └──▶ pin 46  +1V2_HEAD        1.2 V

                              ◀── pin 15  VDDIO_SENSE
                                  headboard reports its I/O level back
```

### 11.2 Sequence

```
                   t0        t1            t2            t3            t4
                   │         │             │             │             │
 USB 5 V          ▁▁╱▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔
                   │         │             │             │             │
 board rails      ▁▁▁▁▁▁╱▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔
 FPGA, FX3, DDR3   │         │             │             │             │
                   │         │             │             │             │
 FPGA configured  ▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁╱▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔
 (from SPI EPROM)  │         │             │             │             │
                   │         │             │             │             │
 USB enumerated   ▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁╱▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔
                   │         │             │             │             │
 headboard power  ▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁╱▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔
 switch enabled    │         │             │             │  ◀ DevWare │
                   │         │             │             │    commands │
 sensor reset     ▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔╲▁▁▁▁▁▁▁▁╱▔▔▔▔▔▔▔▔
 released                                                     ◀ 240 ms ▶
```

The important architectural point: **the headboard is powered under software control, after USB
enumeration.** A sensor sitting on an unenumerated Demo3 has no power at all. If you are probing a
headboard rail and seeing zero volts, check that DevWare has actually connected before you start
suspecting the regulators.

The 4.5 W USB budget is generous for a part like the AR0544 (158 mW at 5 MP / 60 fps) but it does
have to cover the FPGA, DDR3, FX3 and, if you use it, the HDMI transmitter. Bus-powered operation is
the reason the quick-start guide is emphatic about using a real USB 3.0 port.

---

## 12. Interrupt and event architecture

Like the sensor, Demo3 has no classical interrupt pin exposed to you. Events propagate up a chain,
each stage converting the previous stage's notion of "done" into its own.

```
  ┌── SENSOR ──────────────────────────────────────────────────────────────────┐
  │  Frame Start / Frame End / Line Start / Line End short packets              │
  │  Embedded data rows                                                         │
  └───────────────────────────────────┬─────────────────────────────────────────┘
                                      │  in-band on the MIPI link
                                      ▼
  ┌── DEMO3 RECEIVER (group A) ────────────────────────────────────────────────┐
  │  · packet decode → frame/line boundary strobes                             │
  │  · FIFO level flags:  overflow  ──▶ dropped data, the usual cause of tears │
  │                       underflow ──▶ link starved                           │
  │  · ECC / CRC errors on CSI-2 packets                              [INF]    │
  └───────────────────────────────────┬────────────────────────────────────────┘
                                      ▼
  ┌── FRAME BUFFER CONTROLLER (group B) ───────────────────────────────────────┐
  │  · "buffer N complete" ──▶ rotate the triple buffer                        │
  │  · "buffer full"       ──▶ in frame-capture mode, kicks off the FX3 burst  │
  │  · backpressure to the receiver if the host is not draining                │
  └───────────────────────────────────┬────────────────────────────────────────┘
                                      ▼
  ┌── FX3 / GPIF II (group C) ─────────────────────────────────────────────────┐
  │  · 14 configurable control pins carry handshakes between FPGA and FX3 [DS] │
  │  · DMA channel completion                                                  │
  └───────────────────────────────────┬────────────────────────────────────────┘
                                      ▼
  ┌── USB 3.0 / HOST ──────────────────────────────────────────────────────────┐
  │  · bulk transfer completion ──▶ driver callback ──▶ DevWare frame callback │
  │    ◀── this is the only "interrupt" application software ever sees         │
  └────────────────────────────────────────────────────────────────────────────┘

  ── side channels ───────────────────────────────────────────────────────────
   HDMI hot-plug detect ──▶ ADV7526 ──▶ I²C status / interrupt        [INF]
   I²C transaction complete ──▶ FX3 / FPGA I²C master status
   FPGA CONF_DONE ──▶ signals successful configuration from SPI EPROM [INF]
  ── outbound events (Demo3 → sensor) ────────────────────────────────────────
   SP[5:0] asserted by DevWare ──▶ trigger, shutter, standby, XSHUTDOWN
   HEAD_RESET_L ──▶ sensor hard reset
```

**Practical debug consequence:** a torn or dropped frame almost always originates at a FIFO overflow
in group A or at frame-buffer backpressure in group B — not in USB. If you see frame loss, check the
link rate against section 13 before you suspect the host.

---

## 13. Bandwidth budget — worked for the AR0544

Full resolution, 10-bit linear: 2592 × 1944 = **5,038,848 pixels per frame**.

At 60 fps that is 302.3 Mpixel/s, or **3.02 Gbps** of pixel payload before any blanking or packet
overhead. Walking that through the chain:

| Stage | Documented limit | Full-res 10-bit fps ceiling | Binding? |
|---|---|---|---|
| AR0544 MIPI TX | 2 × 1.72 Gbps = 3.44 Gbps | ~68 fps (sensor itself caps at 60) | no |
| **Demo3 MIPI RX** | **2 × 0.768 Gbps = 1.54 Gbps** | **~30 fps** | **yes** |
| Frame buffer input | 400 Mpixel/s | ~79 fps | no |
| **Frame buffer output** | **200 Mpixel/s** | **~39 fps** | second-tightest |
| FX3 GPIF II | 5 Gb/s | not binding | no |
| USB 3.0 link | 5 Gb/s raw; real-world FX3 throughput is lower **[INF]** | ~50–60 fps, marginal | maybe |

**The Demo3 MIPI receiver caps you at roughly 30 fps at full resolution** — and that is a
payload-only upper bound. Add CSI-2 packet overhead and horizontal/vertical blanking and the
achievable number is lower, call it mid-to-high 20s.

Ways to get useful data anyway:

| Approach | Effect |
|---|---|
| Run at 30 fps full resolution | Simplest. Roughly the honest ceiling. |
| Enable **DPCM 10 → 8** compression | 20% fewer bits → payload ceiling rises to ~38 fps |
| Use the **1080p crop** mode | 1920 × 1080 at 10-bit → ~74 fps payload ceiling; the sensor offers 110 fps in this mode, so Demo3 becomes the limit again but at a useful rate |
| Use a **binned / skipped / summed** mode | 648 × 486 is 16× smaller; bandwidth stops mattering entirely |
| Use **frame-capture mode** | Fill the 1 Gb buffer at full rate, then drain slowly. Gets you short bursts at true full speed. |

If you need sustained full-resolution 60 fps out of an AR0544, Demo3 is the wrong host. That is a
statement about a 2015-era evaluation board, not about the sensor.

---

## 14. Two documentation snags worth knowing

**1. Pin direction in `EVBUM2310/D` Table 1 is inconsistent.** Most entries are written from the
headboard's point of view — MIPI data is "Out" because it leaves the headboard, `MCLK` is "In"
because it enters the headboard. But `HEAD_RESET_L` is listed as "Out", which only makes sense from
Demo3's point of view. Cross-check against a headboard manual: `EVBUM2904/D` lists the same pin 31
as an input (`HB_RST_L`, direction `I`), and the AR0544 headboard schematic wires it into the
supervisor's `MR` input **[SCH]**. **The headboard-side reading is the correct one.**

**2. Pin 5 is documented as reserved but is not.** `EVBUM2310/D` calls pin 5 `S_RESERVED1`, "General
Reserved Signal 1". Both the AR1223 and AR0544 headboards use it as `DEMO_FB_CLK` — a frame-buffer
clock driven *from* the headboard **[SCH]**. If you are designing a headboard, do not treat pin 5 as
free.

---

## 15. Items to confirm before relying on them

| # | Item | Tag |
|---|---|---|
| 1 | Demo3's internal board rail voltages (FPGA core/I-O, FX3, DDR3, ADV7526) and their sequencing | **[INF]** — not in the public manual |
| 2 | The reference oscillator feeding the clock generator, and FX3's reference crystal | **[INF]** |
| 3 | Exact FPGA PLL structure and the DDR3 / HDMI / GPIF clock derivations | **[INF]** |
| 4 | Whether the headboard power switch is truly software-gated after enumeration, and in what order | **[INF]** — behaviour inferred from the block diagram and DevWare's observed flow |
| 5 | Real-world sustained FX3 / USB 3.0 throughput on your host | **[INF]** — varies by host controller and driver; measure it |
| 6 | CSI-2 ECC/CRC error reporting from the MIPI receiver, and how DevWare surfaces it | **[INF]** |
| 7 | HDMI hot-plug and ADV7526 interrupt handling | **[INF]** |
| 8 | Whether your Demo3 revision has the same 768 Mbps/lane MIPI limit | Check your board; the manual is rev 1, July 2020 |
