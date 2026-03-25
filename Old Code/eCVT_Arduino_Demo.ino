#include <Servo.h>

Servo myServo;
int hallPin = 2;
int servoPin = 3;
int twst = A8;
int post;
int magCount;
bool magDetect;
// RPM measurement variables
unsigned long lastDetectionTime = 0;
unsigned long currentTime = 0;
int pulseCount = 0;
float rpm = 0;
bool lastHallState = LOW;
bool rpmValid = false;

const int MAGNETS_PER_REV = 1;

void setup() {
  Serial.begin(9600);
  myServo.attach(servoPin);
  pinMode(hallPin, INPUT);
  pinMode(servoPin, OUTPUT);
  pinMode(LED_BUILTIN, OUTPUT);
  pinMode(twst, INPUT);
}

void loop() {
  //control servo with Petentiometer angle
  post = analogRead(twst);
  int servoAngle = map(post, 0, 1023, 0, 180);
  myServo.write(servoAngle);
  

  magDetect = digitalRead(hallPin);
  if(magDetect == HIGH){
    //Serial.println("Magnet Detected:" + magDetect);
    digitalWrite(LED_BUILTIN, HIGH);
  }
  else{
    //Serial.println("Nothing There:" + magDetect);
    digitalWrite(LED_BUILTIN, LOW);
  }

// Read hall sensor
  bool currentHallState = digitalRead(hallPin);
  
  // Detect rising edge (magnet has just arrived)
  if(currentHallState == HIGH && lastHallState == LOW) {
    digitalWrite(LED_BUILTIN, HIGH);
    
    currentTime = micros();
    
    if(pulseCount == 0) {
      // First detection - just record time
      lastDetectionTime = currentTime;
      pulseCount = 1;
      Serial.println("First magnet detected - initializing");
    }
    else {
      // Calculate time since last pulse
      unsigned long timeDelta = currentTime - lastDetectionTime;
      
      // Each pulse = 1/3 revolution
      // RPM = (60 * 1000) / (timeDelta * MAGNETS_PER_REV)
      rpm = 60000000.0 / (timeDelta * MAGNETS_PER_REV); //changed this for microseconds
      
      Serial.print("Magnet detected | Time delta: ");
      Serial.print(timeDelta);
      Serial.print(" microseconds | RPM: ");
      Serial.println(rpm);
      
      lastDetectionTime = currentTime;
      pulseCount++;
      rpmValid = true;
    }
  }
  else if(currentHallState == LOW) {
    digitalWrite(LED_BUILTIN, LOW);
  }
  
  // Store current state for next iteration
  lastHallState = currentHallState;
  
  // Optional: Display current RPM periodically
  static unsigned long lastPrintTime = 0;
  if(micros() - lastPrintTime > 500 && rpmValid) {
    //Serial.print("Current RPM: ");
    Serial.print(micros());
    Serial.print(",");
    Serial.println(rpm);
    lastPrintTime = micros();
  }
        
      
  //delay(15);  // Small delay for servo stability
  /*static unsigned long lastPlotTime = 0;
  if (micros() - lastPlotTime > 5000 && rpmValid) { // every 5 ms
    Serial.println(rpm);   // <--- This is what the plotter will use
    lastPlotTime = micros();
  }*/
}
