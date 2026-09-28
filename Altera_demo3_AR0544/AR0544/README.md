# AR0544 — onsemi 1/4.2-inch 5 MP CMOS Digital Image Sensor

Engineering notes on the AR0544's architecture, organised by functional group rather than by
data-sheet page order. Written for someone who has to bring the part up on a board and needs to
know what talks to what.

---

## 0. Scope, sources and how to read this

Everything here is derived from **publicly available** onsemi material:

| Source | What it gives |
|---|---|
| `AR0544-PD/D` rev. 12 (Feb 2026) — public data sheet | Block diagram, key parameters, rail names, mode table, ordering info |
| `AR0544_CSP47_Demo3Head` schematic rev 1.0 (18 Jan 2023) | **Ball-level pinout**, rail grouping, GPIO function options, clock/reset circuit |
| `EVBUM2904/D` (AR1223 D-PHY Demo3 headboard) | Jumper conventions shared across onsemi D-PHY headboards |
| `EVBUM2310/D` (Demo3 baseboard) | Host-side interface |

The **full AR0544 data sheet is released under NDA.** That means register addresses, PLL divider
ranges, and absolute timing numbers are *not* public. Wherever this document states something that
the public material does not directly confirm, it is tagged:

- **[DS]** — stated in public onsemi documentation
- **[SCH]** — read off the AR0544 Demo3 headboard schematic
- **[INF]** — inferred from the AR-family architecture; plausible, but **verify before you commit silicon**

Section 11 collects every **[INF]** item in one list so you can take it straight to your FAE.

---

## 1. Part identification

