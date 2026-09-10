# eCVT System Changelog
Knight Racing Baja SAE — Teensy 4.1 Firmware & MATLAB Simulation

All changes are listed newest-first. Firmware changes reference line numbers in
`ECVT_Latest.ino`. Simulation changes reference `eCVT_Simulation.m`.

---

## [Unreleased] — 2026-09-10

### MATLAB Simulation — RPM_PROFILE Bug Fix & Run 3 Data

#### Bug: `RPM_PROFILE` undefined (runtime error)
When the TEST_SCENARIO selector block was written, `RPM_PROFILE` was accidentally
omitted from the base parameters section. This caused a MATLAB indexing error
(`Unable to index into 'RPM_PROFILE'`) on line 230 of the main loop.

**Fix:** Added `RPM_PROFILE` back to the base parameters section with a
representative 6-point profile:

| Segment | Time | RPM | Purpose |
|---------|------|-----|---------|
| Idle | 0–2 s | 800 | State machine stabilize |
| Ramp up | 2–35 s | 800→3900 | RPM crosses 1800 ~t=7s, actuator extends |
| Hold at peak | 35–60 s | 3900 | Steady-state tracking; preset switches at t=30/52 |
| Ramp down | 60–75 s | 3900→800 | **Exercises retract path** |
| Hold idle | 75–85 s | 800 | Confirms idle/RUNNING behavior at low RPM |

#### Root cause of Run 3 anomalies
Run 3 was executed after the RPM_PROFILE fix but with the wrong initial profile
(held at 3900 from t=35–85 s, never ramped down). This caused:
- **T2 = 95.5%** (vs 69.5% in Run 2) — artificially inflated; actuator parked at
  peak with no retract needed.
- **Relay retract = 0.0%** — retract relay never fired; no downward RPM to follow.

These results are recorded in `eCVT_Test_Results.xlsx` (Run 3 column, flagged `**`)
but should not be used as a T2 performance benchmark. Re-run with the corrected
`RPM_PROFILE` to get valid comparable data.

---

### MATLAB Simulation — TEST_SCENARIO Selector & Improved Fault Test Checks

#### TEST_SCENARIO selector (replaces manual scenario constants)
Added a single `TEST_SCENARIO` integer at the top of `eCVT_Simulation.m` that
configures all fault injection parameters automatically via a `switch` block.

| Value | Name | Faults active |
|-------|------|---------------|
| 0 | Standard (T1–T5, T8) | RPM spike at t=33.0s only |
| 1 | Feedback Fault (T6) | ADC wire break at t=25.0s, all others disabled |
| 2 | Actuator Stall (T7) | Mechanical freeze at t=20.0s, all others disabled |
| 3 | Full Fault Suite (T7+T8) | Spike at t=33.0s + stall at t=55.0s |

`SCENARIO_NAME` string is auto-derived and appears in:
- `Run parameters:` console block (new `Scenario:` line)
- Figure 1, 2, and 3 `sgtitle` titles

#### Improved T6 (feedback fault) test check
T6 now verifies three conditions instead of two:
1. `FAULT_ACT_FEEDBACK` was logged in `fault_arr`
2. System latched into `FAIL_SAFE` (`fs_mask` is non-empty)
3. **Both relays were off during the fail-safe period** (`relays_off`)

Console output now includes trigger timestamp (e.g. `triggered at t=25.03s`).

#### Improved T7 (stall fault) test check
T7 now verifies three conditions instead of one:
1. `FAULT_ACT_STALL` was logged in `fault_arr`
2. System latched into `FAIL_SAFE`
3. Both relays off during fail-safe period

Console output now includes trigger timestamp and elapsed time since the freeze
was injected (e.g. `triggered at t=25.04s (5.04s after freeze)`), confirming the
5 s stall timeout fired correctly.

---

### Firmware — RPM Spike Blind-Spot Documentation

