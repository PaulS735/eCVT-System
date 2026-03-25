// eCVT Firmware — Knight Racing Baja SAE
// Teensy 4.1 — Relay H-bridge actuator control with hall effect RPM

// --- Pin assignments ---
const int PIN_HALL      = 2;   // Hall effect sensor (interrupt-capable, INPUT_PULLUP)
const int PIN_RELAY_FWD = 3;   // Forward relay control (active LOW)
const int PIN_RELAY_REV = 4;   // Reverse relay control (active LOW)
const int PIN_POT       = A8;  // Potentiometer mode selector (analog in)
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
// Position scale: 0 = fully retracted, ~2794 = fully extended (voltage divider limits to ~2.25V)

// --- Fault detection constants ---
const int ACT_FEEDBACK_MIN     = 10;    // Below this = feedback wire likely broken/disconnected
const int ACT_FEEDBACK_MAX     = 3000;  // Above this = feedback wire shorted to power
const int POT_STUCK_THRESHOLD  = 5;     // ADC counts — less change than this over N reads = stuck
const unsigned long POT_STUCK_TIME_MS = 5000;  // How long pot must be static to flag stuck
const float RPM_MAX_VALID      = 4000.0; // Above this RPM = sensor noise / false trigger
const unsigned long ACT_STALL_TIMEOUT_MS = 3000; // If actuator hasn't moved in this long while driving

// --- Engine specs ---
const float ENGINE_HP = 10.0;  // Briggs & Stratton 10HP

// --- Hall sensor ISR variables (volatile) ---
volatile unsigned long lastPulseTime = 0;
volatile unsigned long pulseDelta = 0;
volatile bool newPulse = false;

// --- Fault flags ---
enum FaultCode {
  FAULT_NONE           = 0,
  FAULT_ACT_FEEDBACK   = 1,  // Actuator position feedback out of range
  FAULT_POT_STUCK      = 2,  // Potentiometer stuck at one value
  FAULT_RPM_IMPLAUSIBLE = 3, // RPM reading above physical limit
  FAULT_ACT_STALL      = 4   // Actuator not moving despite being driven
};

FaultCode activeFault = FAULT_NONE;
bool faultLatched = false;  // Once critical fault triggers, stay in fault until reset

// --- Global state ---
unsigned long lastDetectionTime = 0;
unsigned long timeDelta = 0;
float rpm = 0;
bool rpmValid = false;
int potValue = 0;
int actuatorPos = 0;
unsigned long lastDirectionChange = 0;
int lastRelayState = 0;  // 0=stopped, 1=fwd, -1=rev

// Fault detection state
int lastPotValue = 0;
unsigned long potLastChangeTime = 0;
int lastActuatorPos = 0;
unsigned long actLastMoveTime = 0;
unsigned long lastFaultPrintTime = 0;

// --- Preset structure ---
struct RpmPreset {
  const char* name;
  int rpmThresholds[5];
  int actPositions[5];    // Actuator position targets in ADC counts (0-2794)
  int numPoints;
};

// Placeholder values — must be calibrated on vehicle
const RpmPreset PRESET_AGGRESSIVE = {
  "Aggressive",
  {500, 1000, 1500, 2000, 2500},
  {600, 1100, 1600, 2100, 2600},
  5
};

const RpmPreset PRESET_ECONOMY = {
  "Economy",
  {300, 800, 1300, 1800, 2300},
  {500, 900, 1400, 1900, 2400},
  5
};

const RpmPreset PRESET_SPORT = {
  "Sport",
  {600, 1200, 1800, 2400, 3000},
  {700, 1200, 1700, 2200, 2700},
  5
};

// Active preset pointer
const RpmPreset* activePreset = &PRESET_ECONOMY;

// --- Hall effect ISR ---
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

// --- Preset selection from potentiometer ---
void selectPresetFromPot() {
  potValue = analogRead(PIN_POT);

  // 12-bit ADC: 0-4095 divided into 3 zones
  if (potValue < 1365) {
    if (activePreset != &PRESET_ECONOMY) {
      activePreset = &PRESET_ECONOMY;
      Serial.println("Preset: Economy");
    }
  }
  else if (potValue < 2730) {
    if (activePreset != &PRESET_SPORT) {
      activePreset = &PRESET_SPORT;
      Serial.println("Preset: Sport");
    }
  }
  else {
    if (activePreset != &PRESET_AGGRESSIVE) {
      activePreset = &PRESET_AGGRESSIVE;
      Serial.println("Preset: Aggressive");
    }
  }
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
    target = activePreset->actPositions[0]; // default
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
  }
  else if (actuatorPos > target + ACT_DEADBAND) {
    newState = -1;  // Retract (REV)
  }
  else {
    newState = 0;   // Within deadband — stop
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

  // 2. Potentiometer stuck check
  if (abs(potValue - lastPotValue) > POT_STUCK_THRESHOLD) {
    potLastChangeTime = millis();
    lastPotValue = potValue;
  }
  else if (millis() - potLastChangeTime > POT_STUCK_TIME_MS) {
    // Only flag if pot is at a rail (0 or 4095) — mid-range "stuck" is just the user not turning it
    if (potValue < 10 || potValue > 4085) {
      return FAULT_POT_STUCK;
    }
  }

  // 3. RPM plausibility check
  if (rpmValid && rpm > RPM_MAX_VALID) {
    return FAULT_RPM_IMPLAUSIBLE;
  }

  // 4. Actuator stall check — driving but position not changing
  if (lastRelayState != 0) {
    if (abs(actuatorPos - lastActuatorPos) > ACT_DEADBAND / 2) {
      actLastMoveTime = millis();
      lastActuatorPos = actuatorPos;
    }
    else if (millis() - actLastMoveTime > ACT_STALL_TIMEOUT_MS) {
      return FAULT_ACT_STALL;
    }
  }
  else {
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
    case FAULT_POT_STUCK:       Serial.print("POT_STUCK"); break;
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

  // No pinMode needed for analog input pins (PIN_POT, PIN_ACT_POS)

  pinMode(LED_BUILTIN, OUTPUT);

  // Initialize fault detection timers
  potLastChangeTime = millis();
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
      timeDelta = delta;
      rpm = 60000000.0 / (timeDelta * MAGNETS_PER_REV);
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

  // --- 3. Read potentiometer and select preset ---
  selectPresetFromPot();

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
      // For implausible RPM, reject the reading
      if (fault == FAULT_RPM_IMPLAUSIBLE) {
        rpm = 0;
        rpmValid = false;
      }
    }
  }
  else {
    activeFault = FAULT_NONE;
  }

  // --- 6. Look up target and drive actuator ---
  int targetPos = getActuatorTargetForRpm(rpm);
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