`AR0544` **C S S _ C/M/H _ 11/33 _ SMK _ A1-CP / A1-CP2 / A1-CR / AH3-GEVB`

| Field | Meaning |
|---|---|
| `C` / `M` / `H` | Colour filter array: RGB Bayer / Monochrome / RGB-IR **[DS]** |
| `11` / `33` | Chief ray angle, 11° or 33° **[DS]** |
| `A1-CP` | Chip-scale package, protective film |
| `A1-CP2` | Chip-scale package, protective film, low MOQ |
| `A1-CR` | Chip-scale package, no protective film |
| `AH3-GEVB` | **Demo3 headboard** — the sensor pre-mounted on an evaluation camera board |

Example: `AR0544CSSC11SMKAH3-GEVB` = 5 MP RGB, 11° CRA, on a Demo3 headboard. **[DS]**

Package: **ODCSP47**, 47 balls, 4.67 × 3.68 × 0.63 mm, 0.50 mm pitch. **[DS]**

---

## 2. Key parameters

| Parameter | Value |
|---|---|
| Optical format | 1/4.2-inch, 4:3 |
| Active array | 2592 H × 1944 V (2608 × 1960 including border pixels) |
| Pixel | 1.4 µm, stacked back-side illuminated (BSI) |
| ADC | 10-bit, on die |
| Interface | 2-lane MIPI D-PHY, max 1.72 Gbps per lane |
| Input clock | 6 – 48 MHz |
| Gain (linear mode) | 0 – 50.62 dB total: analog 0 – 27.37 dB, digital 0 – 23.25 dB |
| Compression | DPCM 10 → 8 |
| Analog / pixel supply | 2.8 V (2.7 – 2.9 V) |
| I/O supply | 1.8 V (1.7 – 1.9 V) |
| PLL / MIPI PHY supply | 1.05 V (1.0 – 1.1 V) |
| Power | 158 mW at 5 MP, 60 fps |
| Dynamic range | 73 dB (eDR, 1-exposure) / 100 dB (LI-HDR) |
| SNR_MAX | 39.9 dB |
| Responsivity | 8.7 ke⁻/lux·s (green, RGB) · 17.3 ke⁻/lux·s (clear, mono) |
| OTPM | 2360 bytes (shading coefficients + module info) |
| Junction temperature | −30 °C to +85 °C operating; 0 °C to +60 °C for optimal image quality |

All **[DS]**.

---

## 3. Functional grouping and top-level block diagram

The data-sheet block diagram splits the die into three lanes — *image sensor core*, *signal
processing*, *output*. That is a dataflow view. For board bring-up it is more useful to add four
more groups that cut across it: control, clocking, power, and event I/O. Seven groups total.

| Group | Contains | Why grouped |
|---|---|---|
| **A · Image sensor core** | Row driver, pixel array, analog signal chain, analog gain, 10-bit ADC, temperature sensor | Everything in the analog domain on `VAA_*`; noise-sensitive, needs the quietest rails |
| **B · Signal processing** | Data correction, digital gain, lens shading correction, test pattern generator | Pure digital pixel maths on `VDD_DIG_DCORE`; bypassable for raw characterisation |
| **C · Output** | FIFO, optional DPCM compression, MIPI D-PHY transmitter | Rate-matching + serialisation; the only high-speed group, own 0.4 V SLVS rail |
| **D · Control** | I²C target, OTPM, context switching, gain control, timing control | The register plane; everything the host touches |
| **E · Clocking** | EXTCLK input, PLL, clock dividers | Single clock source feeds every other group |
| **F · Power** | Nine rail groups across four voltages | Determines the power-up sequencer |
| **G · Event I/O** | `XSHUTDOWN`, `GPIO[1:0]`, `GPI[3:2]`, `TEST`, `ATEST[2:1]` | Asynchronous pins — reset, strobe, trigger, sync |

### 3.1 Dataflow (groups A → B → C)

```
                                    light
                                      │
  ┌───────────────────────────────────▼──────────────────────────────────────┐
  │ GROUP A · IMAGE SENSOR CORE                          rails: VAA_ANA_*     │
  │                                                                           │
  │   ┌────────────┐      ┌──────────────┐    ┌───────────┐   ┌────────────┐  │
  │   │ Row driver │─────▶│ Pixel array  │───▶│  Analog   │──▶│  10-bit    │  │
  │   │  (select,  │      │  2592 × 1944 │    │  signal   │   │    ADC     │  │
  │   │  reset,    │      │   1.4 µm BSI │    │  chain +  │   │  (on die)  │  │
  │   │  transfer) │      │  ERS  /  GRR │    │ an. gain  │   └─────┬──────┘  │
  │   └─────▲──────┘      └──────────────┘    └───────────┘         │         │
  │         │                                                       │         │
  │         │             ┌─────────────────────────┐               │         │
  │         │             │ Temperature sensor 10-b │──┐            │         │
  │         │             └─────────────────────────┘  │            │         │
  └─────────┼──────────────────────────────────────────┼────────────┼─────────┘
            │ row timing                               │ read via   │ pixels
            │                                          │ I²C        │
  ┌─────────┼──────────────────────────────────────────┼────────────▼─────────┐
  │ GROUP B · SIGNAL PROCESSING                        │  rails: VDD_DIG_*    │
  │         │                                          │                      │
  │   ┌─────┴──────┐   ┌──────────────┐  ┌───────────┐ │ ┌─────────────────┐  │
  │   │  Timing    │   │     Data     │─▶│  Digital  │─┼▶│  Lens shading   │  │
  │   │  control   │   │  correction  │  │   gain    │ │ │   correction    │  │
  │   └────────────┘   └──────▲───────┘  └───────────┘ │ │  (coeffs ← OTPM)│  │
  │                           │                        │ └────────┬────────┘  │
  │                    ┌──────┴───────┐                │          │           │
  │                    │ Test pattern │                │          │           │
  │                    │  generator   │                │          │           │
  │                    └──────────────┘                │          │           │
  └────────────────────────────────────────────────────┼──────────┼───────────┘
                                                       │          │
  ┌────────────────────────────────────────────────────┼──────────▼───────────┐
  │ GROUP C · OUTPUT                        rails: DVDD1V2PHY, EXT_0P4V_MIPI  │
  │                                                    │                      │
  │   ┌──────────────┐   ┌──────────────────┐   ┌──────▼─────────────────┐    │
  │   │     FIFO     │──▶│  DPCM 10 → 8     │──▶│  MIPI D-PHY TX         │    │
  │   │ (rate match) │   │  (optional)      │   │  2 data + 1 clock lane │    │
  │   └──────────────┘   └──────────────────┘   │  ≤ 1.72 Gbps per lane  │    │
  │                                             └───────────┬────────────┘    │
  └─────────────────────────────────────────────────────────┼─────────────────┘
                                                            │
                   ZP0/ZN0 (B6/A6) · ZP1/ZN1 (B4/A4) · CP/CN (B5/A5)
                                                            ▼
                                                    to host / receiver
```

### 3.2 Control, clock and event planes (groups D, E, G)

```
        SCL (C2) ──┐                             ┌── GPIO0 (D2)  FLASH strobe out
        SDA (A2) ──┤                             ├── GPIO1 (D3)  SHUTTER out /
                   │                             │               3D daisy-chain out
             ┌─────▼──────────────┐              │
             │  GROUP D · CONTROL │              ├── GPI2  (D4)  SADDR / trigger /
             │ ────────────────── │              │               standby   (input)
             │  I²C target        │◀────────────▶│
             │  (Fast-mode+)      │   registers  ├── GPI3  (B2)  3D daisy-chain in /
             │  OTPM 2360 B       │              │               trigger   (input)
             │  Context switching │              │
             │  Gain control      │              ├── XSHUTDOWN (E5)  hard reset
             │  Timing control    │              ├── TEST (C7)       test mode strap
             └─────┬──────────────┘              └── ATEST1 (E7) / ATEST2 (C1)
                   │                                      analog test taps
                   │ configures                  GROUP G · EVENT I/O
                   ▼
   EXTCLK (D5) ──▶ ┌───────────────────────┐
   6 – 48 MHz      │  GROUP E · CLOCKING   │──▶ vt_pix_clk  → groups A, B
                   │  PLL + dividers       │──▶ op_pix_clk  → group C
                   └───────────────────────┘