**File:** `ECVT_Latest.ino`, rolling average section (~line 62)

Added a `DESIGN NOTE` comment explaining that `FAULT_RPM_IMPLAUSIBLE` cannot fire
when true RPM is below ~3700 RPM, because a single-sample spike is diluted by the
three real samples in the 4-sample average and the result cannot exceed
`RPM_MAX_VALID = 4050`. This is intentional (false-fault immunity under vibration)
but limits mid-range spike detection sensitivity. Recommended action at calibration
is documented in the comment.

---

### MATLAB Simulation — Power Band & Analysis Plots (Figure 2 & 3)

Added two additional figures to `eCVT_Simulation.m` that generate after the main
simulation figure.

#### Figure 2 — Power Band & CVT Analysis (6 subplots)
Requires two new configurable constants at the top of the power-band section:
- `CVT_RATIO_HIGH = 3.5` — estimated ratio at full retraction (PLACEHOLDER, calibrate)
- `CVT_RATIO_LOW  = 0.8` — estimated ratio at full extension  (PLACEHOLDER, calibrate)

| Subplot | What it shows | Why it matters |
|---------|---------------|----------------|
| P1 | Preset control laws: target position (counts & mm) vs RPM | Primary tuning reference; breakpoints annotated |
| P2 | Estimated CVT ratio vs RPM for each preset | Shows torque-multiplication vs speed-multiplication zones |
| P3 | **Output shaft torque vs engine RPM** (key tuning chart) | Directly shows torque available at the wheels for each mode |
| P4 | Output shaft RPM vs engine RPM | Shows vehicle speed potential for each preset |
| P5 | Actuator stroke utilization % vs RPM | Shows how much of the 152mm stroke each preset uses |
| P6 | Relay duty-cycle pie chart (from simulation run) | Shows extend/retract/deadband time split; high extend% means chasing |

#### Figure 3 — Preset Comparison at Breakpoints (2 bar charts)
- Bar chart of target position (counts & mm) for all 3 presets at all 7 breakpoint RPMs.
- Bar chart of estimated CVT ratio for all 3 presets at all 7 breakpoint RPMs.
- Side-by-side grouped bars make mode differences immediately visible.

#### Relay duty-cycle console output
Simulation now prints percentage of RUNNING time spent extending, retracting, and in
deadband after Figure 2 is rendered.

---

### MATLAB Simulation — Bug Fixes (based on initial test results)

**Source:** `Testing Matlab.docx` — first simulation run produced two test failures.

#### T1 FAIL — RPM measurement accuracy (max_err = 392.4 RPM)
**Root cause:** The RPM spike was injected at `t=20.5s` when true engine RPM ≈ 2885.
At that RPM one spike sample averaged with three real samples gives:
`(20797µs × 3 + 10909µs) / 4 = 20035µs → ~2995 RPM` — never exceeding `RPM_MAX_VALID`
(4050 RPM), so the 392 RPM measurement error was silently absorbed into the rolling
average without triggering a fault. This contaminated the T1 accuracy metric.

**Fix — `eCVT_Simulation.m`:**
- T1 test now excludes a ±2 s window around the spike injection time. The spike is
  intentional and is validated by T8; T1 is for steady-state measurement quality only.

#### T8 FAIL — RPM spike not caught by fault detection
**Root cause:** Same spike timing issue. Physics makes it mathematically impossible for
one spike sample to push the 4-sample rolling average above 4050 RPM when the true RPM
is only ~2885. Threshold cannot be crossed regardless of spike magnitude.

**Fix — `eCVT_Simulation.m`:**
- `FAULT_RPM_SPIKE_S` changed from `20.5` → `33.0` (true RPM ≈ 3900 at that time).
  At peak RPM one spike sample can tip the average: `(15385µs × 3 + 6000µs) / 4 =
  14266µs → 4207 RPM` → exceeds 4050 → `FAULT_RPM_IMPLAUSIBLE` triggered correctly.
