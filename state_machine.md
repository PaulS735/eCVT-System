# Knight Racing eCVT Firmware State Machine

**Platform:** Teensy 4.1
**Application:** Electronic Continuously Variable Transmission (eCVT) Control
**Competition:** Baja SAE

---

## 1. State Diagram

```
                         +------------------+
                         |                  |
                         |       INIT       |
                         |                  |
                         | - Configure pins |
                         | - Start serial   |
                         | - Attach ISR     |
                         | - Relays OFF     |
                         |   (both HIGH)    |
                         +--------+---------+
                                  |
                                  | (always, on boot)
                                  v
                    +-------------+--------------+
                    |                            |
                    |           IDLE             |
                    |                            |
                    | - Actuator holds/retracts  |
          +-------->| - Serial: "Idling"         |<---------+
          |         | - Waiting for hall pulse   |          |
          |         +-------------+--------------+          |
          |                       |                         |
          |  RPM timeout          | Valid hall              |
          |  (1s no pulse)        | pulse received          |
          |                       v                         |
          |         +-------------+--------------+          |
          |         |                            |          |
          |         |          RUNNING           |          |
          +---------+                            |          |
                    | - Hall ISR captures pulses |          |
                    | - Calculates RPM           |          |
                    | - Reads preset selector    |          |
                    | - Drives actuator to       |          |
                    |   target position          |          |
                    | - Telemetry every 50ms     |          |
                    +--------+-------+-----------+          |
                             |       |                      |
                Non-critical |       | Any fault            |
                fault clears |       | detected             |
                             |       v                      |
                             |  +----+-------------------+  |
                             |  |                        |  |
                             |  |         FAULT          |  |
                             +--+                        |  |
                                | NON-CRITICAL:          |  |
                                |  - Log warning         +--+
                                |  - Continue degraded     ^
                                |                          |
                                | CRITICAL:              (non-critical
                                |  - Actuator stopped     fault clears)
                                |  - Fault code every 1s
                                +----------+-------------+
                                           |
                                           | Critical fault latched
                                           v
                                +----------+-------------+
                                |                        |
                                |      FAIL_SAFE         |
                                |                        |
                                | - Both relays HIGH     |
                                | - No control output    |
                                | - Continuous fault     |
                                |   indication on serial |
                                | - Power cycle to reset |
                                +------------------------+
```

---

## 2. State Descriptions

### 2.1 INIT

The initialization state executes once during `setup()`. It performs all hardware configuration required before the control loop can operate.

| Action                  | Detail                                                        |
|-------------------------|---------------------------------------------------------------|
| Configure GPIO pins     | Set relay pins as OUTPUT, mode button as INPUT_PULLUP         |
| Start serial            | Initialize USB serial for telemetry and diagnostics           |
| Attach hall effect ISR  | Bind the hall sensor input pin to an interrupt on FALLING edge|
| Set relays to OFF state | Both relay outputs driven HIGH (active-LOW logic = OFF)       |

**Exit condition:** Transitions to IDLE unconditionally after all setup completes. This state is entered exactly once per power cycle.

---

### 2.2 IDLE

The system enters IDLE when the engine is not running or no valid RPM signal has been received. This is the default resting state after initialization and the fallback state during engine shutdown.

| Behavior                    | Detail                                                     |
|-----------------------------|------------------------------------------------------------|
| Actuator control            | Holds current position or retracts to minimum extent       |
| Serial output               | Reports "Idling" status at regular interval                |
| RPM monitoring              | Watches for first valid hall sensor pulse                   |

**Entry conditions:**
- From INIT on boot (always)
- From RUNNING when RPM timeout expires (1 second with no hall pulse)

**Exit condition:** Transitions to RUNNING when a valid hall effect pulse is received by the ISR.

---

### 2.3 RUNNING

The primary operating state. The control loop actively manages CVT ratio by driving the actuator to a target position derived from engine RPM and the selected performance preset.

| Behavior                    | Detail                                                     |
|-----------------------------|------------------------------------------------------------|
| RPM calculation             | ISR captures pulse timing; loop computes RPM               |
| Preset selection            | Button press cycles Economy / Sport / Aggressive            |
| Actuator control            | Bang-bang control drives actuator toward target position    |
| Telemetry output            | Serial telemetry transmitted every 50 ms                   |

**Entry condition:** From IDLE when a valid hall pulse is received.

**Exit conditions:**
- Transitions to IDLE on RPM timeout (1 second with no hall pulse)
- Transitions to FAULT on any detected fault condition

See Section 4 for full control loop details.

---

### 2.4 FAULT

The fault state handles both recoverable and unrecoverable error conditions. Behavior depends on fault severity classification.

**Non-critical faults** are handled inline: a warning is logged, and the system continues operating with degraded behavior. The system effectively remains in or returns to RUNNING once the fault condition clears.

**Critical faults** halt actuator control and latch the system into a failure mode. The fault code is reported on serial every 1 second. The system is locked and cannot recover without a power cycle.

**Entry condition:** From RUNNING when any fault condition is detected.

**Exit conditions:**
- Non-critical: returns to RUNNING when fault condition clears on next evaluation cycle
- Critical: transitions to FAIL_SAFE (latched, no software exit)

---

### 2.5 FAIL_SAFE

A terminal state entered on any critical fault. Designed to bring the actuator to a safe, unpowered condition.