```

**Context switching** is worth calling out: the AR0544 holds two complete register contexts
(exposure, gain, window, frame rate) and can alternate between them frame by frame **[DS]**. That
is how LI-HDR T1/T2 and alternating-exposure schemes are driven without per-frame I²C traffic.

---

## 4. Pin map, grouped by function

Read off the AR0544 CSP47 headboard schematic **[SCH]**. 47 balls total.

### 4.1 Signal pins (11)

| Ball | Name | Dir | Group | Function |
|---|---|---|---|---|
| `D5` | `EXTCLK` | In | E | Master clock input, 6 – 48 MHz |
| `C2` | `SCL` | In | D | I²C clock, Fast-mode+ |
| `A2` | `SDA` | I/O | D | I²C data |
| `E5` | `XSHUTDOWN` | In | G | Active-low hard reset / shutdown |
| `C7` | `TEST` | In | G | Test-mode strap; tie for normal operation |
| `D2` | `GPIO0` | I/O | G | Default FLASH output; usable as input |
| `D3` | `GPIO1` | I/O | G | Default SHUTTER output; or 3D daisy-chain out |
| `D4` | `GPI2` | In | G | SADDR (2nd I²C address) / slave-mode trigger / standby |
| `B2` | `GPI3` | In | G | 3D daisy-chain in / trigger |
| `E7` | `ATEST1` | Analog | G | Analog test tap |
| `C1` | `ATEST2` | Analog | G | Analog test tap |

Note the asymmetry: **`GPIO[1:0]` are bidirectional, `GPI[3:2]` are input-only.** The Demo3
headboard nets are named `S_GPIO2` / `S_GPIO3`, which makes them look bidirectional — they are not.

### 4.2 MIPI pins (6)

| Ball | D-PHY name | C-PHY alias | Function |
|---|---|---|---|
| `B6` | `ZP0` | `A0` | Data lane 0, positive |
| `A6` | `ZN0` | `B0` | Data lane 0, negative |
| `B4` | `ZP1` | `B1` | Data lane 1, positive |
| `A4` | `ZN1` | `C1` | Data lane 1, negative |
| `B5` | `CP` | `C0` | Clock lane, positive |
| `A5` | `CN` | `A1` | Clock lane, negative |

The dual naming means the same six balls map to either **two D-PHY lanes + clock** or **two C-PHY
trios** (trio 0 = A0/B0/C0 = `B6`/`A6`/`B5`; trio 1 = A1/B1/C1 = `A5`/`B4`/`A4`). The headboard even
fits an `FSA646A` mux with a D-PHY/C-PHY select jumper **[SCH]**. But the public data sheet lists
**2-lane D-PHY only** — so treat C-PHY as unconfirmed unless your NDA data sheet says otherwise.

### 4.3 Power and ground pins (30)

| Rail group | Balls | Voltage | Feeds |
|---|---|---|---|
| `VAA_ANA_ACORE` | `E2`, `F7` | 2.8 V | Analog core, group A |
| `VAA_ANA_PIX` | `D1`, `F3`, `F4` | 2.8 V | Pixel array bias, group A |
| `VAA18_ANA_ACORE` | `D8`, `E3`, `F2`, `F6` | 1.8 V | Analog core, 1.8 V section |
| `VDDIO1V8[3:0]` | `B1`, `C3`, `C8`, `D6` | 1.8 V | All digital I/O buffers, group G + D |
| `VDD_DIG_DCORE` | `A3`, `B7`, `D7` | 1.05 V | Digital core, group B |
| `VDD_DIG_ACORE` | `E1`, `F5` | 1.05 V | Digital logic inside the analog block |
| `VDD_DIG_PLL` | `A8`, `B8` | 1.05 V | PLL, group E |
| `DVDD1V2PHY` | `A7`, `C4` | 1.05 V | MIPI D-PHY digital, group C |
| `EXT_0P4V_MIPI` | `B3` | 0.4 V | D-PHY SLVS common-mode reference, group C |
| `DGND` | `C5`, `C6`, `E6` | 0 V | Digital ground |
| `GND_DIG_ACORE` | `E4`, `E8` | 0 V | Digital-in-analog ground |
| `GND_ANA_ACORE` / `GND_ANA_PIX` | `F1`, `F8` | 0 V | Analog + pixel ground |

**Naming trap:** the net is called `DVDD1V2PHY` and the headboard net is `VDD-PHY`, but the
AR0544 Demo3 headboard actually regulates it to **1.05 V**, matching the data sheet's "PLL, MIPIphy
= 1.05 V" line **[DS] [SCH]**. Do not read 1.2 V into the pin name. Same story for the `+1V2_HB`
rail from Demo3, which feeds an on-board 1.05 V LDO or a select jumper.

---

## 5. Clock tree

### 5.1 Structure

Single clock source. Everything on the die is derived from `EXTCLK` through one PLL, so there are no
asynchronous clock domain crossings inside the sensor except the I²C interface, which is clocked by
the host's `SCL` and is independent of `EXTCLK`.

```
   ┌────────── on the camera board ──────────┐
   │  Y1  20 MHz oscillator      ─┐          │
   │  HB_MCLK from Demo3         ─┼─ P20 ────┼──▶ EXTCLK (D5)   6 – 48 MHz  [DS]
   │  SLAVE_CLK (multi-camera)   ─┘  select  │
   └─────────────────────────────────────────┘
                                                      │
   ═══════════════════════════════════════════════════╪═══════════════ AR0544 die
                                                      ▼
                                    ┌────────────────────────────────┐
                                    │ pre-PLL divider                │  [INF]
                                    └────────────────┬───────────────┘
                                                     ▼
                                    ┌────────────────────────────────┐
                                    │ PLL  ×N multiplier / VCO       │  powered by
                                    │                                │  VDD_DIG_PLL (A8,B8)
                                    └────────┬──────────────┬────────┘
                              video-timing   │              │   output
                                  branch     ▼              ▼    branch
                       ┌───────────────────────┐   ┌────────────────────────┐
                       │ vt system divider     │   │ op system divider      │  [INF]
                       └───────────┬───────────┘   └───────────┬────────────┘
                                   ▼                           ▼
                       ┌───────────────────────┐   ┌────────────────────────┐
                       │ vt pixel divider      │   │ op pixel divider       │  [INF]
                       └───────────┬───────────┘   └───────────┬────────────┘
                                   ▼                           ▼
                            ── vt_pix_clk ──             ── op_pix_clk ──
                                   │                           │
              ┌────────────────────┼──────────┐                ▼
              ▼                    ▼          ▼        ┌───────────────────┐
     row driver / ERS       ADC conversion  exposure   │ D-PHY byte clock  │
     line & frame timing    digital pipe    counters   │        ×8         │
     (groups A + B)                                    │ DDR serial clock  │
                                                       └─────────┬─────────┘
                                                                 ▼
                                                    CP/CN (B5/A5) + ZP/ZN lanes
                                                    ≤ 1.72 Gbps per lane  [DS]
