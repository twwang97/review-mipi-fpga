# Optical design

**Part 6 of the TIDA-010083 review.** Parts 1 to 5 built a camera up to the cover glass. This part is about what happens in front of it, and it is the part a camera hardware engineer is most likely to be asked about and least likely to have written down.

The sensor was chosen in Part 2 for its global shutter and its frame rate. Those are electrical arguments. They also set a Nyquist frequency, an image circle and a chief-ray angle, and between them those three numbers eliminate most of the M12 lens catalogue.

![Optical chain](diagrams/15-optical-chain.svg)

---

## 1. What the sensor demands

| Property | Value | Consequence |
|---|---|---|
| Active array | 1920 × 1200 | — |
| Pixel pitch | 3.0 µm | **Nyquist = 167 lp/mm** |
| Active diagonal | **6.79 mm** | image circle ≥ 6.8 mm |
| Optical format | 1/2.6 inch | most "1/3 inch" M12 lenses do not cover it |
| Shutter | global | no rolling-shutter geometry correction needed |
| CRA variants | 0° and 28° | the lens must be matched to the one you buy |

Two of those rows do most of the work.

**167 lp/mm is a demanding number.** It is the frequency at which the lens has to deliver contrast for the sensor to resolve anything at its own pixel pitch. Plenty of lenses sold as "5 megapixel" are characterised at 100 lp/mm and quietly collapse above it.

**6.79 mm is larger than it sounds.** The 1/3 inch format that dominates cheap M12 optics has a 6.0 mm diagonal. A 1/3 inch lens on this sensor vignettes the corners hard, and no amount of shading correction fixes geometry.

---

## 2. Focal length follows from the application, not the catalogue

For a working distance *WD* and a desired field of view *FOV* across the 5.76 mm sensor width, the thin-lens approximation gives

```
f ≈ sensor_width × WD / FOV
```

A 200 mm field at 150 mm working distance wants f ≈ 5.76 × 150 / 200 ≈ 4.3 mm. Pick the nearest stock focal length — 4 mm or 6 mm — then **re-derive the actual field and tell the application engineer what they are getting**, because it will not be 200 mm. This is the single most common source of "the camera doesn't see the whole part" at installation, and it is arithmetic, not optics.

---

## 3. Aperture — a narrower window than most people expect

Diffraction sets a hard ceiling on MTF at Nyquist. For an unobstructed circular aperture:

```
MTF(ν) = (2/π)[ arccos s − s√(1 − s²) ],   s = ν / νc,   νc = 1 / (λ·F#)
```

At λ = 550 nm and ν = 167 lp/mm:

| Aperture | Cutoff νc | Diffraction MTF at Nyquist |
|---|---|---|
| F/1.8 | 1010 lp/mm | 79 % |
| F/2.0 | 909 lp/mm | 77 % |
| F/2.8 | 649 lp/mm | 68 % |
| F/4 | 455 lp/mm | 54 % |
| F/5.6 | 325 lp/mm | 38 % |
| F/8 | 227 lp/mm | 16 % |
| **F/11** | **165 lp/mm** | **0 %** |

**F/11 is the diffraction cutoff for a 3.0 µm pixel.** The lens delivers literally zero contrast at Nyquist. Stopping down "to get more depth of field" destroys the resolution the sensor was bought for, and it is a reflex that has to be trained out of whoever installs the camera.

The usable window is **F/2 to F/4**. Wider and aberrations dominate; narrower and diffraction does. The window is narrow because the pixel is small, which is the price of 2.3 MP in a 1/2.6 inch format.

**Specify the lens properly.** The table above is a ceiling, not a specification — real aberrations subtract from it. Ask for MTF ≥ 30 % at 167 lp/mm on axis and ≥ 20 % at 0.8 field, and ask for the **measured curve**, not a "megapixel" rating, which is a marketing unit with no definition.

---

## 4. Chief-ray angle — the mistake that cannot be corrected later

The AR0234CS ships in 0° and 28° CRA variants. They differ in how far the microlens array is shifted outward relative to the photodiodes, and they are not interchangeable.

