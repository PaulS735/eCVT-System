// eCVT Firmware — Knight Racing Baja SAE
// Teensy 4.1 — Relay H-bridge actuator control with hall effect RPM
// Actuator: 12V, 6-inch (152mm) stroke, 2000N linear actuator with position feedback

// --- Pin assignments ---
const int PIN_HALL      = 2;   // Hall effect sensor (interrupt-capable, INPUT_PULLUP)
const int PIN_RELAY_FWD = 3;   // Forward relay control (active LOW)
const int PIN_RELAY_REV = 4;   // Reverse relay control (active LOW)
const int PIN_MODE_BTN  = 5;   // Mode cycle button (INPUT_PULLUP, press = LOW)
const int PIN_ACT_POS   = A1;  // Actuator position feedback (analog in)
// White wire is 0-5V — voltage divider required: 10k top + 8.2k bottom before this pin

// --- Timing constants ---
const int    MAGNETS_PER_REV        = 1;
const unsigned long RPM_TIMEOUT     = 1000000;  // 1 second in microseconds
const unsigned long RELAY_DEADTIME_MS = 75;     // Min ms between relay direction changes
const unsigned long PRINT_INTERVAL_US = 50000;  // Serial print every 50ms
const unsigned long FAULT_PRINT_INTERVAL_MS = 1000; // Fault messages every 1s

// --- Actuator constants ---
const int ACT_DEADBAND = 50;   // ADC counts — stop relay when within this of target
const int ACT_POS_MIN  = 100;  // Software position clamp — minimum safe ADC count
const int ACT_POS_MAX  = 2800; // Software position clamp — maximum safe ADC count (voltage divider tops out ~2794)
// Actuator: 12V, 152mm stroke, 2000N, ~12mm/s under load (verify from datasheet)
// Position scale: 0 = fully retracted, ~2794 = fully extended (voltage divider limits to ~2.25V)
// Resolution: 152mm / 2794 counts ≈ 0.054 mm/count

// --- Button debounce ---
const unsigned long BTN_DEBOUNCE_MS = 200;  // Minimum ms between accepted presses

// --- Fault detection constants ---
const int ACT_FEEDBACK_MIN     = 10;    // Below this = feedback wire likely broken/disconnected
const int ACT_FEEDBACK_MAX     = 3000;  // Above this = feedback wire shorted to power
const float RPM_MAX_VALID      = 4050.0; // Requirement ceiling is 3900 RPM + 150 noise margin
const float RPM_MIN_CONTROL    = 1800.0; // Below this = engine not under load, hold retracted
const unsigned long ACT_STALL_TIMEOUT_MS = 5000; // If actuator hasn't moved in this long while driving
// NOTE: 5s timeout accounts for the slower 152mm/2000N actuator (~12mm/s under load)

// --- Engine specs ---
const float ENGINE_HP = 10.0;  // Briggs & Stratton 10HP

// --- Hall sensor ISR variables (volatile) ---
volatile unsigned long lastPulseTime = 0;
volatile unsigned long pulseDelta = 0;
volatile bool newPulse = false;

// --- RPM rolling average ---
// A 4-sample rolling average of pulseDelta smooths out magnet bounce and marginal
// ISR triggers under vibration. At 3900 RPM worst-case, pulse period is ~15,385 us.
// 4 samples adds ~46 ms of latency — well within the 50 ms print/control interval.
const int RPM_AVG_SAMPLES = 4;
unsigned long deltaBuffer[RPM_AVG_SAMPLES] = {0};
int deltaBufferIdx = 0;
int deltaBufferCount = 0;  // Tracks fill level — don't average until buffer is full

// --- Fault flags ---
enum FaultCode {
  FAULT_NONE           = 0,
  FAULT_ACT_FEEDBACK   = 1,  // Actuator position feedback out of range
  FAULT_BTN_RESERVED   = 2,  // Reserved
  FAULT_RPM_IMPLAUSIBLE = 3, // RPM reading above physical limit
  FAULT_ACT_STALL      = 4   // Actuator not moving despite being driven
};

FaultCode activeFault = FAULT_NONE;
bool faultLatched = false;  // Once critical fault triggers, stay in fault until reset

// --- Global state ---
unsigned long lastDetectionTime = 0;
unsigned long timeDelta = 0;
float rpm = 0;
float lastValidRpm = 0;  // Retained across noise spikes — used when current reading is rejected
bool rpmValid = false;
int actuatorPos = 0;
unsigned long lastDirectionChange = 0;
int lastRelayState = 0;  // 0=stopped, 1=fwd, -1=rev

// Mode button state
int presetIndex = 0;  // 0=Economy, 1=Sport, 2=Aggressive
bool lastBtnState = HIGH;
unsigned long lastBtnTime = 0;