```

The divider **names** follow the SMIA/AR-family convention and are **[INF]**. The *structure* — one
PLL feeding a video-timing branch and an output branch — is what every AR-series part does and is
implied by the data sheet's `PLL` block sitting between `EXTCLK` and both the timing control and the
MIPI blocks **[DS]**.

### 5.2 Clock domains

| Domain | Source | Consumers | Notes |
|---|---|---|---|
| `EXTCLK` | External oscillator | PLL only | Must be stable *before* `XSHUTDOWN` is released |
| `vt_pix_clk` | PLL, video branch | Pixel array, ADC, row timing, exposure | Sets frame rate and line time |
| `op_pix_clk` | PLL, output branch | FIFO read side, DPCM, D-PHY | Sets the link rate |
| D-PHY serial | op branch ×8, DDR | Lane serialisers | Half-rate DDR clock on `CP`/`CN` |
| `SCL` | Host | I²C target only | Asynchronous to everything above |

The FIFO in group C exists precisely because the video-timing branch and the output branch run at
different rates — it absorbs the difference between how fast rows come out of the array and how fast
the link drains them.

### 5.3 Board-level clock options

On the Demo3 headboard, header **P20** picks the source **[SCH]**:

| P20 | Source |
|---|---|
| `1-3` | On-board 20 MHz oscillator Y1 — **default** |
| `3-5` | Demo3-generated MCLK (`HB_MCLK`, connector pin 44) |
| `2-4` | Slave clock from another headboard (multi-camera slave) |
| `6-8` | Enable master clock output to drive a downstream slave |

All clock nets on the headboard swing at `+VDDIO_LS` = 1.8 V. Probe points: `TP8` = `S_CLK` (the
clock actually reaching the sensor), `TP9` = `FB_CLK`, `TP10` = `M_CLK`.

---

## 6. Power architecture and power sequencer

### 6.1 Rail tree

Four distinct voltages, nine rail groups. On the Demo3 headboard they are sourced like this **[SCH]**:

```
  Demo3 52-pin connector                on-board                      AR0544 balls
 ─────────────────────────      ───────────────────────      ──────────────────────────

  +2V8_VAA_HEAD  (pin 38) ─────────── direct ──────────────▶ VAA_ANA_ACORE   E2, F7
                           └────────── direct ──────────────▶ VAA_ANA_PIX     D1, F3, F4

  +1V8_HEAD      (pin 42) ─────────── direct ──────────────▶ VAA18_ANA_ACORE D8,E3,F2,F6

  +VDDIO_LS 1.8 V ────┐
                      ├── P16 1-2 (default) ────── VDD-IO ──▶ VDDIO1V8[3:0]   B1,C3,C8,D6
  +2V8_VDDIO_HEAD ────┘   P16 2-3 = 2.8 V I/O option
       (pin 48)

                          ┌── P98 1-2 (default) = use Demo3 +1V2_HB
  +1V2_HEAD      (pin 46) ┤                                  ┌▶ VDD_DIG_DCORE A3, B7, D7
                          └── P98 2-3 = U10 NCP59748 ────────┼▶ VDD_DIG_ACORE E1, F5
                                 on-board 1.05 V    VDD_SEL ─┼▶ VDD_DIG_PLL   A8, B8
                                                             └▶ DVDD1V2PHY    A7, C4

  +3V3_HEAD      (pin 47) ──▶ peripheral 3.3 V ──▶ U1 NCP135 ──▶ EXT_0P4V_MIPI  B3
                              (gates, EEPROM,       0.4 V LDO      (P1 selects internal
                               supervisor)          100 mA          LDO vs on-board)

  +5V0_HEAD      (pin 39) ──▶ +5V0 ──▶ power LED, FLASH header (not a sensor rail)

  VDDIO_SENSE    (pin 15) ◀── tells Demo3 which I/O level the headboard is running at