| Behavior                    | Detail                                                     |
|-----------------------------|------------------------------------------------------------|
| Relay state                 | Both relays forced HIGH (active-LOW OFF = actuator coasts) |
| Control output              | None; actuator is electrically disconnected from drive     |
| Serial output               | Continuous fault indication with fault code                 |
| Recovery                    | Manual power cycle required                                |

**Entry condition:** From FAULT when a critical fault is latched.

**Exit condition:** None. Power cycle required to restart the system.

---

## 3. State Transition Table

| #  | From State         | To State           | Trigger / Condition                          |
|----|--------------------|--------------------|----------------------------------------------|
| T1 | INIT               | IDLE               | Setup complete (unconditional, on boot)      |
| T2 | IDLE               | RUNNING            | Valid hall effect pulse received              |
| T3 | RUNNING            | IDLE               | RPM timeout (1 second with no hall pulse)    |
| T4 | RUNNING            | FAULT              | Any fault condition detected                 |
| T5 | FAULT (non-crit)   | RUNNING            | Fault condition clears on next check cycle   |
| T6 | FAULT (critical)   | FAIL_SAFE          | Latched immediately, no exit except power cycle |

---

## 4. Control Loop Detail (RUNNING State)

The following operations execute each iteration of `loop()` while in the RUNNING state.

### 4.1 RPM Measurement

1. **Hall effect ISR** fires on the **FALLING edge** of the sensor signal.
2. ISR captures the time delta between consecutive pulses using `micros()`.
3. The main loop copies the volatile ISR data with **interrupts temporarily disabled** to prevent torn reads.
4. The raw pulse delta is pushed into a **4-sample rolling average buffer**. This smooths out magnet bounce and marginal ISR triggers under vehicle vibration. At 3900 RPM (worst case), pulse period is ~15,385 µs; 4 samples add ~46 ms of latency, well within the 50 ms control interval.
5. RPM is calculated from the averaged delta as:

```
RPM = 60,000,000 / (avgDelta_us * magnetsPerRev)
```

6. If no pulse has been received for **1 second**, RPM is considered invalid and the system transitions to IDLE.
7. If RPM is below **1800** (RPM_MIN_CONTROL), the engine is not under load and the actuator holds at the retracted/low-ratio position. Control presets only apply in the **1800–3900 RPM** operating range.

### 4.2 Preset Selection

A momentary push button on **Pin 5** (INPUT_PULLUP, wired to GND) cycles through the three performance presets. Each press advances to the next mode with **200ms debounce** to reject contact bounce.

| Press Count (mod 3) | Preset      |
|----------------------|-------------|
| 0 (default on boot)  | Economy     |
| 1                     | Sport       |
| 2                     | Aggressive  |

Each preset defines a 7-point piecewise linear curve mapping engine RPM (1800–3900) to a target actuator position. A preset change is logged to serial when it occurs.

### 4.3 Actuator Position Feedback

The actuator's built-in position feedback potentiometer is read on analog input **A1** through a voltage divider. The raw ADC value represents the current actuator extension.

### 4.4 Target Position Calculation

1. The selected preset curve is evaluated at the current RPM using **piecewise linear interpolation** between defined breakpoints.
2. The resulting target position is **clamped** to the software limits `[ACT_POS_MIN, ACT_POS_MAX]` to prevent mechanical overtravel.

### 4.5 Actuator Drive (Bang-Bang with Deadband)

The actuator is driven through a relay H-bridge using bang-bang (on/off) control:

| Condition                                     | Action              |
|-----------------------------------------------|---------------------|
| Position error > +deadband (50 ADC counts)    | Drive EXTEND        |
| Position error < -deadband (50 ADC counts)    | Drive RETRACT       |
| Position error within deadband                | STOP (both relays HIGH) |

**Direction change protection:** A **75 ms deadtime** is enforced between direction reversals. Both relays are always set **HIGH** (OFF) before either is set LOW (ON) to prevent shoot-through current in the H-bridge.

**Relay logic:** Relays are **active-LOW**. HIGH = relay off (open circuit), LOW = relay on (closed circuit).

### 4.6 Telemetry Output

Every **50 ms**, the following data is transmitted over USB serial:

- Current RPM
- Selected preset name
- Target actuator position
- Actual actuator position
- Actuator drive direction
- Fault status (if any)

---

## 5. Fault Classification Table

| Fault Condition                   | Severity     | Detection Method                                         | System Response                                      |
|-----------------------------------|--------------|----------------------------------------------------------|------------------------------------------------------|
| Actuator feedback out of range    | CRITICAL     | ADC reading outside valid window (wire break or short)   | Actuator stopped, fault latched, enters FAIL_SAFE    |
| Actuator stall                    | CRITICAL     | Driving actuator but position unchanged for 3 seconds    | Actuator stopped, fault latched, enters FAIL_SAFE    |
| RPM implausible (> 4050 RPM)     | NON-CRITICAL | Calculated RPM exceeds requirement ceiling + noise margin | Reading rejected, last valid RPM retained            |

### Critical Fault Behavior
- Both relay outputs forced **HIGH** (actuator drive disabled)
- Fault code reported on serial every **1 second**
- System **locked** until manual power cycle
- No software path back to RUNNING

### Non-Critical Fault Behavior
- Warning message logged to serial
- System **continues operating** with degraded behavior
- Fault re-evaluated each loop iteration
- Returns to normal operation when fault condition clears
