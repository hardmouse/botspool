#include <ESP32Servo.h>

// ----------------------------
// TB6612 Pins
// ----------------------------
#define PWMA 25
#define AIN1 26
#define AIN2 27
#define STBY 33

#define PWMB 14
#define BIN1 12
#define BIN2 13

// ----------------------------
// Servo
// ----------------------------
#define SERVO_PIN 32
Servo head;

// ----------------------------
// UART2 to Raspberry Pi
// ----------------------------
#define UART_RX 16  // ESP32 RX2  <- Pi TX (pin 8)
#define UART_TX 17  // ESP32 TX2  -> Pi RX (pin 10)

// ----------------------------
// Failsafe
// ----------------------------
unsigned long lastCmdMs = 0;
const unsigned long FAILSAFE_MS = 800;

// ----------------------------
// LEDC PWM (ESP32 core 3.3.5)
// Use explicit channels to avoid conflicts with Servo library
// ----------------------------
static const int CH_A = 6;
static const int CH_B = 7;

// ----------------------------
// Servo scan state
// ----------------------------
bool servoScan = false;
int  servoPos  = 90;         // 0..180
int  servoDir  = 1;          // +1 / -1
unsigned long lastServoMs = 0;
const unsigned long SERVO_STEP_MS = 25;
const int SERVO_STEP_DEG = 2;

// ----------------------------
// Motor control
// ----------------------------
void motorRaw(int left, int right) {
  // left/right: -255..255

  // Left motor direction
  int a = left;
  if (a > 0) { digitalWrite(AIN1, HIGH); digitalWrite(AIN2, LOW); }
  else if (a < 0) { digitalWrite(AIN1, LOW); digitalWrite(AIN2, HIGH); a = -a; }
  else { digitalWrite(AIN1, LOW); digitalWrite(AIN2, LOW); }

  // Right motor direction
  int b = right;
  if (b > 0) { digitalWrite(BIN1, HIGH); digitalWrite(BIN2, LOW); }
  else if (b < 0) { digitalWrite(BIN1, LOW); digitalWrite(BIN2, HIGH); b = -b; }
  else { digitalWrite(BIN1, LOW); digitalWrite(BIN2, LOW); }

  // PWM duty by CHANNEL (NOT by pin)
  ledcWriteChannel(CH_A, constrain(a, 0, 255));
  ledcWriteChannel(CH_B, constrain(b, 0, 255));
}

void stopAll() {
  motorRaw(0, 0);
}

// ----------------------------
// Servo scan update
// ----------------------------
void updateServoScan() {
  if (!servoScan) return;

  unsigned long now = millis();
  if (now - lastServoMs < SERVO_STEP_MS) return;
  lastServoMs = now;

  servoPos += servoDir * SERVO_STEP_DEG;

  if (servoPos >= 180) { servoPos = 180; servoDir = -1; }
  if (servoPos <= 0)   { servoPos = 0;   servoDir =  1; }

  head.write(servoPos);
}

// ----------------------------
// UART line reader
// ----------------------------
String readLineUART() {
  static String buf;
  while (Serial2.available()) {
    char c = (char)Serial2.read();
    if (c == '\n') {
      String line = buf;
      buf = "";
      line.trim();
      return line;
    }
    buf += c;
  }
  return "";
}

// ----------------------------
// Command handler
// ----------------------------
void handleCmd(const String& cmd) {
  // Commands:
  // F/B/L/R/S
  // M <left> <right>
  // Servo:
  // Z (start/resume scan)
  // X (stop scan hold)
  // C (center + stop scan)
  // V <angle> 0..180 (set angle + stop scan)

  if (cmd == "F") motorRaw(170, 170);
  else if (cmd == "B") motorRaw(-170, -170);
  else if (cmd == "L") motorRaw(-140, 140);
  else if (cmd == "R") motorRaw(140, -140);
  else if (cmd == "S") stopAll();

  else if (cmd.startsWith("M ")) {
    int l=0, r=0;
    if (sscanf(cmd.c_str(), "M %d %d", &l, &r) == 2) {
      motorRaw(constrain(l, -255, 255), constrain(r, -255, 255));
    }
  }

  // ---- Servo commands ----
  else if (cmd == "Z") {
    // Start/resume scan from current servoPos
    servoScan = true;
    head.write(servoPos);
    lastServoMs = millis();
  }
  else if (cmd == "X") {
    // Stop scan, HOLD current position
    servoScan = false;
  }
  else if (cmd == "C") {
    // Center (and stop scan)
    servoScan = false;
    servoPos = 90;
    head.write(servoPos);
  }
  else if (cmd.startsWith("V ")) {
    int ang=90;
    if (sscanf(cmd.c_str(), "V %d", &ang) == 1) {
      servoScan = false;
      servoPos = constrain(ang, 0, 180);
      head.write(servoPos);
    }
  }

  lastCmdMs = millis();
}

// ----------------------------
// Setup
// ----------------------------
void setup() {
  // Motor direction pins
  pinMode(AIN1, OUTPUT);
  pinMode(AIN2, OUTPUT);
  pinMode(BIN1, OUTPUT);
  pinMode(BIN2, OUTPUT);

  // Standby
  pinMode(STBY, OUTPUT);

  // Force direction LOW at boot (prevents creep/noise)
  digitalWrite(AIN1, LOW);
  digitalWrite(AIN2, LOW);
  digitalWrite(BIN1, LOW);
  digitalWrite(BIN2, LOW);

  // Enable driver
  digitalWrite(STBY, HIGH);

  // Motor PWM (ESP32 core 3.3.5): explicit channels
  bool okA = ledcAttachChannel(PWMA, 20000, 8, CH_A);
  bool okB = ledcAttachChannel(PWMB, 20000, 8, CH_B);

  // Force duty 0 at boot
  ledcWriteChannel(CH_A, 0);
  ledcWriteChannel(CH_B, 0);

  // If attach failed, freeze (should not happen)
  if (!okA || !okB) {
    while (true) delay(1000);
  }

  // Servo
  head.setPeriodHertz(50);
  head.attach(SERVO_PIN, 500, 2500);
  servoPos = 90;
  head.write(servoPos);

  // UART to Pi
  Serial2.begin(115200, SERIAL_8N1, UART_RX, UART_TX);

  stopAll();
  lastCmdMs = millis();
}

// ----------------------------
// Loop
// ----------------------------
void loop() {
  String line = readLineUART();
  if (line.length()) handleCmd(line);

  updateServoScan();

  // failsafe stop if Pi stops talking
  if (millis() - lastCmdMs > FAILSAFE_MS) {
    stopAll();
    lastCmdMs = millis();
  }
}