**The rule: |CRA_lens − CRA_sensor| ≤ 5° at maximum field.**

Beyond that the chief ray misses the shifted microlens and the corner loses illumination. A 10–15° mismatch typically costs 20–40 % corner signal, and on the colour variant it shifts hue as well, because the three colour planes lose different amounts.

**Flat-field correction does not rescue this.** Dividing a dark corner back up to nominal multiplies its shot noise by the same factor. You recover the brightness and lose the signal-to-noise ratio — which, for an inspection camera, is the thing you were paying for.

Two practical notes:

- **Ask for the CRA curve, not the number.** CRA varies with field height. A single headline figure at maximum field can hide a mismatch at 0.6 field, where most of the image lives.
- **A 0° CRA sensor needs a distant exit pupil**, which in practice means a larger, more telecentric lens. If the housing is 29 mm, that constrains you toward the 28° variant and a conventional compact M12 — so the sensor variant and the housing size are the same decision.

---

## 5. Monochrome or colour

Part 2 notes that monochrome is "usually the right choice for inspection" and is right, but the reason is worth having to hand:

| | Monochrome | Colour (Bayer) |
|---|---|---|
| Sensitivity | baseline | roughly half — the CFA absorbs light |
| Resolution at Nyquist | full | effectively half per colour plane, restored only by interpolation |
| ISP cost | no demosaic | demosaic, plus white balance and colour correction |
| Bandwidth | Mono8 or Mono10 | RGB8 is 3× the payload — see Part 2 §14 |
| CRA sensitivity | illumination falls off | illumination **and hue** shift |

Part 2 §14's bandwidth table already shows the last row biting: 1920 × 1200 debayered RGB8 falls to 17 fps on a gigabit link against 51 fps for Mono8. If the application does not need colour, colour costs a factor of three in frame rate and a factor of two in light.

---

## 6. Exposure, motion and the strobe

For a part moving across the field, the blur in pixels is

```
blur_px = v × t_exp / (FOV / 1920)
```

At a 200 mm field, one pixel is 0.104 mm of object:

| Belt speed | Exposure for 1 px of blur |
|---|---|
| 0.5 m/s | 208 µs |
| 1.0 m/s | **104 µs** |
| 2.0 m/s | 52 µs |

This is where the optical design hands the bill back to the electronics. A 100 µs exposure at F/2.8 on a 3.0 µm pixel needs a lot of light in a very short time, which means a strobe rather than continuous illumination — and the strobe is the 8.3 W of PoE headroom in Part 5 §4 finding its consumer.

The hardware for it already exists and is deterministic: the sensor's **FLASH** pin goes high for the exposure and drives the strobe directly, with no software in the latency path. Part 2 §13 sets this up; the reason it matters is here.

---

## 7. Focus — see Part 7

Depth of focus at F/2.8 with a one-pixel circle of confusion is **± 8.4 µm**. Every mechanical contributor between the photodiode and the lens flange is larger than that on its own. That calculation is in [Part 7](../Mechanical/README.md) because its conclusion is mechanical, not optical — but it is an optical requirement, and it is the reason the sensor sits on its own board.

---

## 8. What is still missing here

- **No lens has been selected.** This section says how to select one and what to reject; it does not name a part, because the field of view and working distance are application inputs that have not been fixed.
- **No optical simulation.** No ray trace, no through-focus MTF, no relative illumination curve, no distortion figure.
- **No illumination design.** Strobe geometry, wavelength choice, and whether it is co-axial, ring or bar — all of which change the lens requirement.
- **No filter decision.** An IR-cut filter is mandatory for colour and often wanted for monochrome consistency; a band-pass filter matched to the strobe wavelength is how machine-vision cameras reject ambient light, and it changes both the optical path length and the exposure budget above.
- **No distortion or calibration model.** If the camera measures rather than inspects, an intrinsic calibration (focal length, principal point, radial and tangential distortion) belongs in flash alongside the defect map.