- Spike magnitude increased from ~5500 RPM equivalent to ~10,000 RPM equivalent
  (delta = 6000 µs). Provides adequate margin above 4050 even if true RPM is slightly
  below 3900 at the moment of injection.

#### Firmware insight documented
The 4-sample rolling average intentionally absorbs single-pulse noise spikes, but this
means `FAULT_RPM_IMPLAUSIBLE` can only fire when the true RPM is already near the ceiling.
A spike at mid-range RPM will cause a brief measurement error without raising a fault.
To be noted during on-vehicle calibration.

---

## [fcdb871] — 2026-04-07

### Firmware — Four major additions to `ECVT_Latest.ino`

#### 1. Hardware Watchdog Timer
- **Lines:** 5–6, 429–433, 437
- Added `Watchdog_t4.h`; WDT1 configured with 500 ms timeout.
- `wdt.feed()` called at the top of every `loop()` iteration.
- On MCU hang: hardware resets, relays default HIGH (off) on boot → actuator stops safely.

#### 2. EMA Filter on Actuator Position ADC Reads
- **Lines:** 49–52, 109–111, 490–498
- Alpha = 0.15 gives ~300 ms settling time — smooths relay switching EMI and alternator
  ripple on the position feedback wire.
- Initialized from the startup calibration baseline so there is no cold-start transient.
- `actuatorPos` is always the integer-rounded filtered value throughout the control loop.

#### 3. RPM Rolling Average Buffer Fill Gate
- **Line:** 470
- `rpmValid` is now only set `true` once all 4 rolling-average buffer slots are populated.
- Prevents the first 1–3 pulses from producing unstable RPM readings averaged with fewer
  than 4 samples.
- Startup delay: ~133 ms at 1800 RPM, ~61 ms at 3900 RPM (within the 50 ms control loop
  tolerance).

#### 4. Position Rate-of-Change Fault (`FAULT_ACT_RATE`)
- **Lines:** 42–47, 78, 105–107, 303–313, 361, 503
- New critical fault: checks every 50 ms whether position feedback changed by more than
  150 ADC counts.
- 150 counts ≈ 14× the maximum real actuator speed (~11 counts per 50 ms at 12 mm/s),
  providing large margin against false positives from normal movement.
- Catches broken feedback wires (instant jump to 0 or 4095) and severe EMI spikes.
- Classified critical → latches into `FAIL_SAFE` state.

#### 5. Startup Feedback Calibration (`calibrateFeedback()`)
- **Lines:** 370–400, 426–427
- Takes 32 averaged ADC samples at boot (~16 ms) to establish a noise-free baseline.
- Initializes `emaActuatorPos`, `actuatorPos`, `lastActuatorPos`, and `prevPosForRate`
  from the real baseline (no assumed starting position).
- If baseline falls outside `[ACT_FEEDBACK_MIN=10, ACT_FEEDBACK_MAX=3000]`, immediately
  enters fail-safe and prints `CAL_FAIL,FEEDBACK_OUT_OF_RANGE,{value}` to serial.
- On success prints `CAL_OK,BASELINE,{value}` for logging on the Raspberry Pi.

---

## [32df573] — 2026-03-25

### Firmware — Actuator specification correction and power architecture

- Corrected actuator specs from PQ12 to: **12V / 152mm stroke / 2000N force**.
- Updated `ACT_POS_MAX` to reflect correct voltage divider ceiling (~2794 counts).
- Added battery to power architecture documentation; updated power budget accordingly.

---

## [4365560] — 2026-03-25

### Firmware — RPM averaging, range gating, and button mode selector

- Added 4-sample rolling average of hall pulse time deltas (`deltaBuffer[]`).
- Added `RPM_MIN_CONTROL = 1800` gate: below this RPM the actuator holds fully retracted
  (low ratio). Prevents CVT from engaging before the engine is under load.