```

Every one of these ultimately comes from the **5 V USB bus** via Demo3's power distribution and its
headboard power switch. There is no separate barrel jack in the standard setup.

### 6.2 Current-measurement shunts

The headboard fits zero-ohm "cut-trace" shunts so you can break each rail and insert an ammeter
**[SCH]**: `JP2` (3.3 V peripheral), `JP3` (VDDIO_LS), `JP4` (VDD-IO), `JP7` (VDD), `JP8` (VAA),
`JP9` (VAA-PIX), `JP10` (VDD-PHY), `JP12` (VDD-PLL), `JP14` (VDD-ANA), `JP22` (VAA1V8). Cut the trace
on the bottom side, solder a header, and you can characterise per-domain power without guessing.

### 6.3 Power-up sequencer

**This is the part you must confirm with the NDA data sheet before laying out a product board.** What
is public is the *set* of rails and their voltages, not their mandated ordering.

What the Demo3 headboard actually does is simpler than a strict sequence: Demo3's headboard power
switch enables the connector rails together, the on-board LDOs settle, and the `ADM6711` supervisor
holds `XSHUTDOWN` low for 240 ms afterwards. So on the eval board, *sequencing is replaced by a
generous reset hold* **[SCH]**.

```
                 t0          t1          t2          t3               t4
                 │           │           │           │                │
 core 1.05 V    ▁▁▁▁╱▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔
 VDD_DIG_DCORE   │           │           │           │                │
 VDD_DIG_ACORE   │           │           │           │                │
 VDD_DIG_PLL     │           │           │           │                │
 DVDD1V2PHY      │           │           │           │                │
                 │           │           │           │                │
 1.8 V          ▁▁▁▁▁▁▁▁▁▁▁▁▁╱▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔
 VAA18_ANA       │           │           │           │                │
 VDDIO1V8        │           │           │           │                │
                 │           │           │           │                │
 2.8 V          ▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁╱▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔
 VAA_ANA_ACORE   │           │           │           │                │
 VAA_ANA_PIX     │           │           │           │                │
                 │           │           │           │                │
 0.4 V          ▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁╱▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔
 EXT_0P4V_MIPI   │           │           │           │                │
                 │           │           │           │                │
 EXTCLK         ▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁╱▔╲▁╱▔╲▁╱▔╲▁╱▔╲▁╱▔╲▁╱▔╲
                 │           │           │           │                │
 XSHUTDOWN      ▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁╱▔▔▔▔▔▔▔▔
                 │           │           │           │  ◀── 240 ms ──▶│
                 │           │           │           │                │
 I²C access     ─────────────────────────────────────────────────────────── OK ──▶
                                                                      │
                                                        first register write here