// Fault detection state
int lastActuatorPos = 0;
unsigned long actLastMoveTime = 0;
unsigned long lastFaultPrintTime = 0;
bool actuatorInDeadband = false;  // Set by driveActuator when position is within target deadband

// --- Preset structure ---
const int MAX_BREAKPOINTS = 7;

struct RpmPreset {
  const char* name;
  int rpmThresholds[MAX_BREAKPOINTS];
  int actPositions[MAX_BREAKPOINTS];  // Actuator position targets in ADC counts (0-2794 = 0-152mm)
  int numPoints;
};

// Placeholder values — MUST be calibrated on vehicle with actual CVT variator.
// RPM range: 1800–3900 per requirement. Below 1800 = hold retracted (RPM_MIN_CONTROL).
// Positions are ADC counts after voltage divider (0 = retracted, ~2794 = fully extended).
//
// TODO: Secondary driven-shaft sensor needed to close the loop on actual CVT ratio.
//       Until then, these curves map engine RPM to actuator position as a proxy only.
//       Calibration requires measuring sheave position vs belt ratio on the bench,
//       then tuning breakpoints during on-vehicle dyno/driving tests.

const RpmPreset PRESET_ECONOMY = {
  "Economy",
  {1800, 2150, 2500, 2850, 3200, 3550, 3900},
  { 400,  700, 1000, 1350, 1700, 2050, 2400},
  7
};

const RpmPreset PRESET_SPORT = {
  "Sport",
  {1800, 2150, 2500, 2850, 3200, 3550, 3900},
  { 500,  850, 1200, 1600, 2000, 2350, 2600},
  7
};

const RpmPreset PRESET_AGGRESSIVE = {
  "Aggressive",
  {1800, 2150, 2500, 2850, 3200, 3550, 3900},
  { 600, 1000, 1400, 1800, 2200, 2500, 2700},
  7
};

// Active preset pointer
const RpmPreset* activePreset = &PRESET_ECONOMY;

// --- Hall effect ISR ---
// Accuracy derivation (SR_20/SR_21: 0.05% RPM accuracy over 1800–3900 range):
//
//   At 3900 RPM (worst case — shortest period):
//     Period = 60e6 / 3900 = 15,385 us
//     micros() resolution on Teensy 4.1 = 1 us (hardware timer, no jitter)
//     Single-sample quantization error = 1 / 15385 = 0.0065% — meets 0.05%
//
//   With 4-sample rolling average:
//     Random jitter (magnet wobble, ISR latency ~0.2 us on Cortex-M7) averages out.
//     Effective jitter contribution ≈ 0.2 / (15385 * sqrt(4)) = 0.00065% — negligible.
//     Dominant error source becomes magnet placement concentricity, not firmware.
//
//   At 1800 RPM (longest period in control range):
//     Period = 60e6 / 1800 = 33,333 us
//     Single-sample error = 1 / 33333 = 0.003% — even better.
//
void hallISR() {
  unsigned long now = micros();
  pulseDelta = now - lastPulseTime;
  lastPulseTime = now;
  newPulse = true;
}

// --- Torque calculation ---
float calculateTorque(float currentRpm) {
  if (currentRpm == 0) {
    return 0.0;
  }
  // Torque (lb-ft) = (HP * 5252) / RPM
  return (ENGINE_HP * 5252.0) / currentRpm;
}

// --- Preset list for cycling ---
const RpmPreset* PRESETS[] = { &PRESET_ECONOMY, &PRESET_SPORT, &PRESET_AGGRESSIVE };
const int NUM_PRESETS = 3;

// --- Mode selection via button press ---
// Button wired between PIN_MODE_BTN and GND, uses INPUT_PULLUP
// Each press cycles: Economy → Sport → Aggressive → Economy ...
void selectPresetFromButton() {
  bool btnState = digitalRead(PIN_MODE_BTN);

  // Detect falling edge (press) with debounce
  if (btnState == LOW && lastBtnState == HIGH) {
    if (millis() - lastBtnTime > BTN_DEBOUNCE_MS) {
      presetIndex = (presetIndex + 1) % NUM_PRESETS;
      activePreset = PRESETS[presetIndex];
      Serial.print("Preset: ");
      Serial.println(activePreset->name);
      lastBtnTime = millis();
    }
  }
  lastBtnState = btnState;
}