- Added `RPM_MAX_VALID = 4050` implausible-RPM check (non-critical fault path).
- Replaced potentiometer preset selection with button-based cycling (`PIN_MODE_BTN = 5`):
  Economy → Sport → Aggressive → Economy with 200 ms debounce.

---

## [af3b81e] — 2026-03-25

### Firmware — Preset selection input change

- Preset selection moved from analog potentiometer to digital mode button.
- README updated to reflect new wiring and user interface.

---

## [dbdd5b2 / ee29bf1] — 2026-03-24

### Firmware — Initial release (`ECVT_Latest.ino`)

Complete firmware rewrite targeting Teensy 4.1 with relay H-bridge actuator control:

- Hall effect RPM sensing on Pin 2 (interrupt-driven, FALLING edge).
- Dual-relay H-bridge control on Pins 3 & 4 (active LOW, mutual exclusion enforced).
- 75 ms deadtime between direction reversals to protect relay contacts.
- Piecewise linear RPM→position preset curves (7 breakpoints, Economy/Sport/Aggressive).
- Bang-bang actuator control with ±50 ADC count deadband.
- Actuator position feedback via voltage divider on A1 (0–5V → 0–2.25V, 12-bit ADC).
- Fault detection: `FAULT_ACT_FEEDBACK` (wire break/short), `FAULT_ACT_STALL` (5 s no
  movement while driving), `FAULT_RPM_IMPLAUSIBLE` (non-critical, hold last valid RPM).
- Fail-safe latch: critical faults permanently disable relays until power cycle.
- Serial telemetry at 9600 baud over USB CDC, 50 ms cadence, CSV format.
- Full system documentation added: `README.md`, `state_machine.md`, `wiring_guide.md`,
  `power_budget_and_actuator_analysis.md`.

---

## 2026-09-10 — MATLAB Simulation Added

### New file: `eCVT_Simulation.m`

Hardware-out-of-loop simulation for development use while the physical system is being
built. Mirrors all firmware logic from `ECVT_Latest.ino`.

**Plant models:**
- Engine: first-order lag (τ = 0.5 s) responding to a configurable RPM profile.
- Actuator: velocity-integrated position model at 12 mm/s (220 counts/s); physical
  endstops enforced.
- Position sensor: Gaussian ADC noise (σ = 5 counts) + fault injection modes.
- Hall sensor: pulse accumulator with ±50 µs timing jitter.

**Firmware logic replicated (1:1 with firmware functions):**

| Firmware | Simulation |
|----------|------------|
| `hallISR()` + 4-sample rolling avg | Pulse accumulator + circular `rpm_buf[]` |
| `selectPresetFromButton()` | Debounced button events at configurable times |
| `getActuatorTargetForRpm()` | `fwGetTargetPos()` — same piecewise linear math |
| EMA filter (α = 0.15) | Identical update each timestep |
| `driveActuator()` + 75 ms deadtime | Bang-bang with `last_dir_chg_ms` guard |
| `checkFaults()` — all 4 fault types | Feedback range, rate-of-change, stall, RPM spike |
| Fail-safe latch | `fault_latched = true`, both relays forced off |
| RPM timeout (1 s) | `time_since_pulse_us >= RPM_TIMEOUT_US` |

**Outputs:**
- 7-panel figure (RPM, torque, position control, relay state, state machine, tracking
  error, CVT operating map).
- Console telemetry in firmware CSV format.
- Automated 8-test pass/fail report (T1–T8).

**Scenario controls (top of file):**
- `RPM_PROFILE` — arbitrary engine RPM vs time.
- `BUTTON_PRESS_TIMES_S` — simulate mode button presses.
- `FAULT_FEEDBACK_BREAK_S` — inject position sensor wire break.
- `FAULT_ACTUATOR_STALL_S` — inject mechanical jam.
- `FAULT_RPM_SPIKE_S` — inject single implausible RPM spike.