```

| Step | Action | Why |
|---|---|---|
| t0 | Bring up the **1.05 V core group** | **[INF]** — digital core and PLL first is the AR-family norm; it keeps the digital logic defined before analog bias exists |
| t1 | Bring up **1.8 V** (`VAA18_ANA`, `VDDIO1V8`) | I/O buffers get a defined level; analog 1.8 V section biases |
| t2 | Bring up **2.8 V** (`VAA_ANA_ACORE`, `VAA_ANA_PIX`) | Pixel and analog bias last, so no forward-biased ESD paths into an unpowered core |
| t3 | Bring up **0.4 V** `EXT_0P4V_MIPI` | D-PHY common-mode reference; only needed before streaming |
| t4 | Start `EXTCLK`, wait, **then release `XSHUTDOWN`** | The PLL needs a live reference at reset release |

The general principle behind the **[INF]** ordering: **lowest voltage first on the way up, reverse on
the way down.** That keeps every ESD diode between domains reverse-biased throughout the transition.
Power-down is the mirror image — assert `XSHUTDOWN`, stop `EXTCLK`, then drop 0.4 V → 2.8 V → 1.8 V →
1.05 V.

---

## 7. Reset sequencer

### 7.1 Reset types

| Type | Trigger | Effect |
|---|---|---|
| **Power-on reset** | Rails crossing threshold | Internal POR; on the headboard, augmented by the external supervisor |
| **Hard reset** | `XSHUTDOWN` (E5) driven low | Registers return to defaults, D-PHY lanes go to LP-11, streaming stops **[INF]** |
| **Soft reset** | I²C register write | Logic reset without losing the I²C link; register map returns to defaults **[INF]** |
| **Standby** | I²C, or `GPI2` configured as standby | Clocks gated, state retained **[DS]** — this is the low-power path, not a reset |

### 7.2 Reset chain on the Demo3 headboard

Three independent sources OR into one supervisor, and only the supervisor drives the sensor **[SCH]**:

```
                                                      +3.3 V
                                                        │
   HEAD_RESET_L ──▶ J1 pin 31 ──▶ HB_RST_L ──┐        ┌─┴──────────────┐
   (from Demo3 FPGA, asserted by DevWare)     │        │  U6  ADM6711   │
                                              ├───────▶│   MR          │
   SW1  manual push-button ───────────────────┤        │                │
                                              │        │   RESET ───────┼──▶ S_XSHUTDOWN_L
   internal POR (supply threshold) ───────────┘        │   240 ms pulse │        │
                                                       └────────────────┘        │
                                                                                 ▼
                                                                   ┌─────────────────────┐
   S_SP5 ──▶ J1 pin 26 ────── optional override ──────────────────▶│ XSHUTDOWN (E5)      │
   (Demo3 general control 5)   (populated on some headboards)      └─────────────────────┘

   probe points:  TP11 = HB_RST_L        TP12 = S_XSHUTDOWN_L
```

Pressing `SW1` produces a clean 240 ms low pulse on `XSHUTDOWN` — long enough that you never have to
reason about minimum reset width during bench work.

### 7.3 Reset release sequence

```
 rails valid    ▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔

 EXTCLK         ▁▁▁▁▁▁▁╱▔╲▁╱▔╲▁╱▔╲▁╱▔╲▁╱▔╲▁╱▔╲▁╱▔╲▁╱▔╲▁╱▔╲▁╱▔╲▁╱▔╲▁╱▔╲▁╱▔╲▁╱▔╲
                       │
                       │  ① clock must be running and stable first
                       │
 XSHUTDOWN     ▔▔▔▔╲▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁╱▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔
                        ◀──── ② hold ≥ 240 ms ──▶│
                                                 │
                                                 │◀── ③ internal boot ──▶│  [INF]
 I²C                   ── no access ─────────────────────────────────────│▶ writes OK
                                                                         │
                                                                         │ ④ load registers
                                                                         │   (or OTPM preset)
 D-PHY lanes   ──────────────── LP-11 (ultra-low-power) ─────────────────────────┤
                                                                                 │
                                                                                 │ ⑤ streaming
 frame output  ────────────────────────────────────────────────────────────── ▶  │ starts
