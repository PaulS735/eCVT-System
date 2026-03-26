# Knight Racing eCVT System -- Engineering Analysis

**Prepared for:** Baja SAE Competition Design Review
**Team:** Knight Racing
**Document Rev:** 2.0
**Date:** 2026-03-25

---

## Table of Contents

1. [Electrical Power Budget](#1-electrical-power-budget)
2. [Actuator Speed and Control Verification](#2-actuator-speed-and-control-verification)

---

## 1. Electrical Power Budget

### 1.1 System Overview

The eCVT electronics are powered by a 12 V alternator mounted to the Briggs & Stratton 10 hp engine. The alternator charges a **lead-acid battery**, which serves as the primary energy reservoir. All electronics draw from the battery, not directly from the alternator. Per Baja SAE rules, the **alternator output is limited to 18 A at 12 V** (216 W). A **20 A inline fuse** protects the main feed from the battery.

The power architecture is:

```
Alternator 12 V ──> Lead-Acid Battery 12 V ──┬── Linear Actuator (via relay H-bridge)
                                               │
                                               └── Buck Converter (12 V -> 5 V, 3 A rated, 85% eff.)
                                                    ├── Raspberry Pi 4B (USB-C, 5 V)
                                                    │    └── Teensy 4.1 (USB, 5 V from Pi)
                                                    │         ├── Hall Effect Sensor (3.3 V from Teensy LDO)
                                                    │         └── Mode Button (Pin 5, INPUT_PULLUP)
                                                    └── Relay Module Logic (5 V, optocoupler + coils)
```

> **NOTE — Alternator stator rating is unknown.** The alternator's actual continuous output capacity has not been measured or confirmed from a datasheet. All long-run energy balance conclusions in this document (Section 1.6) are **provisional** until the alternator's sustained output is verified to be ≥ average system draw. If the alternator cannot keep up with average load, the battery will discharge over the 4-hour endurance and the system will eventually brown out.

The LoRa RFM95W module is planned but not yet implemented; it is included in the budget for margin analysis.

### 1.2 Component Current Draw Summary

| Component | Supply | Typical Current (at supply V) | Peak Current (at supply V) | Notes |
|---|---|---|---|---|
| Linear Actuator (12V/152mm/2000N) | 12 V (from battery) | TBD (~4 A estimate) | TBD (~10--15 A stall estimate) | **VERIFY FROM DATASHEET** |
| Buck Converter | 12 V in | see downstream | see downstream | 85% efficiency |
| Raspberry Pi 4B | 5 V (from buck) | 1.0 A | 3.0 A | USB-C |
| Teensy 4.1 | 5 V (from Pi USB) | 0.10 A | 0.10 A | USB powered |
| Relay module logic | 5 V (from buck) | 0.050 A | 0.10 A | 2 relay coils + optocouplers |
| Hall effect sensor | 3.3 V (from Teensy) | 0.010 A | 0.010 A | A3144 or equivalent |
| Mode button | 3.3 V (Teensy pullup) | ~0 A | ~0 A | Momentary, internal pullup |
| LoRa RFM95W | 3.3 V (external reg) | 0.012 A RX | 0.120 A TX burst | Not yet implemented |

> All actuator current values in this document are estimates based on typical 12V/2000N actuators. The actual values depend on the specific actuator model and must be verified from its datasheet.

### 1.3 Buck Converter Load Analysis

All 5 V and 3.3 V loads are downstream of the buck converter. The Teensy's internal 3.3 V LDO draws from the 5 V USB rail, so the hall sensor current is included in the Teensy's 5 V draw.

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

**Typical operating current at 12 V (from battery):**

| Component | Calculation | I at 12 V (A) |
|---|---|---|
| Actuator (running, estimate) | Direct 12 V | ~4.000 |
| Buck conv. (typical 5 V = 1.15 A) | 1.15 x 5 / (12 x 0.85) | 0.564 |
| LoRa RX (future, 3.3 V, 12 mA) | 0.012 x 3.3 / (12 x 0.85) | 0.004 |
| **Total typical at 12 V** | | **~4.568 A** |

**Peak / worst-case current at 12 V (from battery):**

| Component | Calculation | I at 12 V (A) |
|---|---|---|
| Actuator (stall, estimate) | Direct 12 V | ~15.000 |
| Buck conv. (peak 5 V = 3.2 A) | 3.2 x 5 / (12 x 0.85) | 1.569 |
| LoRa TX burst (future) | 0.12 x 3.3 / (12 x 0.85) | 0.039 |
| **Total peak at 12 V** | | **~16.608 A** |

### 1.5 Margin Analysis

#### 1.5.1 Compliance Margin (18 A Alternator Rule)

The Baja SAE 18 A rule limits **alternator output**, not instantaneous battery discharge. This distinction matters:

- **Typical operation (4.57 A)** is well below the 18 A alternator limit. The alternator only needs to replenish what the battery delivers to the system on average.
- **Peak stall current (~16.6 A)** is sourced by the battery, not the alternator. The alternator is not capable of sourcing 16.6 A instantaneously — the battery absorbs the transient. This is the normal operating mode for any battery-buffered system.

| Parameter | Value | Limit | Margin | Status |
|---|---|---|---|---|
| Typical operating current | ~4.57 A | 18 A (alternator rule) | ~13.43 A (74.6%) | PASS |
| Typical operating current | ~4.57 A | 20 A (fuse) | ~15.43 A (77.2%) | PASS |
| Peak current (actuator stall) | ~16.61 A | 20 A (fuse) | ~3.39 A (17.0%) | PASS — battery-sourced transient |

#### 1.5.2 Safety Factor Analysis

If the team adopts a **1.5x safety factor** on the 18 A alternator rule, the design operating target becomes:

```
Design limit = 18 A / 1.5 = 12.0 A
```

| Parameter | Value | Design Limit (FoS 1.5) | Margin to Design Limit | Status |
|---|---|---|---|---|
| Typical operating current | ~4.57 A | 12.0 A | 7.43 A (62%) | PASS |
| Peak stall (battery transient) | ~16.6 A | 12.0 A | -4.6 A | DOES NOT MEET FoS 1.5 |

> The typical operating current meets FoS 1.5 with wide margin. The stall transient does not, but this is expected — stall is a fault condition, not a design operating point. The correct mitigation is the firmware stall timeout (5 seconds), which cuts actuator power before sustained overcurrent can occur. The 20 A fuse provides hardware backup.

#### 1.5.3 Alternator Output — Unknown

> **ACTION REQUIRED:** The alternator stator's continuous output rating is not known. All energy balance and 4-hour endurance conclusions depend on this number.
>
> - If alternator output ≥ ~5 A at 12 V: the battery stays charged indefinitely under typical load. **System is viable for endurance.**
> - If alternator output < ~4.57 A: the battery is net-discharging during operation. Runtime is limited by battery capacity. A 12 Ah battery at ~4.57 A average draw (minus alternator contribution) could last the 4-hour event if the deficit is small, but this must be calculated once the alternator spec is known.
>
> **Measure the alternator output under load** (at typical engine RPM with all electronics connected) before the endurance event. This is the single most important electrical validation item.

**Key observations:**

1. **Typical operation is within budget.** At ~4.57 A, the system uses 25.4% of the 18 A alternator limit. All electronics current values are sourced from datasheets (Pi, Teensy, hall sensor, relay module). The actuator running current (~4 A) is an estimate — verify from datasheet.

2. **Actuator stall is a battery-sourced transient.** The lead-acid battery can deliver the ~15 A stall spike directly without involving the alternator. The 18 A rule applies to alternator output, not instantaneous system draw. The 20 A fuse protects against sustained overcurrent. Firmware stall detection (5 second timeout) ensures the actuator is disabled before the transient becomes sustained.

3. **The 20 A fuse will not blow during normal stall transients.** Automotive blade fuses require sustained overcurrent to blow; a 20 A fuse typically survives transients of 30+ A for several seconds. A ~15 A stall lasting until the 5 s firmware timeout is within the fuse's I²t curve.

### 1.6 Thermal Viability for 4-Hour Endurance

> **NOTE:** This section is provisional. It depends on (a) the alternator being able to sustain average system draw and (b) the actuator's actual winding resistance, which is unknown.

**Total energy dissipated as heat (worst case continuous):**

The primary heat source is the buck converter and the actuator.

- Buck converter: At typical load (1.15 A at 5 V = 5.75 W output), input power is 5.75 / 0.85 = 6.76 W, so heat dissipated = 6.76 - 5.75 = **1.01 W**.
- Actuator: Winding resistance is **TBD** (unknown — not available without datasheet). Using a placeholder of ~1.0 ohm: P = I² x R = 16 x 1.0 = 16 W instantaneous. With estimated duty cycle of ~8.3% (slower actuator, ~1.75 s per shift, 2--4 shifts per minute), average heat ≈ **1.3 W**. **This value will change when the actual winding resistance is measured.**
- Relay contacts: At ~4 A through contacts rated for 10 A, negligible dissipation (< 0.2 W).

**Total continuous heat generation: approximately 2.5 W (provisional).**

At ~2.5 W continuous, thermal management is not a concern even if the real value is 2--3x higher. The electronics enclosure will reach a few degrees above ambient at most.

> **Conclusion:** The system is thermally viable for the 4-hour endurance race, but the actuator heat estimate must be revised once the actual winding resistance is known. Given the low overall dissipation, even a significant error in this estimate does not change the conclusion.

### 1.7 Power Budget Summary

```
  Typical 12 V draw:   ~4.57 A  ( ~55 W)   -- 25.4% of 18 A alternator limit
  Peak 12 V draw:      ~16.6 A  (~199 W)   -- battery-sourced transient, not alternator
  Buck converter load:   1.15 A  /  3.0 A   -- 38.3% of rated capacity (typical)
  Thermal dissipation:  ~2.5 W continuous    -- no active cooling needed (provisional)
  FoS 1.5 on 18A rule:  PASS at typical, DOES NOT MEET at stall (expected — stall is fault condition)
  Endurance viability:   PROVISIONAL — requires alternator output ≥ ~5 A (unverified)

  TBD items:
    - Actuator running current (estimated 4 A)
    - Actuator stall current (estimated 10-15 A)
    - Actuator winding resistance (estimated 1.0 ohm)
    - Alternator continuous output rating
```

---

## 2. Actuator Speed and Control Verification

### 2.1 Actuator Specifications

The actual actuator is a **12V, 6-inch (152mm) stroke, 2000N linear actuator** with built-in position feedback potentiometer. This is NOT the Actuonix PQ12-100-6-R micro-actuator referenced in early design documents.

| Parameter | Value | Status |
|---|---|---|
| Stroke | 152 mm (6 inches) | Known |
| Force rating | 2000 N (~450 lbf) | Known |
| No-load speed | TBD (~20 mm/s estimate) | **MEASURE OR FIND DATASHEET** |
| Rated-load speed | TBD (~12 mm/s estimate) | **MEASURE OR FIND DATASHEET** |
| Operating voltage | 12 V DC | Known |
| No-load current | TBD (~1 A estimate) | **VERIFY FROM DATASHEET** |
| Running current | TBD (~4 A estimate) | **VERIFY FROM DATASHEET** |
| Stall current | TBD (~10--15 A estimate) | **VERIFY FROM DATASHEET** |
| Feedback output range | TBD (assumed 0--5 V) | **MEASURE BEFORE TRUSTING DIVIDER MATH** |
| Winding resistance | TBD (~1.0 ohm estimate) | **MEASURE WITH MULTIMETER** |
| Control method | Bang-bang via relay H-bridge | Firmware-defined |

> **CRITICAL ACTION:** The team must obtain the actual datasheet OR physically measure no-load speed, loaded speed, running current, stall current, feedback voltage range, and winding resistance. Every calculated value in this section and in the power budget (Section 1) depends on these numbers. Until they are verified, all compliance conclusions are provisional.

### 2.2 Effective Stroke Per Shift Event

The eCVT does not use the full 152 mm stroke for each shift. The actuator positions correspond to discrete ratio presets along the CVT's sheave travel. Typical shifting moves the actuator between adjacent preset positions.

Each preset uses 7 breakpoints spread over the 1800--3900 RPM operating range. Actuator positions span approximately ADC 400--2700.

```
  Usable ADC range: 2700 - 400 = 2300 counts
  Physical stroke used: 2300 counts x 0.054 mm/count = ~125 mm of 152 mm total

  Position spacing = stroke_used / (N_positions - 1)
  For 7 positions over ~125 mm used:  125 / 6 ≈ 21 mm per step
```

**Typical per-shift stroke: 15--25 mm** (one adjacent breakpoint).

> Note: The 0.054 mm/count resolution assumes the feedback pot outputs 0--5 V over the full 152 mm stroke. If the actual feedback range is different (e.g., 0.5--4.5 V), this changes. Verify by measuring the feedback voltage at both hard stops before relying on this number.

### 2.3 Shift Time Calculation

> **ALL shift time values in this section are estimates based on an assumed rated-load speed of ~12 mm/s. This speed is UNVERIFIED. The actual speed could be anywhere from 5--50 mm/s depending on the actuator's internal gear ratio. Verify before drawing compliance conclusions.**

**Time to move between adjacent positions (estimated at 12 mm/s under load):**

```
  t = distance / speed

  For 15 mm step:  t = 15 / 12 = 1,250 ms (1.25 s)
  For 21 mm step:  t = 21 / 12 = 1,750 ms (1.75 s)
  For 25 mm step:  t = 25 / 12 = 2,083 ms (2.08 s)
```

**Time for full-stroke travel (worst case):**

```
  Full stroke at rated load:  t = 152 / 12 = 12,667 ms (~12.7 s)
  Full stroke at no load:     t = 152 / 20 =  7,600 ms (~7.6 s)
```

### 2.4 Compliance with Design Requirements

**SR_07: Shifting speed of 250 ms**

| Scenario | Estimated Time | Meets SR_07? |
|---|---|---|
| Adjacent position, rated load (21 mm) | ~1,750 ms | **TBD — likely NO at 12 mm/s** |
| Two-position jump, rated load (42 mm) | ~3,500 ms | **TBD — likely NO** |
| Full stroke, rated load (152 mm) | ~12,700 ms | **TBD — NO at any reasonable speed** |
| Full stroke, no load (152 mm) | ~7,600 ms | **TBD — NO** |

> **SR_07 compliance cannot be determined until actuator speed is measured.** Based on typical speeds for 2000N actuators (5--15 mm/s under load), SR_07 (250 ms) is almost certainly **not met** for a 21 mm step. Meeting 250 ms for a 21 mm step would require a loaded speed of ≥ 84 mm/s, which is unrealistic for a 2000N actuator.
>
> **The speed required for SR_07 compliance is:**
> ```
> v_min = 21 mm / 0.250 s = 84 mm/s under load
> ```
> This is the speed of a micro-actuator (like the PQ12), not a 2000N industrial unit.
>
> **Mitigation options:**
> 1. **Revise SR_07** to a realistic target for this actuator class (e.g., 2--3 seconds)
> 2. **Select a faster actuator** with lower force rating, if CVT sheave loads allow
> 3. **Measure actual CVT sheave loads** — if loads are well below 2000N, a smaller/faster actuator is viable
> 4. **Accept the tradeoff** — 2000N provides high reliability margin; slower shifting may be acceptable for endurance
>
> The team should measure the actual actuator speed to quantify the gap before deciding which option to pursue.

**SR_16: Command cycle time < 100 ms**

The command cycle time is the time from issuing a new target position to the control loop beginning actuator drive. This is distinct from mechanical travel time.

- The main control loop on the Teensy 4.1 runs continuously at the maximum rate of the processor (600 MHz ARM Cortex-M7). Each loop iteration completes in **microseconds**.
- The 50 ms print interval is for serial telemetry output only; it does not gate the control loop.
- ADC reads on the Teensy 4.1 take approximately 10--20 microseconds.
- Relay switching time (energize/de-energize): approximately 5--10 ms.

**Effective command cycle time: < 15 ms**, well within the 100 ms requirement.

> **Conclusion:** SR_16 is met with substantial margin. The firmware responds to RPM changes within milliseconds — the bottleneck is actuator mechanical speed, not control loop latency. This conclusion is firmware-based and does not depend on actuator specs.

### 2.5 Relay Deadtime Impact

The relay H-bridge uses a **75 ms deadtime** between switching directions. This is a safety interlock to prevent shoot-through (both relays energized simultaneously, shorting the 12 V supply through the actuator).

**Impact analysis:**

- The 75 ms deadtime only applies when the actuator **reverses direction**. During a single-direction shift (the common case), deadtime is zero.
- With estimated shift times of ~1,750 ms, the 75 ms deadtime is negligible (4.3% of shift time).
- Even if the actual actuator is faster than estimated, the deadtime only matters when the actuator must reverse direction during overshoot correction, not during normal shifts.

> **Conclusion:** The 75 ms relay deadtime has negligible impact on shift performance regardless of actuator speed. Shift time is dominated by actuator mechanical speed.

### 2.6 Voltage Divider and ADC Range Calculation

The actuator has a built-in feedback potentiometer assumed to output 0--5 V proportional to position over its 152 mm stroke. The Teensy 4.1 ADC accepts 0--3.3 V, so a voltage divider scales the signal.

> **UNVERIFIED ASSUMPTION:** The feedback pot output range is assumed to be 0--5 V. Many actuators output a narrower range (e.g., 0.5--4.5 V) to avoid rail saturation. **Measure the actual feedback voltage at both hard stops** before trusting the divider math or the ADC count range below. If the range is not 0--5 V, the divider values, ACT_POS_MAX, and position resolution all change.

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

At maximum actuator output (assuming 5 V):

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

**The usable ADC range is 0--2794, not 0--4095** (assuming 0--5 V feedback).

> **Firmware constant:** `ACT_POS_MAX` is set to 2800 in the firmware based on this calculation. This constant **must be re-validated** against the actual actuator's measured feedback range before deployment. If the feedback range is narrower (e.g., 0.5--4.5 V → divider output 0.225--2.028 V → ADC 279--2516), the usable range shrinks and ACT_POS_MAX must be lowered.

Position resolution (assuming 0--5 V feedback = 0--2794 ADC over 152 mm):

```
  Resolution = 152 mm / 2794 counts = 0.0544 mm/count
```

This gives approximately **18.4 counts per millimeter** of actuator travel -- good resolution for position control. This value changes if the feedback range is narrower than 0--5 V.

### 2.7 Deadband Analysis and Bang-Bang Control Justification

The control firmware uses a **bang-bang (on/off) relay control** with a **deadband of 50 ADC counts**. This section explains why this approach is adequate without PID control.

**Physical meaning of the deadband (assuming 0--5 V feedback, 152 mm stroke):**

```
  Deadband in mm = 50 counts x 0.0544 mm/count = 2.72 mm
```

> Note: The 2.72 mm deadband is based on the assumed 0--5 V feedback range. If the actual feedback range is narrower, the physical deadband changes proportionally. Recalculate once the feedback range is measured. The qualitative justification below remains valid regardless.

The actuator will stop driving once the measured position is within +/- 2.72 mm of the target. Over a 152 mm stroke, this is 1.8% of total travel.

**Why bang-bang control is adequate:**

1. **The actuator is slow relative to the control loop.** The control loop runs at ~MHz rates while the actuator moves at single-digit to low-tens mm/s under load. The loop can read the position and cut the relay many times during a single millimeter of travel. There is no risk of the actuator overshooting the target before the loop reacts.

2. **Relay control is binary by nature.** Relays are either on or off; they cannot provide proportional current control. PID output would need to be converted to PWM, which relays cannot follow at useful frequencies (relay mechanical response is ~5--10 ms, limiting effective PWM to < 50 Hz with severe wear). The 2000N actuator is a highly geared DC motor with very high mechanical impedance -- it does not benefit from high-frequency modulation.

3. **The deadband is mechanically insignificant.** The CVT sheave system has its own compliance, belt stretch, and mechanical backlash that far exceed ~3 mm of actuator precision. Positioning the actuator to +/- 3 mm is more precise than the mechanical system requires.

4. **Overshoot is bounded by actuator inertia.** When the relay cuts power, the actuator coasts to a stop within a fraction of a millimeter due to the high gear ratio typical of high-force linear actuators.

5. **Simplicity and reliability.** Bang-bang control has no tuning parameters beyond the deadband width. PID control would require gains tuned to the specific mechanical load, which varies with CVT position, belt tension, and engine speed. A mistuned PID controller can oscillate, causing relay chatter and premature wear. Bang-bang with an appropriate deadband is robust against all operating conditions.

**Comparison to PID:**

| Property | Bang-Bang + Deadband | PID + Relay |
|---|---|---|
| Steady-state error | < ~3 mm (deadband) | Potentially zero, but relay quantization limits this |
| Settling time | Fast (drive at full voltage) | Slower if gains are conservative |
| Oscillation risk | None (deadband prevents chatter) | High if poorly tuned |
| Relay wear | Minimal (one switch per move) | High (PWM-like switching) |
| Tuning required | None (set deadband once) | Three gains, load-dependent |
| Robustness | Excellent | Sensitive to plant changes |

> **Conclusion:** Bang-bang control with a 50-count deadband is the correct engineering choice for relay-driven actuator positioning in this application. The qualitative justification is independent of actuator specs. The exact physical deadband (currently estimated at 2.72 mm) should be verified once the feedback range is measured.

### 2.8 Control Timing Summary

```
  Control loop period:       ~microseconds (as fast as Teensy CPU allows)    [firmware — verified]
  ADC sample time:           10-20 us                                         [firmware — verified]
  Relay switching time:      5-10 ms                                          [hardware — verified]
  Relay deadtime (reversal): 75 ms                                            [firmware — verified]
  Telemetry print interval:  50 ms (does not gate control)                    [firmware — verified]
  Typical shift time:        TBD (estimated ~1,750 ms at 12 mm/s)            [UNVERIFIED — measure]
  Worst-case shift time:     TBD (estimated ~12,700 ms full stroke)          [UNVERIFIED — measure]
  Position resolution:       TBD (~0.054 mm/count if feedback is 0-5V)       [UNVERIFIED — measure]
  Deadband:                  TBD (~2.72 mm if feedback is 0-5V)              [UNVERIFIED — measure]
  SR_07 compliance:          TBD — likely NOT MET (see Section 2.4)
  SR_16 compliance:          PASS — < 15 ms command cycle time                [firmware — verified]
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
| FoS | Factor of Safety |
| ADC | Analog-to-digital converter |
| CVT | Continuously variable transmission |
| eCVT | Electronically controlled CVT |
| TBD | To be determined — requires measurement or datasheet |

## Appendix B: Open Items

| # | Item | Priority | How to Resolve |
|---|---|---|---|
| 1 | Actuator datasheet (speed, current, stall current) | **HIGH** | Find model number on actuator label; look up or contact supplier |
| 2 | Actuator feedback voltage range | **HIGH** | Measure voltage at both hard stops with multimeter |
| 3 | Actuator winding resistance | MEDIUM | Measure with multimeter across motor leads (actuator disconnected) |
| 4 | Alternator continuous output rating | **HIGH** | Measure output current at typical engine RPM under electrical load |
| 5 | Re-validate ACT_POS_MAX firmware constant | HIGH | Depends on item 2 |
| 6 | Re-evaluate SR_07 compliance | HIGH | Depends on item 1 |
| 7 | Revise thermal estimate | LOW | Depends on item 3 |

## Appendix C: References

- Linear actuator datasheet (12V, 152mm stroke, 2000N) — **TODO: obtain and verify**
- Baja SAE competition rules (current season)
- Raspberry Pi 4 Model B specifications
- Teensy 4.1 technical documentation (PJRC)
- Knight Racing Critical Design Review (CDR) requirements SR_07, SR_16
