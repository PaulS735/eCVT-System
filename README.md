# eCVT System — Knight Racing Baja SAE

Teensy 4.1 firmware and data logging system for an electronically actuated CVT on a Baja SAE off-road race vehicle.

## Overview

This project replaces the passive mechanical CVT (Continuously Variable Transmission) on a Baja SAE buggy with an electronically controlled system. A Teensy 4.1 MCU reads engine RPM from a hall effect sensor, maps it to a target sheave position using tunable presets, and drives a 12V linear actuator via a relay H-bridge to reach that position.

A Raspberry Pi 4B logs all telemetry over USB Serial and (future) transmits live data to the pit via LoRa radio.

**Team:** Knight Racing — Deniz Tekin Kaya, Paul Shanklin, Brynn Caldwell, Asaf Reyes
**Competition:** Baja SAE
**Electrical Revision:** Rev 1.0, January 2026

## Hardware

| Component | Part | Connection |
|---|---|---|
| MCU | Teensy 4.1 (600MHz Cortex-M7) | USB to Pi |
| Hall Sensor | Unipolar (A3144 or equiv.) | Pin 2 (interrupt, INPUT_PULLUP) |
| Relay Module | Dual SPDT, optocoupler-isolated, active LOW | Pin 3 (FWD), Pin 4 (REV) |
| Linear Actuator | 12V, 152mm (6") stroke, 2000N with feedback | Relays (motor), Pin A1 (position feedback) |
| Mode Button | Momentary push button | Pin 5 (INPUT_PULLUP, cycles presets) |
| Data Logger | Raspberry Pi 4B | USB Serial from Teensy |
| Radio (future) | RFM95W LoRa 915MHz | Pi SPI bus |
| Power | 12V alternator → 20A fuse → buck converter (5V/3A) | |

### Power Budget

| | Typical | Peak (actuator stall) |
|---|---|---|
| 12V draw | 4.6A | 16.6A |
| 18A Baja limit | 25% used | 92% (transient only) |

## Firmware Architecture

### Control Loop (~50ms cycle)

1. **RPM measurement** — Interrupt-driven hall sensor, 1 pulse/rev, `FALLING` edge ISR, 4-sample rolling average
2. **Mode selection** — Debounced button on pin 5 cycles Economy → Sport → Aggressive
3. **Position feedback** — Read actuator position via ADC (voltage divider: 5V → 2.25V max)
4. **Target lookup** — 7-point piecewise linear interpolation from RPM (1800–3900) to actuator position
5. **RPM gating** — Below 1800 RPM, actuator holds retracted (engine not under load)
6. **Actuator drive** — Bang-bang relay control with 50-count deadband and 75ms direction-change deadtime
7. **Fault detection** — Feedback loss, actuator stall, implausible RPM (holds last valid reading)
8. **Telemetry output** — CSV over USB Serial at 9600 baud

### State Machine

```
INIT ──→ IDLE ──→ RUNNING ──→ IDLE (RPM timeout)
              │         │
              └─────────┴──→ FAULT ──→ FAIL_SAFE (relays off, latched)
```

### Fault Handling

| Fault | Severity | Response |
|---|---|---|
| Actuator feedback out of range | Critical | Latch fail-safe, kill relays |
| Actuator stall (5s no movement) | Critical | Latch fail-safe, kill relays |
| RPM > 4050 (implausible) | Warning | Hold last valid RPM, continue |

### Serial Output Format

```
{status},{timeDelta},{rpm},{torque},{actuatorPos},{preset}
```

- `status`: `1` = running, `0` = idle
- `timeDelta`: microseconds between hall pulses
- `rpm`: engine RPM (2 decimal places)
- `torque`: calculated lb-ft (2 decimal places)
- `actuatorPos`: ADC counts 0–4095
- `preset`: Economy / Sport / Aggressive

### Safety

- **Relay mutual exclusion**: Both relays HIGH (off) before any direction change. Both LOW simultaneously = dead short = fire.
- **75ms deadtime**: Enforced between any direction reversal.
- **Position clamping**: Software limits at ADC 100–2800 prevent over-extension.
- **Fail-safe latch**: Critical faults kill relays permanently until power cycle.
- **No `delay()`**: All timing uses `millis()`/`micros()` to keep the ISR responsive.

## File Structure

```
├── ECVT_Latest.ino          Teensy firmware (primary)
├── pi_logger.py             Raspberry Pi serial logger
├── graphRPM.py              Post-run data plotting (matplotlib)
├── state_machine.md         State machine documentation
├── FMEA.csv                 Failure Modes & Effects Analysis (45 entries)
├── power_budget_and_actuator_analysis.md
├── wiring_guide.md          Pin-level wiring reference
├── Critical Design Review.pptx
├── Old Code/
│   └── eCVT_Arduino_Demo.ino   Original prototype (reference only)
└── README.md
```

## Setup

### Teensy

1. Install [Teensyduino](https://www.pjrc.com/teensy/td_download.html)
2. Open `ECVT_Latest.ino` in Arduino IDE
3. Select Board: Teensy 4.1
4. Upload

### Raspberry Pi Logger

```bash
pip install pyserial
python3 pi_logger.py              # logs to datalog.txt
python3 pi_logger.py mylog.txt    # custom filename
```

### Post-Run Plotting

```bash
pip install matplotlib
python3 graphRPM.py
```

## Wiring Notes

- **Actuator white wire (position feedback) is 0–5V** over 152mm stroke — connect through voltage divider (10k + 8.2k) before Teensy A1. Direct connection will damage the ADC.
- **Relay module VCC is 5V** — coils need 5V from the buck converter, not Teensy 3.3V. Control pins (IN1/IN2) accept 3.3V logic fine.
- **Mode button** — wire between pin 5 and GND. Internal pullup handles the rest.
- **Hall sensor** — 3.3V supply from Teensy 3V3 pin. Open-drain output with internal pullup on pin 2.

## Future Work

- [ ] Secondary driven-shaft RPM sensor — needed to close the loop on actual CVT ratio (currently using engine RPM as proxy)
- [ ] Driver display (OLED/TFT on Teensy SPI/I2C) — speed, RPM, mode, faults
- [ ] LoRa telemetry to pit-side base station
- [ ] Alternator voltage monitoring (12V bus health)
- [ ] On-vehicle preset calibration during testing (7-point curves need bench + driving data)
- [ ] Temperature monitoring (CVT belt or engine)