```

| # | Step | Note |
|---|---|---|
| ① | `EXTCLK` running and stable | The PLL locks off this reference; releasing reset into a dead clock is the single most common bring-up failure |
| ② | Hold `XSHUTDOWN` low | 240 ms on the Demo3 headboard; the silicon minimum is in the full data sheet **[INF]** |
| ③ | Wait for internal boot / OTPM load | Do not hammer I²C immediately after release |
| ④ | Write the register set | Gain, exposure, window, frame rate, MIPI config, context settings |
| ⑤ | Enable streaming | Lanes leave LP-11, frame and line short packets begin |

When the sensor is in **software standby**, the MIPI signals drop to their ultra-low-power state at
nominally 0 V **[DS]** — a useful scope check that you really are in standby.

---

## 8. Interrupt and event architecture

The AR0544 has **no dedicated interrupt pin.** That is deliberate: it is a streaming device, and
"something happened" is conveyed either in-band on the MIPI link or on a repurposed GPIO. There are
four distinct event paths, and it helps to keep them separate in your head.

```
 ┌─────────────────────────────── EVENT SOURCES ───────────────────────────────┐
 │                                                                             │
 │  ① Wake on Motion            ② Frame / line boundaries                      │
 │     motion detector in the      start-of-frame, end-of-frame,               │
 │     WOM Bin4 / Bin4Skip2        start-of-line, end-of-line                  │
 │     low-power modes             + embedded data rows                        │
 │           │                             │                                   │
 │  ③ Exposure events           ④ External trigger in                          │
 │     integration start/stop      GPI2 / GPI3 asserted by the host            │
 │           │                             │                                   │
 └───────────┼─────────────────────────────┼───────────────────────────────────┘
             │                             │
 ┌───────────▼─────────────────────────────▼───────────────────────────────────┐
 │                             DELIVERY PATHS                                  │
 │                                                                             │
 │  path A · OUT-OF-BAND, hardware        path B · IN-BAND, on the MIPI link   │
 │  ───────────────────────────────       ──────────────────────────────────   │
 │                                                                             │
 │   GPIO0 (D2) ──▶ FLASH strobe          CSI-2 short packets:                 │
 │        asserted while the LED/            · Frame Start  (FS)               │
 │        illuminator should fire            · Frame End    (FE)               │
 │        → headboard P4 header              · Line Start / Line End           │
 │          (+5V0 / GND / FLASH / +3V3)                                        │
 │                                        Embedded data lines carry the        │
 │   GPIO1 (D3) ──▶ SHUTTER out              register state for the frame      │
 │        exposure-active indication         that was just sent                │
 │        → also the 3D daisy-chain                                            │
 │          transmit pin                  The receiver's frame-done            │
 │                                        interrupt fires off FE.              │
 │   WOM result ──▶ host wake             ← this is the real "interrupt"       │
 │        [INF] signalled on a GPIO          in a streaming system             │
 │        and/or a status register                                             │
 │                                                                             │
 │  path C · CONTROL-PLANE                path D · MULTI-SENSOR SYNC           │
 │  ──────────────────────────            ─────────────────────────────        │
 │   Status/flag registers polled          GPIO1 (out) ──▶ GPI3 (in) of the    │
 │   over I²C. No pin needed;              next sensor: 3D daisy chain.        │
 │   latency = poll interval.              Frame rate and exposure sync        │
 │                                         across a stereo / array rig. [DS]   │
 └─────────────────────────────────────────────────────────────────────────────┘