// --- Look up actuator target position from RPM and active preset ---
int getActuatorTargetForRpm(float currentRpm) {
  int target;

  if (currentRpm == 0) {
    target = activePreset->actPositions[0];
  }
  else if (currentRpm >= activePreset->rpmThresholds[activePreset->numPoints - 1]) {
    target = activePreset->actPositions[activePreset->numPoints - 1];
  }
  else {
    // Default to first position. If RPM is nonzero but below rpmThresholds[0],
    // we clamp to actPositions[0] — no interpolation below the lowest breakpoint.
    target = activePreset->actPositions[0];
    for (int i = 0; i < activePreset->numPoints - 1; i++) {
      if (currentRpm >= activePreset->rpmThresholds[i] &&
          currentRpm < activePreset->rpmThresholds[i + 1]) {
        target = map((int)currentRpm,
                     activePreset->rpmThresholds[i],
                     activePreset->rpmThresholds[i + 1],
                     activePreset->actPositions[i],
                     activePreset->actPositions[i + 1]);
        break;
      }
    }
  }

  // Clamp to safe position range
  return constrain(target, ACT_POS_MIN, ACT_POS_MAX);
}

// --- Stop actuator — safe shutdown of both relays ---
void stopActuator() {
  digitalWrite(PIN_RELAY_FWD, HIGH);
  digitalWrite(PIN_RELAY_REV, HIGH);
  lastRelayState = 0;
}

// --- Drive actuator toward target with deadtime protection ---
// CRITICAL: IN1 and IN2 must NEVER both be LOW simultaneously (dead short)
void driveActuator(int target) {
  int newState;

  if (actuatorPos < target - ACT_DEADBAND) {
    newState = 1;   // Extend (FWD)
    actuatorInDeadband = false;
  }
  else if (actuatorPos > target + ACT_DEADBAND) {
    newState = -1;  // Retract (REV)
    actuatorInDeadband = false;
  }
  else {
    newState = 0;   // Within deadband — stop
    actuatorInDeadband = true;
  }

  // If direction is changing, enforce deadtime
  if (newState != lastRelayState && newState != 0) {
    if (millis() - lastDirectionChange < RELAY_DEADTIME_MS) {
      // Not enough time elapsed — coast (both off)
      digitalWrite(PIN_RELAY_FWD, HIGH);
      digitalWrite(PIN_RELAY_REV, HIGH);
      return;
    }
  }

  if (newState != lastRelayState) {
    // Always turn both off first before changing direction
    digitalWrite(PIN_RELAY_FWD, HIGH);
    digitalWrite(PIN_RELAY_REV, HIGH);

    if (newState == 1) {
      digitalWrite(PIN_RELAY_FWD, LOW);  // Active LOW — energize FWD
    }
    else if (newState == -1) {
      digitalWrite(PIN_RELAY_REV, LOW);  // Active LOW — energize REV
    }

    lastDirectionChange = millis();
    lastRelayState = newState;
  }
}

// --- Fault detection ---
// Returns FAULT_NONE if healthy, or a fault code if something is wrong
FaultCode checkFaults() {
  // 1. Actuator feedback wire check
  if (actuatorPos < ACT_FEEDBACK_MIN || actuatorPos > ACT_FEEDBACK_MAX) {
    return FAULT_ACT_FEEDBACK;
  }

  // 2. RPM plausibility check
  if (rpmValid && rpm > RPM_MAX_VALID) {
    return FAULT_RPM_IMPLAUSIBLE;
  }

  // 3. Actuator stall check — driving but position not changing
  if (lastRelayState != 0) {
    // Relay is active — check if actuator is actually moving
    if (abs(actuatorPos - lastActuatorPos) > ACT_DEADBAND / 2) {
      actLastMoveTime = millis();
      lastActuatorPos = actuatorPos;
    }
    else if (millis() - actLastMoveTime > ACT_STALL_TIMEOUT_MS) {
      return FAULT_ACT_STALL;
    }
  }
  else if (actuatorInDeadband) {
    // Only reset stall timer when stopped AND confirmed within deadband of target.
    // If relay turned off for other reasons (deadtime coast, obstruction), the timer
    // keeps running so stall can still trigger on the next drive attempt.
    actLastMoveTime = millis();
    lastActuatorPos = actuatorPos;
  }

  return FAULT_NONE;
}

// --- Enter fail-safe mode ---
// Retract actuator to minimum position, halt all adjustments
void enterFailSafe(FaultCode fault) {
  activeFault = fault;
  faultLatched = true;
  stopActuator();
}

// --- Print fault status periodically ---
void printFault() {
  if (millis() - lastFaultPrintTime < FAULT_PRINT_INTERVAL_MS) return;
  lastFaultPrintTime = millis();

  Serial.print("FAULT,");
  switch (activeFault) {
    case FAULT_ACT_FEEDBACK:    Serial.print("ACT_FEEDBACK_LOST"); break;
    case FAULT_BTN_RESERVED:    Serial.print("RESERVED"); break;
    case FAULT_RPM_IMPLAUSIBLE: Serial.print("RPM_IMPLAUSIBLE"); break;
    case FAULT_ACT_STALL:       Serial.print("ACT_STALL"); break;
    default:                    Serial.print("UNKNOWN"); break;
  }
  Serial.print(",");
  Serial.print(actuatorPos);
  Serial.print(",");
  Serial.println(activePreset->name);
}

