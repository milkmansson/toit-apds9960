// Copyright (C) 2026 Toit Contributors
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the EXAMPLES_LICENSE file.

/**
Detects hand swipes with the INT pin and a callback.

The $Apds9960Events class waits for the sensor's INT pin on its own task and
  calls the lambda with the decoded direction.  Wire the module's INT pin to
  $INTERRUPT-PIN.  The pin is open drain and active low, so it needs a pull-up,
  which this example turns on in the ESP32.
*/

import gpio
import i2c
import apds9960 show *
import apds9960.events show *

// Please set these correctly for the device in use:
SDA-PIN ::= 8
SCL-PIN ::= 9
FREQUENCY ::= 400_000
INTERRUPT-PIN ::= 4

main:
  bus := i2c.Bus
      --sda=(gpio.Pin SDA-PIN)
      --scl=(gpio.Pin SCL-PIN)
      --frequency=FREQUENCY
  driver := Apds9960 (bus.device Apds9960.I2C-ADDRESS)

  driver.power-on
  driver.set-proximity-defaults
  driver.set-gesture-defaults
  driver.enable-proximity
  driver.enable-gesture

  events := Apds9960Events driver
      --intrpt-pin=(gpio.Pin INTERRUPT-PIN --input --pull-up)
  events.on-gesture --callback=:: | gesture/int |
    print "Gesture: $(Gesture.name-of gesture)"
  events.start

  print "Swipe a hand over the sensor."
  // The application is free to do other work here.
  while true: sleep --ms=1000
