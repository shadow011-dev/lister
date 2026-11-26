// Lister LED controller v2 - Arduino Nano
// Same wiring as before. Works with Lister's LEDs button and the LED card in Adjust.
//
// Commands (9600 baud, also typeable in the Serial Monitor):
//   a        all 10 LEDs on        (same as the first sketch)
//   s        all 10 LEDs off       (same as the first sketch)
//   n3       LED 3 on   (n1 ... n10)
//   f3       LED 3 off  (f1 ... f10)
//   m37      set all LEDs at once from a number 0-1023
//            (bit 0 = LED 1 on D2 ... bit 9 = LED 10 on D11; 37 = LEDs 1, 3, 6)
//   ?        report the state
// After every change it replies "MASK <number>", which Lister uses to stay in sync.

// Positive (+) pins for the 10 LEDs: LED 1 = D2 ... LED 10 = D11
int ledPins[] = {2, 3, 4, 5, 6, 7, 8, 9, 10, 11};

// Extra pins used as negative (-) GND slots
// (the remaining 3 LEDs connect to the 3 real GND pins on the board)
int gndPins[] = {A0, A1, A2, A3, A4, A5, 12};

const int LED_COUNT = 10;
const unsigned int ALL = (1u << LED_COUNT) - 1;   // 1023
unsigned int mask = 0;                             // which LEDs are on

void applyMask() {
  for (int i = 0; i < LED_COUNT; i++) {
    digitalWrite(ledPins[i], (mask >> i) & 1 ? HIGH : LOW);
  }
}

void report() {
  Serial.print("MASK ");
  Serial.println(mask);
}

void setup() {
  Serial.begin(9600);
  Serial.setTimeout(50);   // numbers after n / f / m arrive right away

  // Pins used as GND
  for (int i = 0; i < 7; i++) {
    pinMode(gndPins[i], OUTPUT);
    digitalWrite(gndPins[i], LOW);
  }

  // LED pins, all off
  for (int i = 0; i < LED_COUNT; i++) {
    pinMode(ledPins[i], OUTPUT);
    digitalWrite(ledPins[i], LOW);
  }

  Serial.println("Ready! v2. a=all on, s=all off, n1-n10 on, f1-f10 off, m0-m1023 pattern, ? state");
}

void loop() {
  if (Serial.available() > 0) {
    char c = Serial.read();

    if (c == 'a' || c == 'A') {
      mask = ALL;
      applyMask();
      Serial.println("All LEDs ON");
      report();
    }
    else if (c == 's' || c == 'S') {
      mask = 0;
      applyMask();
      Serial.println("All LEDs OFF");
      report();
    }
    else if (c == 'n' || c == 'N' || c == 'f' || c == 'F') {
      long k = Serial.parseInt();
      if (k >= 1 && k <= LED_COUNT) {
        if (c == 'n' || c == 'N') mask |= (1u << (k - 1));
        else                      mask &= ~(1u << (k - 1));
        applyMask();
        report();
      }
    }
    else if (c == 'm' || c == 'M') {
      long m = Serial.parseInt();
      if (m >= 0 && m <= (long)ALL) {
        mask = (unsigned int)m;
        applyMask();
        report();
      }
    }
    else if (c == '?') {
      report();
    }
    // anything else (newlines, spaces) is ignored
  }
}
