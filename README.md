# camera design and schematic review

Two worked reviews of MIPI CSI-2 camera designs built around FPGAs. Each one starts from a published reference design or demo board, reads it as a specification rather than a tutorial, and then carries it forward into a complete design of its own.

The writing is organised by function rather than by schematic page or file tree, and every number is either traced to a datasheet or marked as an estimate.

---

## [`Lattice_TIDA010083/`](Lattice_TIDA010083/README.md) — a PoE machine-vision camera

TI's **TIDA-010083** is an isolated 802.3at powered device with a gigabit PHY in 27 × 27 mm. This review takes it apart, then designs the rest of the camera behind it: a **CrossLink-NX LIFCL-40** FPGA, an **AR0234CS** global-shutter sensor, DDR3L frame buffering and a GigE Vision output — end to end, from the reference design to the compliance plan.

| Part | Folder | What it covers |
|---|---|---|
| 1–2 | [`Lattice_TIDA010083/`](Lattice_TIDA010083/README.md) | The reference design read as a specification, then the system design that answers it — part selection, wiring, bandwidth and power budgets |
| 3 | [`FPGA/`](Lattice_TIDA010083/FPGA/README.md) | ~4,400 lines of Verilog-2001: CSI-2 receive, a 4-pixel-wide ISP, DDR3L frame buffer, RGMII MAC, network stack and GigE Vision |
| 4 | [`PCB/`](Lattice_TIDA010083/PCB/README.md) | Floorplan, 10-layer 2+6+2 HDI stack-up, impedance and length matching, via-in-pad, DFM, thermal, ESD and EMI |
| 5 | [`Hardware/`](Lattice_TIDA010083/Hardware/README.md) | Connector pinouts, net-class constraints, power budget, PDN analysis, BOM — all machine-readable |
| 6 | [`Optics/`](Lattice_TIDA010083/Optics/README.md) | What a 3.0 µm global-shutter pixel demands of a lens: Nyquist, MTF against f-number, chief-ray-angle matching |
| 7 | [`Mechanical/`](Lattice_TIDA010083/Mechanical/README.md) | Focus tolerance stack, thermal interface, sealing, the housing as a Faraday cage |
| 8 | [`Verification/`](Lattice_TIDA010083/Verification/README.md) | Bring-up ladder, production test, calibration order, EMC and compliance |

**17 diagrams**, all hand-drawn SVG, all in the folder of the part they belong to.

## [`Altera_demo3_AR0544/`](Altera_demo3_AR0544/demo3/README.md) — a CSI-2 / HiSPi capture demo

A review of onsemi's **AR0544** demo platform and an Intel/Altera FPGA implementation that receives both CSI-2 and HiSPi, decodes DPCM, and streams out over an FX3 slave FIFO or HDMI.

---

## Why it is organised this way

Each part answers the part before it and constrains the part after it. That is the argument the repository is making, and the folder structure is meant to make it visible:

- Part 2 chooses a 9.5 mm FPGA package so the camera fits a 29 mm housing. **Part 4 pays for it** in laser-drilled microvias and filled via-in-pad.
- Part 4 reserves the bottom side under the FPGA for a thermal land, which displaces the decoupling. **Part 5 proves that is affordable** — 36 mΩ against a 100 mΩ target.
- Part 2 chooses a 3.0 µm global-shutter pixel. **Part 6 shows that sets a 167 lp/mm Nyquist** and rules out most of the M12 lens catalogue.
- Part 6 gives a focus budget of ± 8.4 µm. **Part 7 shows the mechanical stack is ten times that**, which is why the sensor is on its own board in Part 4's floorplan.
- Every one of those decisions turns into a gate in **Part 8**.

Where a decision was made and later revised, both are recorded. Part 4 §9 lists four things it changed about Parts 1 and 2, including putting back an oscillator that Part 2 had elegantly deleted.

## What this is not

It is a design study, not a product. There is no schematic, no board file, no synthesis run, no simulation result, and no hardware. Each part ends with a section listing what it is missing, and those lists are accurate rather than modest — the RTL, for instance, carries an open defect that is written down rather than papered over.

---

## Sources

Derived from published material: TI design guide **TIDUEU3** and schematic **TIDM244**, the **DP83867IR/CR** datasheet (SNLS484J), the **CrossLink-NX** family datasheet (FPGA-DS-02049) and LIFCL-40 pinout (FPGA-SC-02018), the **AR0234CS** and **AR0544** datasheets, and the relevant IPC, IEC, CISPR, JEDEC and MIPI standards named in each part.
