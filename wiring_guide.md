# Knight Racing eCVT — Wiring and Interconnect Guide

**Revision:** 1.0
**Date:** 2026-03-24
**Team:** Knight Racing — Baja SAE

---

## Table of Contents

1. [System Block Diagram](#1-system-block-diagram)
2. [Power Distribution](#2-power-distribution)
3. [Teensy 4.1 Pinout Summary](#3-teensy-41-pinout-summary)
4. [Raspberry Pi 4B Connections](#4-raspberry-pi-4b-connections)
5. [Component Wiring Details](#5-component-wiring-details)
6. [Voltage Levels and Logic Summary](#6-voltage-levels-and-logic-summary)
7. [Connector and Wire Gauge Recommendations](#7-connector-and-wire-gauge-recommendations)
8. [Wiring Checklist](#8-wiring-checklist)

---

## 1. System Block Diagram

```
                        ALTERNATOR 12V
                             |
                        [20A FUSE]
                             |
              +--------------+--------------+
              |                             |
    [BUCK CONVERTER]               [DUAL RELAY MODULE]
     12V --> 5V, 3A                  COM1, COM2 = 12V
     ~85% efficiency                 VCC = 5V (from buck)
              |                      GND = common
     +--------+--------+            IN1 <-- Teensy Pin 3 (FWD)
     |                 |            IN2 <-- Teensy Pin 4 (REV)
     |                 |                |          |
  [Pi 4B]        [RELAY VCC]       NO1 (RED)   NO2 (BLACK)
  USB-C 5V       5V logic              |          |
     |                          [PQ12-100-6-R ACTUATOR]
  [USB-A]                         RED = motor +
     |                            BLACK = motor -
  [TEENSY 4.1]                    WHITE = position feedback
   5V via USB                        |
     |                          [VOLTAGE DIVIDER]
   3.3V LDO                     10kΩ + 8.2kΩ
     |                               |
  +--+--+                      Teensy Pin A1
  |     |
[HALL] [POT]
Pin 2  Pin A8
```

---

## 2. Power Distribution

### 2.1 12V Rail (Direct from Alternator)

```
Alternator (+) --> 20A Inline Fuse --> Junction Point
                                           |
                    +----------------------+----------------------+
                    |                                             |
             Buck Converter IN+                          Relay Module COM1
                                                         Relay Module COM2
```

- **Source:** Vehicle alternator, 12V nominal (11.5–13V under load)
- **Protection:** 20A inline blade fuse
- **Consumers on 12V direct:**
  - Linear actuator motor (through relay H-bridge): 2A typical, 10–15A stall
  - Buck converter input: draws ~0.56A typical at 12V

### 2.2 5V Rail (Buck Converter Output)

```
Buck Converter OUT+ (5V) --> Junction Point
                                  |
                  +---------------+---------------+
                  |                               |
           Pi 4B USB-C                   Relay Module VCC
           (5V, up to 3A)               (5V, ~50-100mA)
                  |
           Pi USB-A Port
                  |
           Teensy 4.1 USB
           (5V, ~100mA)
```

- **Source:** Buck converter, 5V regulated, 3A rated
- **CRITICAL:** The relay module VCC MUST be 5V, not 3.3V. The relay coils need 5V to energize reliably.
- **CRITICAL:** The Pi needs clean, stable 5V at ≥2.5A. Use a quality buck converter with low ripple.

### 2.3 3.3V Rail (Teensy Onboard Regulator)

```
Teensy 3V3 Pin --> Junction Point
                        |
                  +-----+-----+
                  |           |
            Hall Sensor    Potentiometer
            VCC (10mA)     CW terminal (1mA)
```

- **Source:** Teensy 4.1 onboard 3.3V LDO, 250mA max output
- **Total load:** ~11mA (well within 250mA capacity)
- **WARNING:** Do NOT power the LoRa module from this rail — it draws 120mA TX bursts and needs its own 3.3V regulator

### 2.4 Ground

```
ALL grounds connect to a single common point (star ground):

Alternator GND ----+
Buck Conv GND -----+
Relay Module GND --+---- COMMON GROUND POINT
Teensy GND --------+     (single terminal block
Pi GND ------------+      or bus bar)
Hall Sensor GND ---+
Pot CCW terminal --+
Actuator (via relay NO contacts)
```

- **CRITICAL:** Use star grounding. All ground wires meet at ONE point. Do not daisy-chain grounds — this prevents ground loops that cause ADC noise and serial communication errors.

---

## 3. Teensy 4.1 Pinout Summary

| Pin | Name | Direction | Connected To | Signal Type | Notes |
|-----|------|-----------|-------------|-------------|-------|
| **2** | PIN_HALL | INPUT_PULLUP | Hall effect sensor output | Digital, FALLING interrupt | 3.3V logic, open-drain sensor pulls LOW on magnet |
| **3** | PIN_RELAY_FWD | OUTPUT | Relay module IN1 | Digital, active LOW | HIGH = relay off, LOW = relay on (extend actuator) |
| **4** | PIN_RELAY_REV | OUTPUT | Relay module IN2 | Digital, active LOW | HIGH = relay off, LOW = relay on (retract actuator) |
| **A1** | PIN_ACT_POS | ANALOG IN | Actuator WHITE wire (through voltage divider) | Analog 0–2.25V | 12-bit ADC, 0–2794 counts usable range |
| **A8** | PIN_POT | ANALOG IN | Potentiometer wiper | Analog 0–3.3V | 12-bit ADC, 0–4095 counts, 3 preset zones |
| **LED_BUILTIN** | — | OUTPUT | Onboard LED | Digital | Blinks on hall pulse detection |
| **USB** | — | — | Pi USB-A port | USB CDC Serial | 115200 baud, also provides 5V power to Teensy |
| **3V3** | — | POWER OUT | Hall sensor VCC, Pot CW terminal | 3.3V regulated | Max 250mA from onboard LDO |
| **GND** | — | GROUND | Common ground bus | — | Multiple GND pins available, use any |

### Pin Cautions

- **ALL Teensy 4.1 GPIO pins are 3.3V only.** They are NOT 5V tolerant. Never connect a 5V signal directly to any Teensy pin.
- **Analog pins (A1, A8) do NOT need `pinMode()`.** The ADC configures them automatically on `analogRead()`.
- **Pin 2 is interrupt-capable.** Required for the hall effect ISR. Do not move the hall sensor to a non-interrupt pin.
- **Pins 3 and 4 are standard digital outputs.** Any digital pin could be used for relays, but these are chosen for physical routing convenience.

---

## 4. Raspberry Pi 4B Connections

| Port | Connected To | Purpose |
|------|-------------|---------|
| **USB-C (power)** | Buck converter 5V output | Power input, 5V @ ≥2.5A required |
| **USB-A #1** | Teensy 4.1 USB | Serial telemetry (115200 baud) + powers Teensy |
| **USB-A #2** | (Optional) USB drive | Backup log file storage |
| **GPIO SPI** | LoRa RFM95W (future) | MOSI=GPIO10, MISO=GPIO9, SCK=GPIO11, CS=GPIO8, DIO0=GPIO24, RST=GPIO25 |

- The Pi appears as the USB host. Teensy appears as `/dev/ttyACM0` on the Pi.
- Pi runs `pi_logger.py` which reads serial lines, timestamps them, and writes to `datalog.txt`.

---

## 5. Component Wiring Details

### 5.1 Hall Effect Sensor (A3144 or equivalent)

```
                  Hall Sensor
                  +--------+
  Teensy 3V3 --->| VCC    |
  Teensy GND --->| GND    |
  Teensy Pin 2 <-| OUT    |--- (open drain, pulled up internally by INPUT_PULLUP)
                  +--------+
```

| Wire | From | To | Color Suggestion |
|------|------|----|-----------------|
| VCC | Teensy 3V3 | Sensor VCC pin | Red |
| GND | Common ground | Sensor GND pin | Black |
| Signal | Sensor OUT pin | Teensy Pin 2 | White or Yellow |

**Behavior:**
- Sensor output is open-drain: it pulls LOW when a magnet is present, floats otherwise
- Teensy `INPUT_PULLUP` provides the pull-up to 3.3V
- At rest (no magnet): pin reads HIGH
- Magnet passes: pin goes LOW → FALLING edge triggers ISR

**Mounting:**
- Sensor face within 3mm of the neodymium magnet on the engine CVT sheave shaft
- One magnet = one pulse per revolution
- Secure with mechanical retention (bracket or epoxy + zip tie)

### 5.2 Potentiometer (10kΩ Linear Taper)

```
                  Potentiometer
                  +--------+
  Teensy 3V3 --->| CW     |  (clockwise terminal)
  Teensy A8  <---| WIPER  |  (center terminal)
  Teensy GND --->| CCW    |  (counter-clockwise terminal)
                  +--------+
```

| Wire | From | To | Color Suggestion |
|------|------|----|-----------------|
| High | Teensy 3V3 | Pot CW terminal | Red |
| Wiper | Pot center terminal | Teensy A8 | Yellow |
| Low | Common ground | Pot CCW terminal | Black |

**ADC Mapping (12-bit, 0–4095):**
- Full CCW: 0V → ADC 0 → Economy mode
- Mid: 1.65V → ADC ~2048 → Sport mode
- Full CW: 3.3V → ADC 4095 → Aggressive mode
- Zone boundaries: 1365 and 2730

### 5.3 Dual Relay Module (H-Bridge)

```
              RELAY MODULE
  +-----------------------------------------+
  |                                         |
  |  [RELAY K1 - FWD]    [RELAY K2 - REV]  |
  |                                         |
  |  IN1  IN2  VCC  GND  COM1 NO1 COM2 NO2 |
  +--+----+----+----+----+----+---+----+----+
     |    |    |    |    |    |   |    |
     |    |    |    |    |    |   |    |
  Pin3 Pin4  5V  GND  12V  |  12V   |
  (Teensy) (Buck) (Common) |  (fuse)|
                         ACT RED  ACT BLACK
```

| Terminal | Connected To | Notes |
|----------|-------------|-------|
| IN1 | Teensy Pin 3 | FWD relay control. Active LOW: LOW=on, HIGH=off |
| IN2 | Teensy Pin 4 | REV relay control. Active LOW: LOW=on, HIGH=off |
| VCC | Buck converter 5V | Relay coil power. MUST be 5V, not 3.3V |
| GND | Common ground | Logic ground |
| COM1 | 12V from fuse | Power input to relay 1 common |
| COM2 | 12V from fuse | Power input to relay 2 common |
| NO1 | Actuator RED wire | Motor terminal + (when K1 energized) |
| NO2 | Actuator BLACK wire | Motor terminal - (when K2 energized) |

**CRITICAL SAFETY RULES:**
1. **NEVER energize both relays simultaneously.** IN1 and IN2 must NEVER both be LOW at the same time. This creates a dead short across the 12V bus → relay destruction, potential fire.
2. **Default state is SAFE:** Both pins HIGH on boot = both relays off = actuator unpowered.
3. **Direction change sequence:** Always set BOTH pins HIGH first, wait 75ms minimum, then set ONE pin LOW.

**Direction Truth Table:**

| IN1 (Pin 3) | IN2 (Pin 4) | K1 State | K2 State | Actuator |
|-------------|-------------|----------|----------|----------|
| HIGH | HIGH | OFF | OFF | **Stopped** (coast) |
| LOW | HIGH | ON | OFF | **Extending** (FWD) |
| HIGH | LOW | OFF | ON | **Retracting** (REV) |
| LOW | LOW | ON | ON | **DEAD SHORT — NEVER DO THIS** |

### 5.4 Linear Actuator (PQ12-100-6-R)

```
  ACTUATOR
  +--------+
  | RED    |---> Relay NO1 (motor +)
  | BLACK  |---> Relay NO2 (motor -)
  | WHITE  |---> Voltage Divider ---> Teensy A1
  +--------+

  VOLTAGE DIVIDER (on White wire):

  Actuator WHITE (0-5V) ---[10kΩ]---+--- Teensy A1
                                     |
                                  [8.2kΩ]
                                     |
                                    GND
```

| Wire Color | Function | Connected To |
|------------|----------|-------------|
| RED | Motor positive | Relay module NO1 |
| BLACK | Motor negative | Relay module NO2 |
| WHITE | Position feedback (0–5V) | Voltage divider input |

**Voltage Divider:**

| Component | Value | Connection |
|-----------|-------|------------|
| R_top | 10kΩ resistor | Between WHITE wire and Teensy A1 |
| R_bot | 8.2kΩ resistor | Between Teensy A1 and GND |

- Output: V_out = V_in × 8.2k / (10k + 8.2k) = V_in × 0.4505
- At max (5V): V_out = 2.253V (safely below Teensy 3.3V max)
- ADC range: 0–2794 counts (12-bit)

**WARNING:** The WHITE wire outputs 0–5V directly from the actuator's internal potentiometer. Connecting WHITE directly to any Teensy pin WITHOUT the voltage divider will damage the Teensy's ADC permanently. Always verify the divider is in place before powering on.

**Position Mapping:**
- 0V (ADC 0) = Fully retracted
- 5V (ADC ~2794 after divider) = Fully extended
- Stroke: 100mm total

### 5.5 Buck Converter (12V → 5V)

| Terminal | Connected To |
|----------|-------------|
| VIN+ | 12V from fuse (post-fuse junction) |
| VIN- | Common ground |
| VOUT+ | 5V rail: Pi USB-C power, Relay module VCC |
| VOUT- | Common ground |

- **Rating:** 3A at 5V output, ~85% efficiency
- **Typical load:** 1.15A at 5V (38% of capacity)
- **Adjustment:** Trim output to exactly 5.0V before connecting Pi (Pi is sensitive to undervoltage)
- **Recommended:** Add 100µF electrolytic + 0.1µF ceramic on output for noise filtering

### 5.6 LoRa Module RFM95W (Future — Not Yet Wired)

Connected to Raspberry Pi GPIO (SPI bus):

| Module Pin | Pi GPIO | Function |
|-----------|---------|----------|
| MOSI | GPIO 10 | SPI data out |
| MISO | GPIO 9 | SPI data in |
| SCK | GPIO 11 | SPI clock |
| NSS (CS) | GPIO 8 | Chip select |
| DIO0 | GPIO 24 | Interrupt (packet ready) |
| RST | GPIO 25 | Module reset |
| VCC | External 3.3V regulator | NOT from Pi 3.3V pin (insufficient current) |
| GND | Common ground | — |

- **CRITICAL:** VCC must be 3.3V ONLY. Connecting 5V will destroy the module.
- **CRITICAL:** Needs its own 3.3V regulator (e.g., AMS1117-3.3 from 5V rail), NOT the Pi's GPIO 3.3V (limited to ~50mA).
- **Antenna:** 82mm quarter-wave whip wire. NEVER transmit without antenna connected.

---

## 6. Voltage Levels and Logic Summary

| Signal | Voltage Level | Type | Notes |
|--------|--------------|------|-------|
| Alternator output | 11.5–13V | Power | Varies with engine load |
| Post-fuse 12V rail | 12V nominal | Power | 20A fuse protected |
| Buck converter output | 5.0V regulated | Power | 3A max |
| Teensy 3.3V LDO | 3.3V regulated | Power | 250mA max |
| Hall sensor output | 0V or 3.3V | Digital (open-drain + pullup) | LOW = magnet present |
| Relay IN1/IN2 | 0V or 3.3V | Digital output from Teensy | LOW = relay ON (active LOW) |
| Potentiometer wiper | 0–3.3V | Analog | Linear with rotation |
| Actuator feedback (raw) | 0–5V | Analog | **NOT safe for Teensy directly** |
| Actuator feedback (divided) | 0–2.25V | Analog | Safe for Teensy ADC |
| USB Serial (Teensy↔Pi) | USB levels | Digital/Serial | 115200 baud |

---

## 7. Connector and Wire Gauge Recommendations

### Wire Gauges

| Circuit | Current | Recommended Gauge | Notes |
|---------|---------|-------------------|-------|
| Alternator to fuse | Up to 18A | 14 AWG minimum | Keep short, use ring terminals |
| Fuse to relay COM | Up to 15A (actuator stall) | 16 AWG | Route away from signal wires |
| Relay NO to actuator | Up to 15A (actuator stall) | 16 AWG | Match actuator wire gauge |
| Fuse to buck converter | ~1.5A max | 20 AWG | Adequate for buck input |
| Buck 5V to Pi | Up to 3A | 20 AWG | Keep under 12 inches for voltage drop |
| Buck 5V to relay VCC | ~100mA | 22 AWG | Low current logic supply |
| Teensy 3.3V to sensors | ~11mA total | 24–26 AWG | Short runs only |
| Signal wires (hall, pot, feedback) | <10mA | 24–26 AWG | Use shielded cable if EMI is a concern |

### Connector Types (Recommended)

| Application | Connector | Why |
|------------|-----------|-----|
| All power connections (12V, 5V) | Deutsch DT 2-pin | IP68 rated, vibration resistant, locking |
| Sensor connections (hall, pot) | Deutsch DT 3-pin or 4-pin | Same family, keyed to prevent mis-mating |
| Actuator (3-wire) | Deutsch DT 3-pin | Matches actuator wire count |
| Relay module headers | 0.1" Dupont with hot glue strain relief | Or solder directly if permanent |
| Pi USB-C power | Quality USB-C cable with strain relief | Tape or zip-tie to prevent disconnection |
| Teensy USB to Pi | Short USB micro cable with strain relief | Secure both ends |

### Harnessing

- **Bundle** power wires (12V, GND) separately from signal wires (hall, pot, feedback)
- **Split loom or braided sleeve** on all harness runs for abrasion protection
- **Adhesive-lined zip ties** every 150mm to secure harness to chassis
- **Minimum bend radius:** 4× wire diameter to prevent conductor fatigue
- **Route away from:** exhaust, moving parts, sharp edges, high-vibration mounting points
- **Drip loops** on any wire entering an enclosure (prevents water wicking in)

---

## 8. Wiring Checklist

Use this checklist when building the harness and during pre-event inspection:

### Before First Power-On

- [ ] 20A fuse installed in holder (not bypassed)
- [ ] Buck converter output verified at 5.0V (±0.1V) with multimeter before connecting Pi
- [ ] Voltage divider on actuator WHITE wire verified: measure divider output with 5V input, must read 2.2–2.3V
- [ ] Relay module VCC connected to 5V (not 3.3V)
- [ ] Both relay IN1 and IN2 float HIGH or are connected to Teensy (which defaults HIGH in firmware)
- [ ] Actuator RED → relay NO1, actuator BLACK → relay NO2 (not swapped)
- [ ] All grounds connected to single common ground point
- [ ] No exposed wire or solder joints — all connections insulated with heat shrink
- [ ] USB cable from Pi to Teensy is secure and strain-relieved

### Before Each Event

- [ ] All Deutsch connectors fully seated and locked
- [ ] No visible wire damage, chafing, or loose connections
- [ ] Fuse intact (not blown)
- [ ] Enclosure sealed, no water ingress from previous event
- [ ] Potentiometer knob turns freely through full range
- [ ] Hall sensor secure and within 3mm of magnet

### Functional Test (Engine Off)

- [ ] Power on system → both relay modules click OFF (default state)
- [ ] Turn pot full CCW → Serial prints "Preset: Economy"
- [ ] Turn pot to mid → Serial prints "Preset: Sport"
- [ ] Turn pot full CW → Serial prints "Preset: Aggressive"
- [ ] Read actuator position on Serial → value changes when actuator is manually pushed
- [ ] No "FAULT" messages on Serial at idle

### Functional Test (Engine Running)

- [ ] RPM reads non-zero on Serial when engine is running
- [ ] RPM reads zero (Idling) when engine is stopped
- [ ] Actuator moves in response to RPM changes
- [ ] Actuator stops when within deadband of target
- [ ] No relay chattering or buzzing
- [ ] Serial output is clean CSV at 115200 baud (no garbled characters)
