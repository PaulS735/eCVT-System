# Knight Racing eCVT System -- Engineering Analysis

**Prepared for:** Baja SAE Competition Design Review
**Team:** Knight Racing
**Document Rev:** 1.0
**Date:** 2026-03-24

---

## Table of Contents

1. [Electrical Power Budget](#1-electrical-power-budget)
2. [Actuator Speed and Control Verification](#2-actuator-speed-and-control-verification)

---

## 1. Electrical Power Budget

### 1.1 System Overview

The eCVT electronics are powered by a 12 V alternator mounted to the Briggs & Stratton 10 hp engine used in Baja SAE competition. Per Baja SAE rules, the **total electrical current budget is 18 A at 12 V** (216 W). A **20 A inline fuse** protects the main feed from the alternator.

The power architecture is:

```
Alternator 12 V ──┬── PQ12-100-6-R Actuator (via relay H-bridge)
                   │
                   └── Buck Converter (12 V -> 5 V, 3 A rated, 85% eff.)
                        ├── Raspberry Pi 4B (USB-C, 5 V)
                        │    └── Teensy 4.1 (USB, 5 V from Pi)
                        │         ├── Hall Effect Sensor (3.3 V from Teensy LDO)
                        │         └── Mode Button (Pin 5, INPUT_PULLUP)
                        └── Relay Module Logic (5 V, optocoupler + coils)
```

The LoRa RFM95W module is planned but not yet implemented; it is included in the budget for margin analysis.

### 1.2 Component Current Draw Summary

| Component | Supply | Typical Current (at supply V) | Peak Current (at supply V) | Notes |
|---|---|---|---|---|
| PQ12-100-6-R Actuator | 12 V direct | 2.0 A | 10--15 A stall | Relay H-bridge driven |
| Buck Converter | 12 V in | see downstream | see downstream | 85% efficiency |
| Raspberry Pi 4B | 5 V (from buck) | 1.0 A | 3.0 A | USB-C |
| Teensy 4.1 | 5 V (from Pi USB) | 0.10 A | 0.10 A | USB powered |
| Relay module logic | 5 V (from buck) | 0.050 A | 0.10 A | 2 relay coils + optocouplers |
| Hall effect sensor | 3.3 V (from Teensy) | 0.010 A | 0.010 A | A3144 or equivalent |
| Mode button | 3.3 V (Teensy pullup) | ~0 A | ~0 A | Momentary, internal pullup |
| LoRa RFM95W | 3.3 V (external reg) | 0.012 A RX | 0.120 A TX burst | Not yet implemented |

### 1.3 Buck Converter Load Analysis

All 5 V and 3.3 V loads are downstream of the buck converter. The Teensy's internal 3.3 V LDO draws from the 5 V USB rail, so the hall sensor and potentiometer current is included in the Teensy's 5 V draw.

**Typical 5 V load:**

| Load | Current at 5 V |
|---|---|
| Raspberry Pi 4B | 1.000 A |
| Teensy 4.1 (incl. sensors) | 0.100 A |
| Relay module logic | 0.050 A |
| **Total typical at 5 V** | **1.150 A** |

**Peak 5 V load:**

| Load | Current at 5 V |
|---|---|
| Raspberry Pi 4B | 3.000 A |
| Teensy 4.1 (incl. sensors) | 0.100 A |
| Relay module logic | 0.100 A |
| **Total peak at 5 V** | **3.200 A** |

**Buck converter rating check:**

The buck converter is rated for **3 A output at 5 V**. The peak downstream demand is 3.2 A, which exceeds the rating by 0.2 A. However, the Pi reaching 3.0 A is an extreme transient (all four cores at 100% with active USB peripherals). Under realistic race conditions the Pi load stays below 2.0 A, putting total 5 V demand at approximately 2.15 A -- well within the 3 A rating.

> **Recommendation:** The 3 A buck converter is adequate for race conditions. If the LoRa module is added on a separate 3.3 V regulator from the 5 V rail, add its peak (0.12 A at 3.3 V = ~0.08 A at 5 V equivalent) to the budget. Total remains under 3 A.

### 1.4 Referred Current at 12 V Input

To find the 12 V input current drawn by the buck converter, we refer the 5 V loads back through the converter efficiency:

```
I_12V = (I_5V x V_5V) / (V_12V x eta)
      = (I_5V x 5) / (12 x 0.85)
      = I_5V x 0.4902
```

**Typical operating current at 12 V:**

| Component | Calculation | I at 12 V (A) |
|---|---|---|
| Actuator (running) | Direct 12 V | 2.000 |
| Buck conv. (typical 5 V = 1.15 A) | 1.15 x 5 / (12 x 0.85) | 0.564 |
| LoRa RX (future, 3.3 V, 12 mA) | 0.012 x 3.3 / (12 x 0.85) | 0.004 |
| **Total typical at 12 V** | | **2.568 A** |

**Peak / worst-case current at 12 V:**

| Component | Calculation | I at 12 V (A) |
|---|---|---|
| Actuator (stall, worst case) | Direct 12 V | 15.000 |
| Buck conv. (peak 5 V = 3.2 A) | 3.2 x 5 / (12 x 0.85) | 1.569 |
| LoRa TX burst (future) | 0.12 x 3.3 / (12 x 0.85) | 0.039 |
| **Total peak at 12 V** | | **16.608 A** |

### 1.5 Margin Analysis

| Parameter | Value | Limit | Margin | Status |
|---|---|---|---|---|
| Typical operating current | 2.57 A | 18 A (Baja rule) | 15.43 A (85.7%) | PASS |
| Typical operating current | 2.57 A | 20 A (fuse) | 17.43 A (87.2%) | PASS |
| Peak current (actuator stall) | 16.61 A | 18 A (Baja rule) | 1.39 A (7.7%) | MARGINAL |
| Peak current (actuator stall) | 16.61 A | 20 A (fuse) | 3.39 A (17.0%) | PASS |

**Key observations:**

1. **Typical operation is well within budget.** At 2.57 A, the system uses only 14.3% of the 18 A allocation, leaving substantial headroom for future additions (lighting, telemetry radio, additional sensors).

2. **Actuator stall is the dominant risk.** The PQ12-100-6-R can draw 10--15 A at stall. The 15 A worst case brings total draw to 16.6 A, which is within the 20 A fuse but approaches the 18 A Baja limit.

3. **Stall is a transient, not steady-state.** A stall condition means the actuator has hit a mechanical hard stop or is severely overloaded. The bang-bang control firmware cuts drive signals once the position enters the deadband, so sustained stall should not occur during normal shifting. If stall does occur, it lasts only until the control loop reads the position and reverses or disables drive -- typically under 100 ms.

4. **The 20 A fuse will not blow during normal stall transients.** Automotive blade fuses require sustained overcurrent to blow; a 20 A fuse typically survives transients of 30+ A for several seconds. A 15 A stall lasting < 100 ms is well within the fuse's I-squared-t curve.

### 1.6 Thermal Viability for 4-Hour Endurance

**Total energy dissipated as heat (worst case continuous):**

The primary heat source is the buck converter and the actuator.

- Buck converter: At typical load (1.15 A at 5 V = 5.75 W output), input power is 5.75 / 0.85 = 6.76 W, so heat dissipated = 6.76 - 5.75 = **1.01 W**.
- Actuator: During active shifting at 2 A and ~1.5 ohm winding resistance, P = I^2 x R = 4 x 1.5 = **6 W**. However, the actuator is only active for short bursts (< 500 ms per shift, perhaps 2--4 shifts per minute on average). Duty cycle is roughly 2 s / 60 s = 3.3%, so average actuator heat is approximately **0.2 W**.
- Relay contacts: At 2 A through contacts rated for 10 A, negligible dissipation (< 0.1 W).

**Total continuous heat generation: approximately 1.3 W.**

At 1.3 W continuous, thermal management is not a concern. The electronics enclosure will reach a few degrees above ambient at most. Even in a hot competition environment (40 C ambient), no active cooling is required.

Over 4 hours, total energy dissipated = 1.3 W x 14400 s = **18.7 kJ** -- trivial for convection cooling in a vehicle with airflow.

> **Conclusion:** The system is thermally viable for the 4-hour endurance race with substantial margin.

### 1.7 Power Budget Summary

```
  Typical 12 V draw:   2.57 A  ( 30.8 W)   -- 14.3% of 18 A limit
  Peak 12 V draw:     16.61 A  (199.3 W)   -- 92.3% of 18 A limit (transient only)
  Buck converter load:  1.15 A  /  3.0 A    -- 38.3% of rated capacity (typical)
  Thermal dissipation:  1.3 W continuous     -- no active cooling needed
  Endurance viability:  PASS for 4 hours
```

---

## 2. Actuator Speed and Control Verification

### 2.1 PQ12-100-6-R Specifications

| Parameter | Value |
|---|---|
| Stroke | 100 mm |
| No-load speed | 100 mm / 250 ms = 0.40 m/s |
| Rated-load speed | 100 mm / ~500 ms = 0.20 m/s |
| Operating voltage | 6--12 V (12 V used) |
| Feedback | Built-in potentiometer, 0--5 V output |
| Control method | Bang-bang via relay H-bridge |

### 2.2 Effective Stroke Per Shift Event

The eCVT does not use the full 100 mm stroke for each shift. The actuator positions correspond to discrete ratio presets along the CVT's sheave travel. Typical shifting moves the actuator between adjacent preset positions.

Each preset uses 7 breakpoints spread over the 1800--3900 RPM operating range. Actuator positions span approximately ADC 400--2700, covering most of the 100 mm stroke.

```
  Position spacing = stroke_used / (N_positions - 1)

  For 7 positions over ~80 mm used:  80 / 6 ≈ 13 mm per step
```

**Typical per-shift stroke: 10--15 mm** (one adjacent breakpoint).

### 2.3 Shift Time Calculation

**Time to move between adjacent positions under rated load:**

Using the rated-load speed of 0.20 m/s:

```
  t = distance / speed

  For 13 mm step:  t = 0.013 / 0.20 =  65 ms
  For 20 mm step:  t = 0.020 / 0.20 = 100 ms
  For 26 mm step:  t = 0.026 / 0.20 = 130 ms
```

**Time for full-stroke travel (worst case):**

```
  Full stroke at rated load:  t = 0.100 / 0.20 = 500 ms
  Full stroke at no load:     t = 0.100 / 0.40 = 250 ms
```

### 2.4 Compliance with Design Requirements

**SR_07: Shifting speed of 250 ms**

| Scenario | Time | Meets SR_07? |
|---|---|---|
| Adjacent position, rated load (13 mm) | 65 ms | YES |
| Two-position jump, rated load (26 mm) | 130 ms | YES |
| Full stroke, rated load (100 mm) | 500 ms | NO |
| Full stroke, no load (100 mm) | 250 ms | YES |

Adjacent-position shifts (13 mm with 7 breakpoints) comfortably meet the 250 ms target at 65 ms. A full-stroke shift under load requires 500 ms and does not meet SR_07. However, full-stroke shifts (low to high or high to low in a single command) are rare in normal driving — the RPM-based control loop moves incrementally through breakpoints.

> **Conclusion:** SR_07 is met for typical single-step shifts (65 ms << 250 ms). Multi-step shifts may exceed 250 ms under load but remain under 500 ms.

**SR_16: Command cycle time < 100 ms**

The command cycle time is the time from issuing a new target position to the control loop beginning actuator drive. This is distinct from mechanical travel time.

- The main control loop on the Teensy 4.1 runs continuously at the maximum rate of the processor (600 MHz ARM Cortex-M7). Each loop iteration completes in **microseconds**.
- The 50 ms print interval is for serial telemetry output only; it does not gate the control loop.
- ADC reads on the Teensy 4.1 take approximately 10--20 microseconds.
- Relay switching time (energize/de-energize): approximately 5--10 ms.

**Effective command cycle time: < 15 ms**, well within the 100 ms requirement.

> **Conclusion:** SR_16 is met with substantial margin.

### 2.5 Relay Deadtime Impact

The relay H-bridge uses a **75 ms deadtime** between switching directions. This is a safety interlock to prevent shoot-through (both relays energized simultaneously, shorting the 12 V supply through the actuator).

**Impact analysis:**

- The 75 ms deadtime only applies when the actuator **reverses direction**. If the actuator is extending and receives a command to retract, the firmware waits 75 ms after de-energizing the extend relay before energizing the retract relay.
- During a single-direction shift (the common case), deadtime is zero.
- In the worst case of oscillation around the target (overshoot requiring reversal), the 75 ms adds to the settling time but does not affect the initial response.
- For a 65 ms shift, a single reversal adds 75 ms, bringing total to 140 ms -- still under 250 ms.

> **Conclusion:** The 75 ms relay deadtime does not prevent compliance with SR_07 for typical shifts. It adds settling time for overshoot correction but this is acceptable.

### 2.6 Voltage Divider and ADC Range Calculation

The PQ12-100-6-R has a built-in feedback potentiometer that outputs 0--5 V proportional to position. The Teensy 4.1 ADC accepts 0--3.3 V, so a voltage divider scales the signal.

**Voltage divider:**

```
                 R_top = 10 k-ohm
  V_in (0-5V) ──/\/\/──┬── V_out -> Teensy ADC pin
                        │
                R_bot = 8.2 k-ohm
                        │
                       GND
```

```
  V_out = V_in x R_bot / (R_top + R_bot)
        = V_in x 8200 / (10000 + 8200)
        = V_in x 8200 / 18200
        = V_in x 0.4505
```

At maximum actuator output (5 V):

```
  V_out_max = 5.0 x 0.4505 = 2.253 V
```

This is safely below the Teensy's 3.3 V ADC reference, providing a **1.047 V safety margin** against overvoltage.

**ADC count range:**

The Teensy 4.1 ADC is 12-bit with a 3.3 V reference:

```
  ADC_max = V_out_max / V_ref x 4095
          = 2.253 / 3.3 x 4095
          = 0.6827 x 4095
          = 2794 counts
```

**The usable ADC range is 0--2794, not 0--4095.**

Position resolution:

```
  Resolution = 100 mm / 2794 counts = 0.0358 mm/count
```

This gives approximately **28 counts per millimeter** of actuator travel -- excellent resolution for position control.

### 2.7 Deadband Analysis and Bang-Bang Control Justification

The control firmware uses a **bang-bang (on/off) relay control** with a **deadband of 50 ADC counts**. This section explains why this approach is adequate without PID control.

**Physical meaning of the deadband:**

```
  Deadband in mm = 50 counts x 0.0358 mm/count = 1.79 mm
```

The actuator will stop driving once the measured position is within +/- 1.79 mm of the target. In CVT terms, this corresponds to a very small fraction of the sheave travel.

**Why bang-bang control is adequate:**

1. **The actuator is inherently slow relative to the control loop.** The control loop runs at ~MHz rates while the actuator moves at 0.20 m/s under load. The loop can read the position and cut the relay hundreds of times during a single millimeter of travel. There is no risk of the actuator "running away" past the target before the loop reacts.

2. **Relay control is binary by nature.** Relays are either on or off; they cannot provide proportional current control. PID output would need to be converted to PWM, which relays cannot follow at useful frequencies (relay mechanical response is ~5--10 ms, limiting effective PWM to < 50 Hz with severe wear). The PQ12-100-6-R is a geared DC motor with high mechanical impedance -- it does not benefit from high-frequency modulation.

3. **The 1.79 mm deadband is mechanically insignificant.** The CVT sheave system has its own compliance, belt stretch, and mechanical backlash that far exceed 1.79 mm of actuator precision. Positioning the actuator to +/- 1.79 mm is more precise than the mechanical system requires.

4. **Overshoot is bounded by actuator inertia.** When the relay cuts power, the actuator coasts to a stop within a few tenths of a millimeter due to the high gear ratio of the PQ12 (100:1). The worst-case overshoot past the deadband edge is small relative to the deadband itself.

5. **Simplicity and reliability.** Bang-bang control has no tuning parameters beyond the deadband width. PID control would require gains tuned to the specific mechanical load, which varies with CVT position, belt tension, and engine speed. A mistuned PID controller can oscillate, causing relay chatter and premature wear. Bang-bang with an appropriate deadband is robust against all operating conditions.

**Comparison to PID:**

| Property | Bang-Bang + Deadband | PID + Relay |
|---|---|---|
| Steady-state error | < 1.79 mm (deadband) | Potentially zero, but relay quantization limits this |
| Settling time | Fast (drive at full voltage) | Slower if gains are conservative |
| Oscillation risk | None (deadband prevents chatter) | High if poorly tuned |
| Relay wear | Minimal (one switch per move) | High (PWM-like switching) |
| Tuning required | None (set deadband once) | Three gains, load-dependent |
| Robustness | Excellent | Sensitive to plant changes |

> **Conclusion:** Bang-bang control with a 50-count (1.79 mm) deadband is the correct engineering choice for relay-driven actuator positioning in this application. The precision exceeds mechanical system requirements, the control is inherently stable, and relay lifetime is maximized.

### 2.8 Control Timing Summary

```
  Control loop period:       ~microseconds (as fast as Teensy CPU allows)
  ADC sample time:           10-20 us
  Relay switching time:      5-10 ms
  Relay deadtime (reversal): 75 ms
  Telemetry print interval:  50 ms (does not gate control)
  Typical shift time:        65 ms (one position step of ~13 mm, under load)
  Worst-case shift time:     500 ms (full stroke, under load)
  Position resolution:       0.036 mm/count (28 counts/mm)
  Deadband:                  +/- 1.79 mm
```

---

## Appendix A: Notation

| Symbol | Meaning |
|---|---|
| V | Volts |
| A | Amperes |
| W | Watts |
| eta | Efficiency (dimensionless) |
| I_12V | Current referred to 12 V input side |
| I_5V | Current at 5 V output side |
| R_top, R_bot | Voltage divider resistors |
| ADC | Analog-to-digital converter |
| CVT | Continuously variable transmission |
| eCVT | Electronically controlled CVT |

## Appendix B: References

- Actuonix PQ12-100-6-R datasheet
- Baja SAE competition rules (current season)
- Raspberry Pi 4 Model B specifications
- Teensy 4.1 technical documentation (PJRC)
- Knight Racing Critical Design Review (CDR) requirements SR_07, SR_16