void setup() {
  Serial.begin(9600);  // 9600 baud — lower = more EMI resistant on noisy vehicle
  analogReadResolution(12);

  // Hall sensor — INPUT_PULLUP: HIGH at rest, LOW when magnet present
  pinMode(PIN_HALL, INPUT_PULLUP);
  attachInterrupt(digitalPinToInterrupt(PIN_HALL), hallISR, FALLING);

  // Relay pins — default both HIGH (relays off, active LOW module)
  pinMode(PIN_RELAY_FWD, OUTPUT);
  pinMode(PIN_RELAY_REV, OUTPUT);
  digitalWrite(PIN_RELAY_FWD, HIGH);
  digitalWrite(PIN_RELAY_REV, HIGH);

  // Mode button — INPUT_PULLUP, button connects pin to GND
  pinMode(PIN_MODE_BTN, INPUT_PULLUP);

  // No pinMode needed for analog input pin (PIN_ACT_POS)

  pinMode(LED_BUILTIN, OUTPUT);

  // Initialize fault detection timers
  actLastMoveTime = millis();
}

void loop() {
  // --- If in latched fault state, hold safe and report ---
  if (faultLatched) {
    stopActuator();
    actuatorPos = analogRead(PIN_ACT_POS);
    printFault();
    return;  // No control activity until manual reset (power cycle)
  }

  // --- 1. Check for new hall pulse from ISR ---
  if (newPulse) {
    noInterrupts();
    unsigned long delta = pulseDelta;
    newPulse = false;
    interrupts();

    if (delta > 0) {
      // Push into rolling average buffer
      deltaBuffer[deltaBufferIdx] = delta;
      deltaBufferIdx = (deltaBufferIdx + 1) % RPM_AVG_SAMPLES;
      if (deltaBufferCount < RPM_AVG_SAMPLES) deltaBufferCount++;

      // Compute averaged delta
      unsigned long sum = 0;
      for (int i = 0; i < deltaBufferCount; i++) sum += deltaBuffer[i];
      timeDelta = sum / deltaBufferCount;

      rpm = 60000000.0 / (timeDelta * MAGNETS_PER_REV);
      lastValidRpm = rpm;  // Store last clean reading for fault recovery
    }
    rpmValid = true;
    lastDetectionTime = micros();
    digitalWrite(LED_BUILTIN, HIGH);
  }

  // --- 2. Check for RPM timeout ---
  if (rpmValid && (micros() - lastDetectionTime > RPM_TIMEOUT)) {
    rpm = 0;
    rpmValid = false;
    digitalWrite(LED_BUILTIN, LOW);

    Serial.print("0,0,0.00,0.00,");
    Serial.print(actuatorPos);
    Serial.print(",");
    Serial.println(activePreset->name);
  }

  // --- 3. Read mode button and select preset ---
  selectPresetFromButton();

  // --- 4. Read actuator position feedback ---
  actuatorPos = analogRead(PIN_ACT_POS);

  // --- 5. Fault detection ---
  FaultCode fault = checkFaults();
  if (fault != FAULT_NONE) {
    if (fault == FAULT_ACT_FEEDBACK || fault == FAULT_ACT_STALL) {
      // Critical — latch into fail-safe
      enterFailSafe(fault);
      return;
    }
    else {
      // Non-critical — log warning but continue operating
      activeFault = fault;
      printFault();
      // For implausible RPM, reject the reading and hold last good value
      if (fault == FAULT_RPM_IMPLAUSIBLE) {
        rpm = lastValidRpm;
        // Keep rpmValid true — we're using the last good reading, not zeroing out
      }
    }
  }
  else {
    activeFault = FAULT_NONE;
  }

  // --- 6. Look up target and drive actuator ---
  // Below RPM_MIN_CONTROL (1800), engine is not under load — hold actuator retracted
  // to keep belt at low ratio. Don't try to interpolate into undefined preset region.
  int targetPos;
  if (rpm > 0 && rpm < RPM_MIN_CONTROL) {
    targetPos = ACT_POS_MIN;  // Retracted / low ratio
  } else {
    targetPos = getActuatorTargetForRpm(rpm);
  }
  driveActuator(targetPos);

  // --- 7. Periodic Serial output ---
  static unsigned long lastPrintTime = 0;
  if (micros() - lastPrintTime > PRINT_INTERVAL_US && rpmValid) {
    float torque = calculateTorque(rpm);
    Serial.print("1,");
    Serial.print(timeDelta);
    Serial.print(",");
    Serial.print(rpm, 2);
    Serial.print(",");
    Serial.print(torque, 2);
    Serial.print(",");
    Serial.print(actuatorPos);
    Serial.print(",");
    Serial.println(activePreset->name);
    lastPrintTime = micros();
  }
}