```

### 8.1 Wake on Motion — the closest thing to a real interrupt

WOM is the AR0544's low-power always-on mode. The sensor runs at 1 fps in a heavily binned mode,
watches for motion, and only then does the system need to wake **[DS]**:

| Mode | Resolution | fps | Streaming? |
|---|---|---|---|
| `WoM Bin4` | 648 × 486 | 1 | Yes — motion detection with image output |
| `WoM Bin4Skip2` | 324 × 243 | 1 | **No** — GB columns skipped to cut power; the stream output is unusable in this mode |

`WoM Bin4Skip2` is the interesting one architecturally: there is no image coming out, so the *only*
thing the sensor can tell you is "motion happened." **The exact signalling mechanism — dedicated GPIO
assertion, status register, or both — is not in the public data sheet.** This is **[INF]** and it is
the single most important thing to pin down if you are building a battery-powered always-on camera
around this part. See section 11.

### 8.2 Trigger modes

The part supports "various trigger modes for multi-sensor synchronisation" **[DS]** and both
**ERS** (electronic rolling shutter) and **GRR** (global reset release). GRR matters for triggered
capture: it resets every row simultaneously and then reads out rolling, which removes the
row-dependent exposure skew for a single flashed frame — at the cost of needing a controlled light
environment. Pair GRR with the `FLASH` output on `GPIO0` and you have a usable strobe capture.

On the headboard, the trigger path is header **P9** (`GPIO3 / TRIGGER`), default `3-5`, and Demo3's
`SP3` / `SP4` lines reach `GPI2` / `GPI3` through connector pins 30 and 32 **[SCH]**.

---

## 9. Operating modes

### 9.1 10-bit modes

| Mode | Description | Resolution | fps |
|---|---|---|---|
| Native 5 MP linear | Full resolution | 2592 × 1944 | 60 |
| LI native 5 MP | Line-interleaved HDR | 2592 × 1944 | 30 |
| Crop 1080p linear | Cropped window | 1920 × 1080 | 110 |
| SLP native 5 M | Super-low-power, full resolution | 2592 × 1944 | 1 |
| Bin4 0.3 MP | Binned, lowest power | 648 × 486 | 1 |
| WoM Bin4 | Wake on motion with streaming | 648 × 486 | 1 |
| WoM Bin4Skip2 | Wake on motion without streaming | 324 × 243 | 1 |

### 9.2 12-bit mode

| Mode | Description | Resolution | fps |
|---|---|---|---|
| eDR native 5 M | Enhanced dynamic range | 2592 × 1944 | 30 |

All **[DS]**.

### 9.3 Three dynamic-range strategies

The part gives you three different ways to get dynamic range, and they are not interchangeable:

- **Linear** — one exposure, 10-bit, 73 dB. Fastest, simplest, no artefacts.
- **eDR** — enhanced dynamic range, 12-bit output, 30 fps. Single exposure, so **no motion
  artefacts**, at the cost of half the frame rate.
- **LI-HDR** — line-interleaved T1/T2 readout, 100 dB. The sensor emits long and short exposures on
  alternating lines and an external ISP fuses them **[DS]**. Highest DR, but you need an ISP
  downstream and you inherit the usual multi-exposure motion artefacts.

Subsampling also differs by CFA: **skipping** works on RGB and mono, **binning** is RGB-only,
**summing** is mono-only **[DS]**. Summing is the right choice for low-light monochrome because it
adds signal; skipping just throws pixels away.

---

## 10. Bring-up checklist

1. **Short-check every rail to ground with all jumpers removed** before applying power.
2. Verify rail voltages at the shunt jumpers: 3.3 V, 1.8 V (VDDIO_LS), 1.8 V (VDD-IO), 1.05 V (VDD,
   VDD-PHY, VDD-PLL, VDD-ANA), 2.8 V (VAA, VAA-PIX), 0.4 V (VDD-SLVS). Tolerance ±3% **[SCH]**.
3. Scope `TP8` (`S_CLK`). You should see the selected clock at 1.8 V swing. If it is dead, check P20.
4. Scope `TP12` (`S_XSHUTDOWN_L`) while pressing `SW1`. Expect a 240 ms low pulse.
5. Confirm the I²C address. Default is set by the `SADDR` strap on `GPI2`; the lens-correction EEPROM
   sits separately at `0xA8` by default (header `P27`) **[SCH]**.
6. Read a known register over I²C before trying to stream. If I²C works but streaming does not, the
   problem is clock/PLL or MIPI configuration, not the board.
7. Check the D-PHY mux jumper is in **D-PHY** position (`1-2`) unless you have specifically
   confirmed C-PHY support.
8. Only then enable streaming.

---

## 11. Items to confirm against the full (NDA) data sheet

Every **[INF]** in this document, collected:

| # | Item | Why it matters |
|---|---|---|
| 1 | **Mandated power-up and power-down rail ordering, with max slew and inter-rail delay** | Section 6.3 gives a defensible generic order, not the specified one. Getting this wrong can forward-bias inter-domain ESD structures. |
| 2 | **Minimum `XSHUTDOWN` low time**, and minimum `EXTCLK` stable time before release | 240 ms on the eval board hides the real number. A product board will want to be much faster. |
| 3 | **Internal boot / OTPM load time** after reset release, before the first I²C write | Determines your driver's post-reset delay. |
| 4 | **Exact PLL divider names, legal ranges and VCO frequency limits** | Needed to compute a link rate for any `EXTCLK` other than the eval board's 20 MHz. |
| 5 | **Wake-on-Motion signalling mechanism** — dedicated pin, status register, or both; and latency | Decides the whole system architecture of an always-on camera. Critical for `WoM Bin4Skip2`, which has no image output at all. |
| 6 | **Soft-reset register address and semantics** | Section 7.1 asserts a soft reset exists by family convention. |
| 7 | **Whether C-PHY is actually supported** | The balls carry C-PHY aliases and the headboard fits a C-PHY-capable mux, but the public data sheet lists 2-lane D-PHY only. |
| 8 | **Full register map, context-switching registers, trigger mode list** | Not public in any form. |
| 9 | **Absolute maximum ratings and ESD ratings** | Not in the public brief. |
| 10 | **`DVDD1V2PHY` nominal voltage** | Pin name says 1.2 V, data sheet parameter table and the eval board both say 1.05 V. Confirm which is specified and what the tolerance is. |

